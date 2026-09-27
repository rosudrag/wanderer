defmodule WandererApp.Sync.Feeds.CorpRosterFeed do
  @moduledoc """
  Primary roster source: one call per poll to
  `GET /corporations/{id}/membertracking/` (director-scoped,
  `esi-corporations.track_members.v1`) returns `character_id`,
  `start_date`, `logon_date`, `logoff_date`, `location_id`,
  `ship_type_id`, `base_id` for the **entire roster** -- no per-member
  token, no per-member consent. Response is IDs only; names are
  resolved via one batch `POST /universe/names/` call
  (`WandererApp.CachedInfo.get_character_name/1` for characters,
  `WandererApp.CachedInfo.get_system_static_info/1` for solar-system
  `location_id` values, `WandererApp.CachedInfo.get_ship_type/1` for
  `ship_type_id` -- reused as-is, not duplicated). `304 Not Modified`
  responses from this endpoint don't count against ESI's error limit
  (`docs/chewy/seat-parity.md` §6.1), so Phase 2's ETag work is a direct
  efficiency win here. See docs/chewy/corp-suite-plan.md §9 Phase 3.

  **Known limitation, not silently truncated:** `WandererApp.Esi.
  ApiClient.get_corp_membertracking/2` fetches page 1 only (ESI pages
  this endpoint at 100 rows/page per `seat-parity.md` §8.3) -- a corp
  with 101+ members will silently miss members 101+ on every poll.
  See that function's own comment for the concrete fix. Not closed in
  this phase; revisit before trusting a corp roster past 100 members.

  `scope` is the whole `WandererApp.Api.OwnedCorporation` struct (gives
  `fetch/2` both `eve_corporation_id` and `director_character_id`
  without a re-fetch); `WandererApp.Sync.Registry`'s resolver for this
  feed only ever yields corps that already have a
  `director_character_id` set -- a corp with none configured is simply
  never scheduled, not dispatched-and-immediately-errored every tick.
  """

  @behaviour WandererApp.Sync.Feed

  require Logger

  alias WandererApp.Api.{Character, CorpRosterSnapshot, OwnedCorporation}
  alias WandererApp.{CachedInfo, Esi}

  @doc """
  `WandererApp.Sync.Registry`'s scope_resolver for this feed. Only
  corps that already have `director_character_id` set are returned --
  an unconfigured corp is simply never scheduled, not
  dispatched-and-immediately-errored every tick.
  """
  def scopes do
    case OwnedCorporation.read(authorize?: false) do
      {:ok, corps} ->
        corps
        |> Enum.filter(& &1.director_character_id)
        |> Enum.map(&{&1, to_string(&1.eve_corporation_id)})

      _error ->
        []
    end
  end

  @impl true
  def cadence_seconds(_corp), do: 4 * 60 * 60

  @impl true
  def token_holder(%OwnedCorporation{director_character_id: nil}),
    do: {:error, :no_director_token}

  def token_holder(%OwnedCorporation{director_character_id: character_id}) do
    case Character.by_id(character_id, authorize?: false) do
      {:ok, character} -> {:character, character}
      _not_found -> {:error, :no_director_token}
    end
  end

  @impl true
  def fetch(%OwnedCorporation{} = corp, etag) do
    case token_holder(corp) do
      {:character, character} ->
        Esi.get_corp_membertracking(corp.eve_corporation_id,
          access_token: character.access_token,
          character_id: character.id,
          etag: etag
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def upsert(%OwnedCorporation{eve_corporation_id: corporation_id}, rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    names_by_id = resolve_names(rows)

    seen_character_ids =
      rows
      |> Enum.map(&upsert_member!(&1, corporation_id, now, names_by_id))
      |> MapSet.new()

    mark_departed!(corporation_id, seen_character_ids, now)

    :ok
  end

  @impl true
  def retention_days, do: :infinity

  @impl true
  def purge_stale(_corp), do: :ok

  # -- name resolution ------------------------------------------------------

  defp resolve_names(rows) do
    character_ids = rows |> Enum.map(& &1["character_id"]) |> Enum.reject(&is_nil/1)

    Map.new(character_ids, fn id ->
      case CachedInfo.get_character_name(id) do
        {:ok, name} -> {id, name}
        _not_found -> {id, nil}
      end
    end)
  end

  defp resolve_location_name(nil), do: nil

  defp resolve_location_name(location_id) do
    case CachedInfo.get_system_static_info(location_id) do
      {:ok, %{solar_system_name: name}} -> name
      _not_solar_system_or_not_found -> nil
    end
  end

  defp resolve_ship_type_name(nil), do: nil

  defp resolve_ship_type_name(ship_type_id) do
    case CachedInfo.get_ship_type(ship_type_id) do
      {:ok, %{name: name}} -> name
      _not_found -> nil
    end
  end

  # -- upsert -----------------------------------------------------------------

  defp upsert_member!(row, corporation_id, now, names_by_id) do
    character_id = row["character_id"] |> to_string()

    attrs = %{
      character_id: character_id,
      name: Map.get(names_by_id, row["character_id"]),
      corporation_id: corporation_id,
      start_date: parse_datetime(row["start_date"]),
      logon_at: parse_datetime(row["logon_date"]),
      logoff_at: parse_datetime(row["logoff_date"]),
      location_id: row["location_id"],
      location_name: resolve_location_name(row["location_id"]),
      ship_type_id: row["ship_type_id"],
      ship_type_name: resolve_ship_type_name(row["ship_type_id"]),
      base_id: row["base_id"],
      status: :active,
      departed_at: nil,
      last_seen_in_roster_at: now
    }

    case CorpRosterSnapshot.by_character_id(character_id, authorize?: false) do
      {:ok, existing} ->
        {:ok, _} = CorpRosterSnapshot.update(existing, attrs, authorize?: false)

      {:error, _not_found} ->
        {:ok, _} = CorpRosterSnapshot.create(attrs, authorize?: false)
    end

    character_id
  end

  defp mark_departed!(corporation_id, seen_character_ids, now) do
    {:ok, current} = CorpRosterSnapshot.active_by_corporation(corporation_id, authorize?: false)

    current
    |> Enum.reject(&(&1.character_id in seen_character_ids))
    |> Enum.each(fn snapshot ->
      {:ok, _} =
        CorpRosterSnapshot.update(snapshot, %{status: :departed, departed_at: now},
          authorize?: false
        )
    end)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _error -> nil
    end
  end

  defp parse_datetime(_other), do: nil
end
