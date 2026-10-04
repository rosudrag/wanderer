defmodule WandererApp.Scout.Ingest do
  @moduledoc """
  CHEWY PATCH: turns rows of eveknob's scout logs into
  `WandererApp.Api.ScoutSpawnSighting` / `WandererApp.Api.
  ScoutStructureSighting` rows.

  The client is an InnerSpace/LavishScript bot tailing two append-only
  TSV files (`Config/Logs/special_spawns.tsv`,
  `Config/Logs/structures.tsv`). That shapes every decision here:

    * **Field names are the TSV's, not ours.** A row may arrive with the
      raw column names (`utc_timestamp`, `system_id`) or the resource's
      own (`observed_at`, `solar_system_id`); both are accepted, so the
      client never has to maintain a translation table.
      `structures.tsv`'s `type_name` column is really the player-set
      structure name — accepted under that name, stored as
      `structure_name`.

    * **The observing character is dropped, not stored.** Both scout
      resources deliberately carry no submitter attribution, so a
      `character` / `character_name` key in an incoming row is ignored
      rather than rejected — an older client keeps working unchanged.

    * **Every value may arrive as a string.** LavishScript has no JSON
      types; `${Entity.IsStructureVulnerable}` stringifies to `"TRUE"`,
      an absent field to `""`. So booleans, integers and floats are all
      coerced from text, and an unparseable optional value becomes `nil`
      rather than failing the row — a log line with a garbled shield
      percentage is still worth keeping.

    * **Re-sends are normal, not an error.** Writes go through each
      resource's `:upsert` action on its natural identity, so a client
      that restarts and re-posts the last 200 lines produces 0 new rows.

  A batch is processed row by row and reports per-row failures rather
  than rejecting the whole payload: one malformed line in a tailed file
  must not cost the other 199.

  A batch that stored anything broadcasts `{:scout_intel_ingested,
  :spawns | :structures}` on the `"scout_intel"` topic, which is what
  makes `WandererAppWeb.ScoutIntelLive` show a freshly reinforced
  structure without a reload. Fire-and-forget: nothing about the ingest
  depends on a subscriber existing.
  """

  require Logger

  alias WandererApp.Api.{ScoutSpawnSighting, ScoutStructureSighting}
  alias WandererApp.CachedInfo

  # An upper bound on one POST. The client posts incrementally; a batch
  # larger than this is a bug or an abuse, and either way is worth an
  # explicit error instead of a multi-second transaction.
  @max_batch 1_000

  # Kept small on purpose: the response is a diagnostic for a bot author,
  # not a data channel. The count is always exact; the list is a sample.
  @max_reported_errors 20

  @type result :: %{
          required(:received) => non_neg_integer(),
          required(:stored) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:errors) => [%{index: non_neg_integer(), error: String.t()}]
        }

  @doc """
  Ingests special-spawn rows. `map_id` is recorded as provenance (which
  map's API key authenticated the post); the log is not map-scoped.
  """
  @spec ingest_spawns([map()], Ecto.UUID.t() | nil) :: {:ok, result()} | {:error, term()}
  def ingest_spawns(rows, map_id) when is_list(rows) do
    ingest(rows, map_id, &spawn_attrs/2, &ScoutSpawnSighting.upsert/2, :spawns)
  end

  def ingest_spawns(_rows, _map_id), do: {:error, :rows_must_be_a_list}

  @doc """
  Ingests structure-observation rows. See the module doc for the two
  traps in the source file (stale header, misnamed `type_name`).
  """
  @spec ingest_structures([map()], Ecto.UUID.t() | nil) :: {:ok, result()} | {:error, term()}
  def ingest_structures(rows, map_id) when is_list(rows) do
    ingest(rows, map_id, &structure_attrs/2, &ScoutStructureSighting.upsert/2, :structures)
  end

  def ingest_structures(_rows, _map_id), do: {:error, :rows_must_be_a_list}

  # ---------------------------------------------------------------------
  # Batch driver
  # ---------------------------------------------------------------------

  defp ingest(rows, _map_id, _build, _write, _kind) when length(rows) > @max_batch,
    do: {:error, {:batch_too_large, @max_batch}}

  defp ingest(rows, map_id, build, write, kind) do
    {stored, failed, errors} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({0, 0, []}, fn {row, index}, {stored, failed, errors} ->
        case store_row(row, index, map_id, build, write) do
          :ok ->
            {stored + 1, failed, errors}

          {:error, message} ->
            {stored, failed + 1, [%{index: index, error: message} | errors]}
        end
      end)

    if stored > 0, do: announce(kind)

    {:ok,
     %{
       received: length(rows),
       stored: stored,
       failed: failed,
       errors: errors |> Enum.reverse() |> Enum.take(@max_reported_errors)
     }}
  end

  # An open page refreshes the affected table; the payload is only the
  # kind, because the page re-reads under its own filters anyway.
  defp announce(kind) do
    Phoenix.PubSub.broadcast(WandererApp.PubSub, "scout_intel", {:scout_intel_ingested, kind})
  catch
    _, _ -> :ok
  end

  defp store_row(row, _index, map_id, build, write) when is_map(row) do
    with {:ok, attrs} <- build.(row, map_id),
         {:ok, _record} <- write.(attrs, authorize?: false) do
      :ok
    else
      {:error, %Ash.Error.Invalid{} = error} -> {:error, Exception.message(error)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp store_row(_row, _index, _map_id, _build, _write), do: {:error, "row must be an object"}

  # ---------------------------------------------------------------------
  # Row -> attributes
  # ---------------------------------------------------------------------

  defp spawn_attrs(row, map_id) do
    with {:ok, observed_at} <- required_time(row, ["utc_timestamp", "observed_at", "timestamp"]),
         {:ok, system_id} <- required_int(row, ["system_id", "solar_system_id"]) do
      {:ok,
       %{
         observed_at: observed_at,
         solar_system_id: system_id,
         solar_system_name: resolve_system_name(system_id, row),
         system_truesec: float(row, ["system_truesec"]),
         location_type: string(row, ["location_type"]),
         # Identity components: "" not nil, or Postgres stops enforcing
         # uniqueness on the row (NULL <> NULL).
         location_name: string(row, ["location_name"]) || "",
         spawn_name: string(row, ["spawn_name"]) || "",
         spawn_category: string(row, ["spawn_category"]),
         anomaly_type: string(row, ["anomaly_type"]),
         players_in_local: int(row, ["players_in_local"]),
         action_taken: string(row, ["action_taken"]),
         outcome: string(row, ["outcome"]),
         entity_id: int(row, ["entity_id"]),
         minutes_since_downtime: int(row, ["minutes_since_downtime"]),
         isk_value: decimal(row, ["isk_value"]),
         map_id: map_id
       }}
    end
  end

  defp structure_attrs(row, map_id) do
    with {:ok, observed_at} <- required_time(row, ["utc_timestamp", "observed_at", "timestamp"]),
         {:ok, system_id} <- required_int(row, ["system_id", "solar_system_id"]),
         {:ok, structure_id} <- required_int(row, ["structure_id"]),
         {:ok, event} <- event(row) do
      timer_seconds = timer_seconds(row)

      {:ok,
       %{
         observed_at: observed_at,
         event: event,
         solar_system_id: system_id,
         solar_system_name: resolve_system_name(system_id, row),
         system_truesec: float(row, ["system_truesec"]),
         structure_id: structure_id,
         type_id: int(row, ["type_id"]),
         # `type_name` is the source column; it holds Entity.Name.
         structure_name: string(row, ["structure_name", "type_name"]),
         group_name: string(row, ["group_name"]),
         owner_id: int(row, ["owner_id"]),
         owner_name: string(row, ["owner_name"]),
         alliance_id: int(row, ["alliance_id"]),
         upkeep_state: int(row, ["upkeep_state"]),
         structure_state: int(row, ["structure_state"]),
         # Computed client-side (eveknob) per the precedence table in
         # docs/chewy/scout-intel.md. The bot is authoritative: never
         # re-derived here from upkeep_state/structure_state/unanchoring.
         status: string(row, ["status"]),
         vulnerable: bool(row, ["vulnerable"]),
         anchoring: bool(row, ["anchoring"]),
         unanchoring: bool(row, ["unanchoring"]),
         timer_seconds: timer_seconds,
         timer_expires_at: expires_at(observed_at, timer_seconds),
         shield_pct: int(row, ["shield_pct"]),
         armor_pct: int(row, ["armor_pct"]),
         hull_pct: int(row, ["hull_pct"]),
         distance_m: int(row, ["distance_m"]),
         nearest_celestial: string(row, ["nearest_celestial"]),
         nearest_celestial_m: int(row, ["nearest_celestial_m"]),
         map_id: map_id
       }}
    end
  end

  # Resolves the solar system name server-side rather than trusting the
  # client. The client used to send `system_name` / `solar_system_name`
  # alongside `system_id`; a bug in one `obj_StructureWatch` code path
  # fell back to the raw numeric ID when the name had not resolved yet,
  # and ~35% of live rows carried that digit string as the "name". The
  # client no longer sends the field at all, but an older client might
  # still post one, so it is kept as a last-resort fallback -- EXCEPT
  # when it is all digits, which is exactly the defect above and worth
  # treating as absent rather than stored as a name.
  #
  # `CachedInfo.get_system_static_info!/1` is the same Cachex-backed
  # lookup `ScoutIntelLive` uses to resolve names at read time; despite
  # the `!`, it swallows its own errors and returns `nil` rather than
  # raising. The `try/rescue` below is extra insurance against any
  # future change to that contract: one bad row must cost one row, never
  # the batch.
  defp resolve_system_name(system_id, row) do
    case CachedInfo.get_system_static_info!(system_id) do
      %{solar_system_name: name} when is_binary(name) ->
        case String.trim(name) do
          "" -> client_system_name(row)
          trimmed -> trimmed
        end

      _ ->
        client_system_name(row)
    end
  rescue
    _ -> client_system_name(row)
  end

  defp client_system_name(row) do
    case string(row, ["system_name", "solar_system_name"]) do
      nil -> nil
      value -> if numeric_string?(value), do: nil, else: value
    end
  end

  defp numeric_string?(value), do: String.match?(value, ~r/^[0-9]+$/)

  # "SEEN"/"CHANGE" from the writer; anything else is a row we do not
  # understand, and guessing :seen would quietly corrupt the identity.
  defp event(row) do
    case string(row, ["event"]) do
      nil -> {:ok, :seen}
      value -> parse_event(String.downcase(value))
    end
  end

  defp parse_event("seen"), do: {:ok, :seen}
  defp parse_event("change"), do: {:ok, :change}
  defp parse_event(other), do: {:error, "unknown event #{inspect(other)}, expected SEEN or CHANGE"}

  # -1 is the writer's "no timer" sentinel. Older rows can also carry a
  # boolean here (the two columns added ahead of it shifted the field on
  # clients that had not updated); `int/2` returns nil for those.
  defp timer_seconds(row) do
    case int(row, ["timer_seconds"]) do
      nil -> nil
      seconds when seconds <= 0 -> nil
      seconds -> seconds
    end
  end

  defp expires_at(_observed_at, nil), do: nil

  defp expires_at(observed_at, seconds),
    do: observed_at |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  # ---------------------------------------------------------------------
  # Coercion. Optional values never fail a row; required ones do.
  # ---------------------------------------------------------------------

  defp required_time(row, keys) do
    case time(row, keys) do
      nil -> {:error, "missing or unparseable #{hd(keys)}"}
      value -> {:ok, value}
    end
  end

  defp required_int(row, keys) do
    case int(row, keys) do
      nil -> {:error, "missing or unparseable #{hd(keys)}"}
      value -> {:ok, value}
    end
  end

  defp fetch(row, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(row, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp string(row, keys) do
    case fetch(row, keys) do
      nil -> nil
      value when is_binary(value) -> value |> String.trim() |> nil_if_empty()
      value -> to_string(value)
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  defp int(row, keys) do
    case fetch(row, keys) do
      nil ->
        nil

      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case value |> String.trim() |> Integer.parse() do
          {parsed, _rest} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp float(row, keys) do
    case fetch(row, keys) do
      nil ->
        nil

      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value * 1.0

      value when is_binary(value) ->
        case value |> String.trim() |> Float.parse() do
          {parsed, _rest} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp decimal(row, keys) do
    case fetch(row, keys) do
      nil ->
        nil

      value when is_integer(value) ->
        Decimal.new(value)

      value when is_float(value) ->
        Decimal.from_float(value)

      value when is_binary(value) ->
        case value |> String.trim() |> Decimal.parse() do
          {parsed, _rest} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp bool(row, keys) do
    case fetch(row, keys) do
      nil -> nil
      value when is_boolean(value) -> value
      value when is_binary(value) -> parse_bool(value |> String.trim() |> String.downcase())
      _ -> nil
    end
  end

  defp parse_bool(value) when value in ~w(true 1 yes), do: true
  defp parse_bool(value) when value in ~w(false 0 no), do: false
  defp parse_bool(_), do: nil

  # The writer emits "YYYY-MM-DD HH:MM:SS" (UTC, no zone marker) for
  # `utc_timestamp` and "MM/DD/YYYY HH:MM:SS" for the local `timestamp`
  # fallback. ISO8601 is accepted too, for any future client.
  defp time(row, keys) do
    case fetch(row, keys) do
      nil -> nil
      %DateTime{} = value -> DateTime.truncate(value, :second)
      %NaiveDateTime{} = value -> from_naive(value)
      value when is_binary(value) -> parse_time(String.trim(value))
      _ -> nil
    end
  end

  defp parse_time(value) do
    with :error <- iso8601(value),
         :error <- naive(value),
         :error <- naive(String.replace(value, " ", "T")),
         :error <- us_slash(value) do
      nil
    else
      %DateTime{} = parsed -> parsed
    end
  end

  defp iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> DateTime.truncate(parsed, :second)
      {:error, _reason} -> :error
    end
  end

  defp naive(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, parsed} -> from_naive(parsed)
      {:error, _reason} -> :error
    end
  end

  # "09/08/2026 11:48:34" -- the client's local-time column, used only if
  # utc_timestamp is absent. Treated as UTC because no offset is recorded;
  # that is why utc_timestamp is preferred.
  defp us_slash(value) do
    with [date, clock] <- String.split(value, " ", parts: 2),
         [month, day, year] <- String.split(date, "/"),
         {:ok, date} <- build_date(year, month, day),
         {:ok, clock} <- Time.from_iso8601(clock),
         {:ok, naive} <- NaiveDateTime.new(date, clock) do
      from_naive(naive)
    else
      _ -> :error
    end
  end

  defp build_date(year, month, day) do
    with {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day) do
      Date.new(year, month, day)
    else
      _ -> :error
    end
  end

  defp from_naive(naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)
end
