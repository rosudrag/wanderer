defmodule WandererApp.Scout.Coverage do
  @moduledoc """
  CHEWY PATCH: turns rows of eveknob's scout-coverage reports into
  `WandererApp.Api.ScoutSystemCoverage` rows -- "I finished looking at
  system S to depth K at time T", recorded even when nothing was found.
  See `docs/design/wanderer-scout-planner.md` sections 1-4 and
  `WandererApp.Scout.Ingest` (the sighting-table sibling this mirrors).

  ## Latest-wins, with a staleness guard

  Unlike the sighting tables' append-only upsert, this identity
  (`solar_system_id`, `kind`) is a single current fact, so an incoming
  row whose `observed_at` is older than or equal to what is already
  stored is SKIPPED rather than written -- a batch retry or an
  out-of-order queue drain must never let a stale report win and make a
  freshly-scouted system look untouched again. The row still counts
  toward `stored` in the response: the ingest succeeded idempotently, it
  just had nothing newer to say. The check-then-write here is not
  transactionally race-free against a concurrent post for the same
  (system, kind) -- same tradeoff every other read-then-write guard in
  this codebase makes (see `AGENTS.md`'s `MapConnection` actor-less-read
  trap) -- but losing that race costs one stale overwrite, corrected by
  the next real observation, never a permanently wrong ranking.

  ## observed_at has two accepted shapes; everything else is `Ingest`'s coercion

  `solar_system_id`, `kind` and `observed_at` are required. `kind` must
  be one of `visit | anoms | sigs | grid` -- closed, unlike the sighting
  tables' free-text categories. `observed_at` is EVE server time
  (`${ISXBob.GameTimeInt64}` through `obj_EVETime.UTCFromFiletime`, the
  same clock `obj_SpawnLog.iss` uses) and is accepted as EITHER an
  ISO8601 UTC string OR an integer unix-epoch-seconds value -- a raw
  epoch int is cheaper for LavishScript to produce than a formatted
  string. Every other field may arrive as a string, coerced the same way
  `WandererApp.Scout.Ingest` coerces the sighting tables.

  A batch is processed row by row and reports per-row failures rather
  than rejecting the whole payload: one malformed line must not cost the
  rest of a tailed queue.
  """

  alias WandererApp.Api.ScoutSystemCoverage

  # Same upper bound as WandererApp.Scout.Ingest, for the same reason: a
  # bigger single POST is a bug or an abuse, not a batch to accept.
  @max_batch 1_000

  # Kept small on purpose: the response is a diagnostic for a bot author,
  # not a data channel.
  @max_reported_errors 20

  @kinds ~w(visit anoms sigs grid)

  @type result :: %{
          required(:received) => non_neg_integer(),
          required(:stored) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:errors) => [%{index: non_neg_integer(), error: String.t()}]
        }

  @doc """
  Ingests coverage rows. `map_id` is recorded as provenance (which map's
  API key authenticated the post); coverage itself is a fact about the
  system, never the map.
  """
  @spec ingest_coverage([map()], Ecto.UUID.t() | nil) :: {:ok, result()} | {:error, term()}
  def ingest_coverage(rows, _map_id) when is_list(rows) and length(rows) > @max_batch,
    do: {:error, {:batch_too_large, @max_batch}}

  def ingest_coverage(rows, map_id) when is_list(rows) do
    {stored, failed, errors} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({0, 0, []}, fn {row, index}, {stored, failed, errors} ->
        case store_row(row, map_id) do
          :ok ->
            {stored + 1, failed, errors}

          {:error, message} ->
            {stored, failed + 1, [%{index: index, error: message} | errors]}
        end
      end)

    {:ok,
     %{
       received: length(rows),
       stored: stored,
       failed: failed,
       errors: errors |> Enum.reverse() |> Enum.take(@max_reported_errors)
     }}
  end

  def ingest_coverage(_rows, _map_id), do: {:error, :rows_must_be_a_list}

  # ---------------------------------------------------------------------
  # Batch driver
  # ---------------------------------------------------------------------

  defp store_row(row, map_id) when is_map(row) do
    with {:ok, attrs} <- row_attrs(row, map_id) do
      write(attrs)
    end
  end

  defp store_row(_row, _map_id), do: {:error, "row must be an object"}

  defp row_attrs(row, map_id) do
    with {:ok, system_id} <- required_int(row, ["solar_system_id"]),
         {:ok, kind} <- required_kind(row),
         {:ok, observed_at} <- required_time(row, ["observed_at"]) do
      {:ok,
       %{
         solar_system_id: system_id,
         kind: kind,
         observed_at: observed_at,
         character_eve_id: string(row, ["character_eve_id"]),
         source: string(row, ["source"]),
         legs_scanned: int(row, ["legs_scanned"]),
         sig_count: int(row, ["sig_count"]),
         scanner_complete: bool(row, ["scanner_complete"]),
         map_id: map_id
       }}
    end
  end

  # Reads the current row for this identity and only upserts when the
  # incoming observation is strictly newer. See the module doc for why
  # this lives here (in Elixir) rather than as an Ash `upsert_condition`.
  defp write(%{solar_system_id: system_id, kind: kind, observed_at: observed_at} = attrs) do
    case ScoutSystemCoverage.by_system_and_kind(system_id, kind, authorize?: false) do
      {:ok, %{observed_at: stored_at}} ->
        if DateTime.compare(observed_at, stored_at) == :gt do
          do_upsert(attrs)
        else
          :ok
        end

      {:error, _not_found} ->
        do_upsert(attrs)
    end
  end

  defp do_upsert(attrs) do
    case ScoutSystemCoverage.upsert(attrs, authorize?: false) do
      {:ok, _record} -> :ok
      {:error, %Ash.Error.Invalid{} = error} -> {:error, Exception.message(error)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # ---------------------------------------------------------------------
  # Row -> attributes
  # ---------------------------------------------------------------------

  defp required_kind(row) do
    case string(row, ["kind"]) do
      nil ->
        {:error, "missing kind"}

      value ->
        normalized = String.downcase(value)

        if normalized in @kinds do
          {:ok, normalized}
        else
          {:error, "unknown kind #{inspect(value)}, expected one of #{Enum.join(@kinds, ", ")}"}
        end
    end
  end

  defp required_int(row, keys) do
    case int(row, keys) do
      nil -> {:error, "missing or unparseable #{hd(keys)}"}
      value -> {:ok, value}
    end
  end

  defp required_time(row, keys) do
    case time(row, keys) do
      nil -> {:error, "missing or unparseable #{hd(keys)}"}
      value -> {:ok, value}
    end
  end

  # ---------------------------------------------------------------------
  # Coercion. Optional values never fail a row; required ones do. Copied
  # from WandererApp.Scout.Ingest.
  # ---------------------------------------------------------------------

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

  # observed_at's two accepted shapes: ISO8601 UTC string, or an integer
  # (or numeric-string) unix-epoch-seconds value. See module doc.
  defp time(row, keys) do
    case fetch(row, keys) do
      nil -> nil
      %DateTime{} = value -> DateTime.truncate(value, :second)
      value when is_integer(value) -> epoch(value)
      value when is_binary(value) -> parse_time(String.trim(value))
      _ -> nil
    end
  end

  defp parse_time(value) do
    case Integer.parse(value) do
      {seconds, ""} -> epoch(seconds)
      _ -> iso8601(value)
    end
  end

  defp epoch(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, parsed} -> DateTime.truncate(parsed, :second)
      {:error, _reason} -> nil
    end
  end

  defp iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> DateTime.truncate(parsed, :second)
      {:error, _reason} -> nil
    end
  end
end
