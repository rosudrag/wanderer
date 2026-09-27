defmodule WandererApp.Map.Operations.SignatureSync do
  @moduledoc """
  CHEWY PATCH: whole-system signature sync for an automated scanner client.

  The existing `/signatures` resource is one HTTP request per signature and has
  no notion of a signature that has *despawned*. A scanner client reads the
  whole probe-scanner list for one system at once, so it wants the inverse
  shape: post the complete list, let the server work out what was added,
  changed and removed, and apply it in one batch.

  The batch apply itself already exists -- `WandererApp.Map.Server.update_signatures/2`
  takes `added_signatures` / `updated_signatures` / `removed_signatures` and does
  the broadcasts, the activity tracking and the connection bookkeeping. What did
  NOT exist server-side is the DIFF: the map UI computes it in TypeScript before
  posting (see `map_signatures_event_handler.ex` "update_signatures"). This module
  is that diff, plus the guards an unattended client needs.

  ## `authoritative`

  The single dangerous operation here is removal. `authoritative: true` is the
  caller asserting "this is the COMPLETE scanner list for that system" -- only
  then are signatures missing from the payload deleted. A client with a stale,
  mid-jump or still-loading snapshot must send `authoritative: false`, where the
  payload can only add and update.

  Two further removal guards, because an empty list and a failed read look
  identical on the wire:

    * an EMPTY authoritative payload for a system that currently has signatures
      is refused (`:empty_authoritative_payload`) unless the caller also sends
      `allow_empty: true`. A genuinely empty system is a real state, but it is
      also exactly what a broken client reports, and the cost of being wrong is
      someone's whole chain.
    * connections are never deleted as a side effect of a removal here
      (`delete_connection_with_sigs: false`). A wormhole that stopped being
      scannable is not proof the connection is gone.

  ## Field merging

  Only keys actually PRESENT in an incoming signature are applied. The batch
  applier builds its DTO from the map it is given and a missing key becomes
  `nil`, which the Ash `:update` action would happily write -- so an update DTO
  here is the existing row overlaid with the incoming keys, never the incoming
  keys alone. A client that does not know about `description` cannot erase it.
  """

  require Logger

  alias WandererApp.Api.{Character, MapSystem, MapSystemSignature}
  alias WandererApp.Map.Operations
  alias WandererApp.Map.Server

  # Signature attributes this endpoint will carry, as {wire key, struct key}.
  # `eve_id` is the identity and is handled separately; `deleted` is the batch
  # applier's own business.
  @synced_fields [
    {"name", :name},
    {"description", :description},
    {"temporary_name", :temporary_name},
    {"kind", :kind},
    {"group", :group},
    {"type", :type},
    {"custom_info", :custom_info},
    {"linked_system_id", :linked_system_id}
  ]
  @synced_keys Enum.map(@synced_fields, &elem(&1, 0))

  @type result :: %{
          added: non_neg_integer(),
          updated: non_neg_integer(),
          removed: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Apply a whole-system signature list.

  Expects `conn.assigns` to carry `:map_id`, `:owner_character_id` and
  `:owner_user_id` (the `:api_map` pipeline provides all three).
  """
  @spec sync(Plug.Conn.t(), map()) :: {:ok, result()} | {:error, atom()}
  def sync(
        %{assigns: %{map_id: map_id, owner_character_id: char_id, owner_user_id: user_id}},
        %{"solar_system_id" => solar_system_id, "signatures" => signatures} = params
      )
      when is_integer(solar_system_id) and is_list(signatures) and not is_nil(char_id) do
    authoritative? = truthy(Map.get(params, "authoritative", false))
    allow_empty? = truthy(Map.get(params, "allow_empty", false))

    with {:ok, character_id} <- resolve_character(params, char_id),
         {:ok, system} <- ensure_system_on_map(map_id, solar_system_id, user_id, char_id) do
      existing = MapSystemSignature.by_system_id!(system.id)
      {incoming, skipped} = normalize(signatures)

      if authoritative? and incoming == [] and existing != [] and not allow_empty? do
        Logger.warning(
          "[SignatureSync] refused empty authoritative payload for map #{map_id} " <>
            "system #{solar_system_id} holding #{length(existing)} signature(s)"
        )

        {:error, :empty_authoritative_payload}
      else
        %{added: added, updated: updated, removed: removed} =
          diff(existing, incoming, authoritative?)

        :ok =
          Server.update_signatures(map_id, %{
            solar_system_id: solar_system_id,
            character_id: character_id,
            user_id: user_id,
            # Never cascade a connection delete off a scanner absence -- see
            # the moduledoc. A connection is removed deliberately, by a human
            # or by the connection endpoint, not because a signature aged out.
            delete_connection_with_sigs: false,
            added_signatures: added,
            updated_signatures: updated,
            removed_signatures: removed
          })

        link_wormholes(map_id, solar_system_id, incoming, user_id, char_id)

        {:ok,
         %{
           added: length(added),
           updated: length(updated),
           removed: length(removed),
           skipped: skipped
         }}
      end
    end
  end

  def sync(%{assigns: %{map_id: _, owner_character_id: _, owner_user_id: _}}, _params),
    do: {:error, :missing_params}

  def sync(_conn, _params), do: {:error, :missing_params}

  @doc """
  The pure half: given the map's current signature rows and a normalized
  incoming list, decide what to add, update and remove.

  `existing` rows are structs/maps keyed by atoms (as Ash returns them);
  `incoming` entries are string-keyed maps carrying at least `"eve_id"`.
  Returns DTOs in the string-keyed shape `Server.update_signatures/2` parses.

  `removed` is always empty when `authoritative?` is false.
  """
  @spec diff([map()], [map()], boolean()) :: %{added: [map()], updated: [map()], removed: [map()]}
  def diff(existing, incoming, authoritative?) do
    by_eve_id = Map.new(existing, &{&1.eve_id, &1})
    incoming_ids = MapSet.new(incoming, & &1["eve_id"])

    {updated, added} =
      Enum.split_with(incoming, &Map.has_key?(by_eve_id, &1["eve_id"]))

    updated =
      updated
      |> Enum.filter(fn sig -> changed?(by_eve_id[sig["eve_id"]], sig) end)
      |> Enum.map(fn sig -> merge_over(by_eve_id[sig["eve_id"]], sig) end)

    removed =
      if authoritative? do
        existing
        |> Enum.reject(&MapSet.member?(incoming_ids, &1.eve_id))
        |> Enum.map(&%{"eve_id" => &1.eve_id})
      else
        []
      end

    %{added: added, updated: updated, removed: removed}
  end

  @doc """
  Drop entries without a usable `eve_id` and de-duplicate on it (first wins).

  Returns `{kept, skipped_count}` so the caller can report how much of the
  payload was unusable instead of silently swallowing it.
  """
  @spec normalize([map()]) :: {[map()], non_neg_integer()}
  def normalize(signatures) do
    kept =
      signatures
      |> Enum.filter(&valid_eve_id?/1)
      |> Enum.map(fn sig -> Map.put(sig, "eve_id", String.trim(sig["eve_id"])) end)
      |> Enum.uniq_by(& &1["eve_id"])

    {kept, length(signatures) - length(kept)}
  end

  defp valid_eve_id?(sig) when is_map(sig) do
    case Map.get(sig, "eve_id") do
      id when is_binary(id) -> String.trim(id) != ""
      _ -> false
    end
  end

  defp valid_eve_id?(_), do: false

  # A change in ANY key the caller actually sent. Keys the caller omitted are
  # not compared -- it has no opinion on them, so they cannot make a row dirty.
  defp changed?(existing, incoming) do
    Enum.any?(@synced_fields, fn {key, attr} ->
      Map.has_key?(incoming, key) and
        normalize_value(Map.get(incoming, key)) != normalize_value(Map.get(existing, attr))
    end)
  end

  # The update DTO: the existing row first, then the incoming keys on top, so an
  # omitted field keeps its stored value instead of being nil'd out.
  defp merge_over(existing, incoming) do
    base =
      Map.new(@synced_fields, fn {key, attr} -> {key, Map.get(existing, attr)} end)

    base
    |> Map.merge(Map.take(incoming, @synced_keys))
    |> Map.put("eve_id", existing.eve_id)
    |> maybe_put_character(incoming)
  end

  defp maybe_put_character(dto, incoming) do
    case Map.get(incoming, "character_eve_id") do
      nil -> dto
      eve_id -> Map.put(dto, "character_eve_id", eve_id)
    end
  end

  # "" and nil are the same absence as far as a scanner client is concerned;
  # treating them as different would mark every row dirty on every sweep.
  defp normalize_value(""), do: nil
  defp normalize_value(value), do: value

  # Resolve the acting character. `character_eve_id` is the in-game id; the
  # batch applier wants our internal character UUID. Falls back to the map
  # owner, exactly like the per-signature endpoint does.
  defp resolve_character(params, fallback_char_id) do
    case Map.get(params, "character_eve_id") do
      nil ->
        {:ok, fallback_char_id}

      eve_id when is_binary(eve_id) ->
        case Character.by_eve_id(eve_id) do
          {:ok, character} -> {:ok, character.id}
          _ -> {:error, :invalid_character}
        end

      _ ->
        {:error, :invalid_character}
    end
  end

  # Same auto-add behaviour the per-signature endpoint has: a system the client
  # scanned but that nobody has put on the map yet is added rather than refused.
  # Deliberately re-implemented over public functions instead of reaching into
  # Operations.Signatures' private helpers -- this file stays additive.
  defp ensure_system_on_map(map_id, solar_system_id, user_id, char_id) do
    case WandererApp.Map.find_system_by_location(map_id, %{solar_system_id: solar_system_id}) do
      nil -> add_system_to_map(map_id, solar_system_id, user_id, char_id)
      system -> {:ok, system}
    end
  end

  defp add_system_to_map(map_id, solar_system_id, user_id, char_id) do
    with {:ok, static_info} when not is_nil(static_info) <-
           WandererApp.CachedInfo.get_system_static_info(solar_system_id),
         :ok <-
           Server.add_system(
             map_id,
             %{solar_system_id: solar_system_id, coordinates: nil},
             user_id,
             char_id
           ),
         system when not is_nil(system) <- fetch_system_after_add(map_id, solar_system_id) do
      Logger.info("[SignatureSync] auto-added system #{solar_system_id} to map #{map_id}")
      {:ok, system}
    else
      {:ok, nil} -> {:error, :invalid_solar_system}
      {:error, _} -> {:error, :invalid_solar_system}
      nil -> {:error, :system_add_failed}
      _ -> {:error, :system_add_failed}
    end
  end

  defp fetch_system_after_add(map_id, solar_system_id) do
    case WandererApp.Map.find_system_by_location(map_id, %{solar_system_id: solar_system_id}) do
      nil ->
        case MapSystem.read_by_map_and_solar_system(%{
               map_id: map_id,
               solar_system_id: solar_system_id
             }) do
          {:ok, system} -> system
          _ -> nil
        end

      system ->
        system
    end
  end

  # A signature that names the system it leads to is a mapped connection, not
  # just a row. The per-signature endpoint already knows how to auto-add the
  # far system, create the connection and infer its ship-size class from the
  # wormhole type, so route those through it rather than duplicating the ladder.
  # Idempotent: the signature itself upserts on (system_id, eve_id).
  defp link_wormholes(map_id, solar_system_id, incoming, user_id, char_id) do
    conn = %{
      assigns: %{map_id: map_id, owner_character_id: char_id, owner_user_id: user_id}
    }

    incoming
    |> Enum.filter(fn sig ->
      is_integer(sig["linked_system_id"]) and sig["linked_system_id"] != solar_system_id
    end)
    |> Enum.each(fn sig ->
      params = Map.put(sig, "solar_system_id", solar_system_id)

      case Operations.Signatures.create_signature(conn, params) do
        {:ok, _} ->
          :ok

        error ->
          Logger.warning(
            "[SignatureSync] could not link #{sig["eve_id"]} -> #{sig["linked_system_id"]}: " <>
              inspect(error)
          )
      end
    end)
  end

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false
end
