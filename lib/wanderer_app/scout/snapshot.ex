defmodule WandererApp.Scout.Snapshot do
  @moduledoc """
  CHEWY PATCH: the structure presence feed. A sweep posts the COMPLETE
  set of structures it can see plus the sphere it proves; this module
  diffs that against `WandererApp.Api.ScoutStructure`'s current-state
  table and derives `appeared` / `changed` / `cleared` / `missing` /
  `gone`. See `docs/design/wanderer-scout-presence.md` for the full
  contract -- this module is that design, not a redesign of it.

  Two clearly separated halves:

    * `diff/2` -- pure, unit-tested in isolation
      (`test/wanderer_app/scout/snapshot_test.exs`), takes plain data in
      and hands plain data back. No Ash call, no clock read.
    * `ingest/2` -- impure: validates the wire payload, loads current
      state for the blob's system, calls `diff/2`, and applies the
      result as writes + one broadcast.

  ## Wire contract: every value is a STRING

  The client's only JSON escaping primitive always emits quoted
  strings -- the existing per-row feed
  (`WandererApp.Scout.Ingest`) already lives with this. So every
  coercion helper below accepts a string OR the native JSON type (cheap,
  and keeps a hand-written curl probe working): `"30000142"` and
  `30000142` both parse to the same integer. `observer` is NOT nested
  (`observer_x`/`observer_y`/`observer_z`, flat) and `steady_ids` is an
  array of id strings -- both deliberate, so the client never needs a
  second escaping layer. An empty string and an absent key are the same
  absence, the same rule `WandererApp.Map.Operations.SignatureSync`'s
  `normalize_value/1` already applies.

  ## The clean cutover

  The client that emits this blob stops posting to the old
  `POST /scout/structures` row feed entirely once this lands.
  `scout_structure_sightings_v1` and its route keep working, for older
  clients and because the backfill migration reads from it, but new rows
  are not assumed to keep arriving there once a map's bot has moved to
  this feed.
  """

  require Ash.Query
  require Logger

  alias WandererApp.Api.{ScoutStructure, ScoutStructureEvent}
  alias WandererApp.Scout.Status

  # Mirrors WandererApp.Scout.Merge's own tolerance and reasoning: a
  # relative `timer_seconds` is re-read every sweep and drifts by the gap
  # between the client's read and the POST, so an exact compare would
  # mark every blob a change.
  @timer_tolerance_seconds 120

  # Two absences, from distinct visits, more than this far apart promote
  # a `:missing` structure to `:gone`. See diff/2 doc and
  # docs/design/wanderer-scout-presence.md section 5.
  @gone_after_seconds 30 * 60

  # Fields a direct sighting (`structures[]`) can make "news" on an
  # already-known structure. Reuses the spirit of
  # `WandererApp.Scout.Merge.changed_fields/0`; `timer_expires_at` is
  # compared separately, with the same tolerance.
  @tracked_fields [
    :status,
    :owner_id,
    :owner_name,
    :alliance_id,
    :structure_name,
    :group_name,
    :vulnerable,
    :anchoring,
    :unanchoring,
    :upkeep_state,
    :structure_state,
    :shield_pct,
    :armor_pct,
    :hull_pct
  ]

  @max_ids 1_000
  @max_reported_errors 20

  # ---------------------------------------------------------------------
  # Pure half
  # ---------------------------------------------------------------------

  @doc """
  Diffs one normalized blob against the known current-state rows for its
  system. Pure: `known` and `blob` are plain data (structs or maps with
  the fields below), no DB access, no clock read.

  `known` rows need: `:structure_id`, `:presence`, `:pos_x`/`:pos_y`/
  `:pos_z`, `:status`, and every field in the tracked-fields list plus
  `:timer_expires_at`.

  `blob` is `%{structures: [...], steady_ids: [...], observer: %{x:,y:,
  z:}, horizon_m:, complete?:}` -- the shape `normalize/1` produces.
  Each `blob.structures` entry needs `:structure_id` plus every tracked
  field and `:timer_expires_at`.

  Returns `%{appeared:, changed:, cleared:, missing:, unchanged:}`:

    * `appeared` -- blob structure maps whose id is not in `known`.
    * `changed` -- `%{known:, blob:, changed_fields:}` for ids in both,
      where a tracked field (or the timer, outside tolerance) differs.
    * `cleared` -- `%{known:}` for `steady_ids` ids in `known` whose
      stored `status` was NOT already in `Status.steady_family/0` -- a
      genuine "went boring" transition. A `steady_ids` id not in `known`
      yields nothing: a healthy structure this feed never had a reason
      to track is not created from a bare id.
    * `missing` -- known rows "in scope" (see below) that are in
      neither `structures[]` nor `steady_ids`.
    * `unchanged` -- `%{known:, blob:}` for every positive confirmation
      that is not news: a `structures[]` entry matching `known` on every
      tracked field, OR a `steady_ids` id whose stored `status` was
      ALREADY steady (`blob:` is `nil` in that case -- a steady id
      carries no record to re-apply).

  ## `in_scope`, and the one deliberate departure from the literal
  formula

  `docs/design/wanderer-scout-presence.md` section 5 writes
  `in_scope = known where presence in (:seen, :cleared) and position
  is not null and dist(...) <= horizon_m`. Taken completely literally,
  a structure's OWN first `:missing` tick would retire it from
  `in_scope` on every later blob (its stored `presence` is now
  `:missing`), which makes the two-absences-30-minutes-apart `:gone`
  path -- required by this module's own test suite and by the design
  doc's section 5 prose two sentences later -- unreachable by
  construction. The coherent reading, implemented here: `in_scope`
  excludes only `:gone` (a presence this module treats as inactive
  until a positive re-sighting, which is checked against ALL of
  `known` regardless of presence, same as `appeared`/`changed`/
  `cleared`). `:missing` stays eligible for a second, third, ... miss,
  which is what lets `missing_count` ever reach 2.
  """
  @spec diff([map()], map()) :: %{
          appeared: [map()],
          changed: [map()],
          cleared: [map()],
          missing: [map()],
          unchanged: [map()]
        }
  def diff(known, blob) do
    known_by_id = Map.new(known, &{&1.structure_id, &1})
    steady_ids = MapSet.new(Map.get(blob, :steady_ids, []))
    blob_structures = Map.get(blob, :structures, [])
    blob_ids = MapSet.new(blob_structures, & &1.structure_id)
    complete? = Map.get(blob, :complete?, true)

    {appeared, changed, unchanged_direct} = diff_structures(blob_structures, known_by_id)
    {cleared, unchanged_steady} = diff_steady(steady_ids, known_by_id)

    missing =
      if complete? do
        known
        |> Enum.filter(&in_scope?(&1, blob))
        |> Enum.reject(&(MapSet.member?(blob_ids, &1.structure_id) or MapSet.member?(steady_ids, &1.structure_id)))
      else
        []
      end

    %{
      appeared: Enum.reverse(appeared),
      changed: Enum.reverse(changed),
      cleared: Enum.reverse(cleared),
      missing: missing,
      unchanged: Enum.reverse(unchanged_direct) ++ Enum.reverse(unchanged_steady)
    }
  end

  defp diff_structures(blob_structures, known_by_id) do
    Enum.reduce(blob_structures, {[], [], []}, fn structure, {appeared, changed, unchanged} ->
      case Map.get(known_by_id, structure.structure_id) do
        nil ->
          {[structure | appeared], changed, unchanged}

        known_row ->
          case tracked_changes(known_row, structure) do
            [] ->
              {appeared, changed, [%{known: known_row, blob: structure} | unchanged]}

            fields ->
              entry = %{known: known_row, blob: structure, changed_fields: fields}
              {appeared, [entry | changed], unchanged}
          end
      end
    end)
  end

  defp diff_steady(steady_ids, known_by_id) do
    Enum.reduce(steady_ids, {[], []}, fn id, {cleared, unchanged} ->
      case Map.get(known_by_id, id) do
        nil ->
          {cleared, unchanged}

        known_row ->
          if already_steady?(known_row.status) do
            {cleared, [%{known: known_row, blob: nil} | unchanged]}
          else
            {[%{known: known_row} | cleared], unchanged}
          end
      end
    end)
  end

  defp already_steady?(status), do: status in Status.steady_family()

  defp tracked_changes(known, blob) do
    simple = Enum.filter(@tracked_fields, &(Map.get(known, &1) != Map.get(blob, &1)))

    if same_timer?(known.timer_expires_at, blob.timer_expires_at) do
      simple
    else
      simple ++ [:timer_expires_at]
    end
  end

  defp same_timer?(nil, nil), do: true
  defp same_timer?(nil, _new), do: false
  defp same_timer?(_old, nil), do: false

  defp same_timer?(old, new),
    do: abs(DateTime.diff(old, new, :second)) <= @timer_tolerance_seconds

  defp in_scope?(%{presence: :gone}, _blob), do: false

  defp in_scope?(row, blob) do
    not is_nil(row.pos_x) and not is_nil(row.pos_y) and not is_nil(row.pos_z) and
      within_horizon?(row, blob.observer, blob.horizon_m)
  end

  defp within_horizon?(row, observer, horizon_m) do
    dx = row.pos_x - observer.x
    dy = row.pos_y - observer.y
    dz = row.pos_z - observer.z
    :math.sqrt(dx * dx + dy * dy + dz * dz) <= horizon_m
  end

  @doc "The gone-promotion window -- exported for the test suite and for ingest/2."
  @spec gone_after_seconds() :: pos_integer()
  def gone_after_seconds, do: @gone_after_seconds

  @doc """
  Whether a structure that just missed again (or for the first time)
  should be promoted straight to `:gone`.

  `missing_count` / `missing_since` are the values AFTER this miss is
  counted (the caller increments first). `status` / `timer_expires_at`
  are the structure's own, unaffected by an absence.
  """
  @spec gone?(non_neg_integer(), DateTime.t(), DateTime.t(), String.t() | nil, DateTime.t() | nil) ::
          boolean()
  def gone?(missing_count, missing_since, observed_at, status, timer_expires_at) do
    count_path =
      missing_count >= 2 and DateTime.diff(observed_at, missing_since, :second) >= @gone_after_seconds

    timer_path =
      status in ["Unanchoring", "Unanchored"] and not is_nil(timer_expires_at) and
        DateTime.compare(timer_expires_at, observed_at) == :lt

    count_path or timer_path
  end

  # ---------------------------------------------------------------------
  # Impure half
  # ---------------------------------------------------------------------

  @doc """
  Validates, normalizes, loads current state for the blob's system,
  diffs, and applies the result. `map_id` is recorded as provenance
  only.

  Returns `{:ok, result}` with
  `%{structures:, steady:, appeared:, changed:, cleared:, missing:,
  gone:, skipped:, errors:}`, or `{:error, reason}` for a payload this
  module refuses outright (never half-applied).
  """
  @spec ingest(Ecto.UUID.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def ingest(map_id, params) when is_map(params) do
    with {:ok, blob} <- normalize(params) do
      apply_diff(map_id, blob)
    end
  end

  def ingest(_map_id, _params), do: {:error, "payload must be a JSON object"}

  # -----------------------------------------------------------------
  # normalize/1 -- wire -> internal shape
  # -----------------------------------------------------------------

  @doc false
  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(params) do
    structures_raw = Map.get(params, "structures") || []
    steady_raw = Map.get(params, "steady_ids") || []

    with :ok <- require_list(structures_raw, "structures"),
         :ok <- require_list(steady_raw, "steady_ids"),
         :ok <- require_non_empty(structures_raw, steady_raw),
         :ok <- require_batch_size(structures_raw, steady_raw),
         {:ok, solar_system_id} <- required_int(params, "solar_system_id"),
         {:ok, observed_at} <- required_time(params, "observed_at"),
         {:ok, observer} <- required_observer(params),
         {:ok, horizon_m} <- required_horizon(params) do
      {kept_structures, structure_errors} =
        normalize_structures(structures_raw, solar_system_id, observed_at)

      {kept_steady, steady_skipped} = normalize_steady_ids(steady_raw)

      # Completeness is the AND of two independent claims, because either
      # side can be the one that knows the census is short. The CLIENT sets
      # `complete: false` when it could not render every structure it saw
      # (a malformed row, or an id list over its own cap); the SERVER adds
      # its own veto when a row failed coercion here. Only a blob both
      # agree is whole may archive anything -- `diff/2` computes
      # `missing: []` otherwise. A missing `complete` key means "true":
      # older clients and hand-written probes do not send it.
      {:ok,
       %{
         solar_system_id: solar_system_id,
         observed_at: observed_at,
         observer: observer,
         horizon_m: horizon_m,
         structures: kept_structures,
         steady_ids: kept_steady,
         complete?: bool(Map.get(params, "complete")) != false and structure_errors == [],
         raw_structures_count: length(structures_raw),
         raw_steady_count: length(steady_raw),
         skipped: length(structure_errors) + steady_skipped,
         errors: structure_errors |> Enum.reverse() |> Enum.take(@max_reported_errors)
       }}
    end
  end

  defp require_list(value, _field) when is_list(value), do: :ok
  defp require_list(_value, field), do: {:error, "#{field} must be an array"}

  defp require_non_empty([], []), do: {:error, :no_observation}
  defp require_non_empty(_structures, _steady), do: :ok

  defp require_batch_size(structures, steady) do
    if length(structures) + length(steady) > @max_ids do
      {:error, {:batch_too_large, @max_ids}}
    else
      :ok
    end
  end

  defp required_int(params, key) do
    case int(Map.get(params, key)) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp required_time(params, key) do
    case time(Map.get(params, key)) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp required_observer(params) do
    with x when not is_nil(x) <- float(Map.get(params, "observer_x")),
         y when not is_nil(y) <- float(Map.get(params, "observer_y")),
         z when not is_nil(z) <- float(Map.get(params, "observer_z")) do
      {:ok, %{x: x, y: y, z: z}}
    else
      nil -> {:error, "observer_x, observer_y and observer_z are required"}
    end
  end

  defp required_horizon(params) do
    case float(Map.get(params, "horizon_m")) do
      value when is_float(value) and value > 0 -> {:ok, value}
      _ -> {:error, "horizon_m is required and must be greater than 0"}
    end
  end

  defp normalize_structures(rows, solar_system_id, observed_at) do
    rows
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {row, index}, {kept, errors} ->
      case structure_attrs(row, solar_system_id, observed_at) do
        {:ok, attrs} -> {[attrs | kept], errors}
        {:error, message} -> {kept, [%{index: index, error: message} | errors]}
      end
    end)
    |> then(fn {kept, errors} -> {Enum.reverse(kept), errors} end)
  end

  defp structure_attrs(row, solar_system_id, observed_at) when is_map(row) do
    case required_int(row, "structure_id") do
      {:ok, structure_id} ->
        timer_seconds = positive_int(row, "timer_seconds")

        {:ok,
         %{
           structure_id: structure_id,
           solar_system_id: solar_system_id,
           type_id: int(Map.get(row, "type_id")),
           structure_name: str(row, ["type_name", "structure_name"]),
           group_name: str(row, ["group_name"]),
           owner_id: int(Map.get(row, "owner_id")),
           owner_name: str(row, ["owner_name"]),
           alliance_id: int(Map.get(row, "alliance_id")),
           upkeep_state: int(Map.get(row, "upkeep_state")),
           structure_state: int(Map.get(row, "structure_state")),
           status: str(row, ["status"]),
           vulnerable: bool(Map.get(row, "vulnerable")),
           anchoring: bool(Map.get(row, "anchoring")),
           unanchoring: bool(Map.get(row, "unanchoring")),
           timer_seconds: timer_seconds,
           timer_expires_at: expires_at(observed_at, timer_seconds),
           shield_pct: int(Map.get(row, "shield_pct")),
           armor_pct: int(Map.get(row, "armor_pct")),
           hull_pct: int(Map.get(row, "hull_pct")),
           pos_x: float(Map.get(row, "pos_x")),
           pos_y: float(Map.get(row, "pos_y")),
           pos_z: float(Map.get(row, "pos_z"))
         }
         |> fill_position()
         |> Map.put(:nearest_celestial, str(row, ["nearest_celestial"]))
         |> Map.put(:nearest_celestial_m, int(Map.get(row, "nearest_celestial_m")))}

      {:error, _} ->
        {:error, "missing or unparseable structure_id"}
    end
  end

  defp structure_attrs(_row, _solar_system_id, _observed_at),
    do: {:error, "structure row must be an object"}

  # A partial position proves nothing: distance math needs all three, so
  # anything less than a complete reading is treated the same as "not
  # resolved yet" -- fail-open, same discipline `nearest_celestial`
  # already uses.
  defp fill_position(%{pos_x: x, pos_y: y, pos_z: z} = attrs)
       when is_nil(x) or is_nil(y) or is_nil(z),
       do: %{attrs | pos_x: nil, pos_y: nil, pos_z: nil}

  defp fill_position(attrs), do: attrs

  defp normalize_steady_ids(ids) do
    Enum.reduce(ids, {[], 0}, fn raw, {kept, skipped} ->
      case int(raw) do
        nil -> {kept, skipped + 1}
        id -> {[id | kept], skipped}
      end
    end)
    |> then(fn {kept, skipped} -> {kept |> Enum.reverse() |> Enum.uniq(), skipped} end)
  end

  defp positive_int(row, key) do
    case int(Map.get(row, key)) do
      nil -> nil
      seconds when seconds <= 0 -> nil
      seconds -> seconds
    end
  end

  defp expires_at(_observed_at, nil), do: nil

  defp expires_at(observed_at, seconds),
    do: observed_at |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  # -----------------------------------------------------------------
  # Coercion -- every wire value may be a string (see @moduledoc). "" and
  # nil are the same absence.
  # -----------------------------------------------------------------

  defp str(row, keys) do
    Enum.find_value(keys, fn key -> str(Map.get(row, key)) end)
  end

  defp str(nil), do: nil
  defp str(""), do: nil
  defp str(value) when is_binary(value), do: value |> String.trim() |> nil_if_empty()
  defp str(value), do: to_string(value)

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  defp int(nil), do: nil
  defp int(""), do: nil
  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)

  defp int(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp int(_value), do: nil

  defp float(nil), do: nil
  defp float(""), do: nil
  defp float(value) when is_float(value), do: value
  defp float(value) when is_integer(value), do: value * 1.0

  defp float(value) when is_binary(value) do
    case value |> String.trim() |> Float.parse() do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp float(_value), do: nil

  defp bool(nil), do: nil
  defp bool(""), do: nil
  defp bool(value) when is_boolean(value), do: value
  defp bool(value) when is_binary(value), do: parse_bool(value |> String.trim() |> String.downcase())
  defp bool(_value), do: nil

  defp parse_bool(value) when value in ~w(true 1 yes), do: true
  defp parse_bool(value) when value in ~w(false 0 no), do: false
  defp parse_bool(_value), do: nil

  # EVE server time as unix-epoch seconds, as a string ("1759574400") or
  # a native number -- the normal case -- or ISO8601, kept for parity
  # with the coverage feed and for hand-written probes.
  defp time(nil), do: nil
  defp time(""), do: nil
  defp time(%DateTime{} = value), do: DateTime.truncate(value, :second)

  defp time(value) when is_integer(value),
    do: value |> DateTime.from_unix!() |> DateTime.truncate(:second)

  defp time(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {seconds, ""} -> time(seconds)
      _ -> iso8601(trimmed)
    end
  end

  defp time(_value), do: nil

  defp iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> DateTime.truncate(parsed, :second)
      {:error, _reason} -> nil
    end
  end

  # -----------------------------------------------------------------
  # Apply -- loads known state, diffs, writes, broadcasts.
  # -----------------------------------------------------------------

  defp apply_diff(map_id, blob) do
    known = load_known(blob.solar_system_id)
    diffs = diff(known, blob)

    appeared = apply_appeared(diffs.appeared, blob, map_id)
    {changed, changed_skipped} = apply_changed(diffs.changed, blob, map_id)
    {cleared, cleared_skipped} = apply_cleared(diffs.cleared, blob, map_id)
    {unchanged, unchanged_skipped} = apply_unchanged(diffs.unchanged, blob)
    {missing, gone, missing_skipped} = apply_missing(diffs.missing, blob, map_id)

    stored? = appeared > 0 or changed > 0 or cleared > 0 or missing > 0 or unchanged > 0
    if stored?, do: announce()

    {:ok,
     %{
       structures: blob.raw_structures_count,
       steady: blob.raw_steady_count,
       appeared: appeared,
       changed: changed,
       cleared: cleared,
       missing: missing,
       gone: gone,
       skipped:
         blob.skipped + changed_skipped + cleared_skipped + unchanged_skipped + missing_skipped,
       errors: blob.errors
     }}
  end

  defp load_known(solar_system_id) do
    ScoutStructure
    |> Ash.Query.filter(solar_system_id == ^solar_system_id)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  # A blob older than a structure's stored `last_confirmed_at` must never
  # drag it backwards -- the discipline `Scout.Merge.not_older?/2`
  # already applies per row on the sighting feed.
  defp stale?(known_row, observed_at),
    do: DateTime.compare(observed_at, known_row.last_confirmed_at) == :lt

  defp apply_appeared(appeared, blob, map_id) do
    Enum.count(appeared, fn structure ->
      attrs =
        structure
        |> Map.put(:presence, :seen)
        |> Map.put(:first_seen_at, blob.observed_at)
        |> Map.put(:last_confirmed_at, blob.observed_at)
        |> Map.put(:map_id, map_id)

      case ScoutStructure.create(attrs, authorize?: false) do
        {:ok, _record} ->
          write_event(:appeared, structure.structure_id, blob, nil, structure.status, [], map_id)
          true

        {:error, reason} ->
          Logger.warning("[Scout.Snapshot] appeared insert failed: #{inspect(reason)}")
          false
      end
    end)
  end

  defp apply_changed(changed, blob, map_id) do
    Enum.reduce(changed, {0, 0}, fn %{known: known, blob: structure, changed_fields: fields},
                                     {ok, skipped} ->
      if stale?(known, blob.observed_at) do
        {ok, skipped + 1}
      else
        attrs =
          structure
          |> Map.put(:last_changed_at, blob.observed_at)
          |> Map.put(:last_confirmed_at, blob.observed_at)
          |> Map.put(:missing_count, 0)
          |> Map.put(:missing_since, nil)
          |> Map.put(:presence, :seen)
          |> Map.put(:map_id, map_id)

        case update(known, attrs) do
          {:ok, _record} ->
            write_event(
              :changed,
              known.structure_id,
              blob,
              known.status,
              structure.status,
              Enum.map(fields, &to_string/1),
              map_id
            )

            {ok + 1, skipped}

          {:error, reason} ->
            Logger.warning("[Scout.Snapshot] changed update failed: #{inspect(reason)}")
            {ok, skipped + 1}
        end
      end
    end)
  end

  defp apply_cleared(cleared, blob, map_id) do
    Enum.reduce(cleared, {0, 0}, fn %{known: known}, {ok, skipped} ->
      if stale?(known, blob.observed_at) do
        {ok, skipped + 1}
      else
        attrs = %{
          presence: :cleared,
          last_confirmed_at: blob.observed_at,
          missing_count: 0,
          missing_since: nil
        }

        case update(known, attrs) do
          {:ok, _record} ->
            write_event(:cleared, known.structure_id, blob, known.status, known.status, [], map_id)
            {ok + 1, skipped}

          {:error, reason} ->
            Logger.warning("[Scout.Snapshot] cleared update failed: #{inspect(reason)}")
            {ok, skipped + 1}
        end
      end
    end)
  end

  # Positive confirmation, never news: no event row. A `structures[]`
  # match also carries the full blob record, which is re-applied here --
  # harmless (every tracked field is equal by construction) and lets a
  # newly-resolved position/nearest-celestial land even though neither
  # is itself a tracked field.
  defp apply_unchanged(unchanged, blob) do
    Enum.reduce(unchanged, {0, 0}, fn %{known: known, blob: structure}, {ok, skipped} ->
      if stale?(known, blob.observed_at) do
        {ok, skipped + 1}
      else
        base = structure || %{}

        attrs =
          base
          |> Map.put(:last_confirmed_at, blob.observed_at)
          |> Map.put(:missing_count, 0)
          |> Map.put(:missing_since, nil)
          |> Map.put(:presence, :seen)

        case update(known, attrs) do
          {:ok, _record} -> {ok + 1, skipped}
          {:error, reason} ->
            Logger.warning("[Scout.Snapshot] unchanged update failed: #{inspect(reason)}")
            {ok, skipped + 1}
        end
      end
    end)
  end

  defp apply_missing(missing, blob, map_id) do
    {missing_count, gone_count, skipped} =
      Enum.reduce(missing, {0, 0, 0}, fn known, {m, g, skipped} ->
        if stale?(known, blob.observed_at) do
          {m, g, skipped + 1}
        else
          new_count = known.missing_count + 1
          new_since = known.missing_since || blob.observed_at

          promote? =
            gone?(new_count, new_since, blob.observed_at, known.status, known.timer_expires_at)

          presence = if promote?, do: :gone, else: :missing

          attrs = %{
            missing_count: new_count,
            missing_since: new_since,
            presence: presence
          }

          case update(known, attrs) do
            {:ok, _record} ->
              kind = if promote?, do: :gone, else: :missing
              write_event(kind, known.structure_id, blob, known.status, known.status, [], map_id)
              if promote?, do: {m, g + 1, skipped}, else: {m + 1, g, skipped}

            {:error, reason} ->
              Logger.warning("[Scout.Snapshot] missing update failed: #{inspect(reason)}")
              {m, g, skipped + 1}
          end
        end
      end)

    {missing_count, gone_count, skipped}
  end

  defp update(known, attrs) do
    known
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(authorize?: false)
  end

  defp write_event(kind, structure_id, blob, status_before, status_after, changed_fields, map_id) do
    ScoutStructureEvent.create(
      %{
        structure_id: structure_id,
        solar_system_id: blob.solar_system_id,
        kind: kind,
        observed_at: blob.observed_at,
        status_before: status_before,
        status_after: status_after,
        changed_fields: changed_fields,
        map_id: map_id
      },
      authorize?: false
    )
  catch
    _, _ -> :ok
  end

  # Fire-and-forget, mirrors WandererApp.Scout.Ingest's announce/1: an
  # open /scout page refreshes under its own filters, nothing here
  # depends on a subscriber existing. Shares the alert cache invalidation
  # too -- an unanchored structure reported `:gone` or confirmed `:seen`
  # moves the sidebar badge.
  defp announce do
    WandererApp.Scout.Alerts.invalidate()
    Phoenix.PubSub.broadcast(WandererApp.PubSub, "scout_intel", {:scout_intel_ingested, :structures})
  catch
    _, _ -> :ok
  end
end
