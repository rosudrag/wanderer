defmodule WandererApp.Scout.Absence do
  @moduledoc """
  CHEWY PATCH: turns a coverage row ("I looked at system S at T") into
  the absence the presence feed cannot report.

  `WandererApp.Scout.Snapshot` retires a structure when a COMPLETE blob
  for its system does not list it. That only ever works while the system
  still holds something else worth listing: the client posts a blob when
  it has structures to report, so an emptied system produces no blob at
  all, and the last structure in it stays `:seen` forever -- on the
  Unanchoring board, in the red banner, in the sidebar count.

  Measured on live data 2026-10-08, that is not hypothetical: five of
  the seven stale `Unanchoring` rows sat in systems whose newest
  coverage row was DAYS newer than any structure confirmation there
  (30004741 toured 12:36 today, its hull last confirmed 2026-10-03;
  30002791 scanned 10-06, hull from 10-01). The bot flew the route, saw
  nothing, and had no way to say so.

  So the coverage ledger is the second absence witness:

    * **Only dwell kinds.** `anoms | sigs | grid` mean the character sat
      in the system and worked it. `visit` is a gate-to-gate pass and
      proves nothing about what is on d-scan, so it never retires
      anything.

    * **Only rows older than the grace window.** Within one visit the
      bot posts its blob and its coverage seconds apart, in either
      order; a structure confirmed inside `grace_seconds/0` of the
      coverage row is treated as confirmed BY that visit.

    * **Only while the structure feed is demonstrably alive**
      (`feed_live?/1`): some structure, anywhere, confirmed within
      `feed_window_seconds/0` of this observation. A client whose
      structure watch is broken or simply older than the feature keeps
      posting coverage, and reading that as "nothing is out there any
      more" would wipe the watchlist. Coverage alone is not evidence;
      coverage from a client that is reporting structures elsewhere is.

  The tick itself is `Snapshot.absent/4` -- one definition of what an
  absence does, shared with the blob path, including the
  two-absences-30-minutes-apart promotion to `:gone` and the
  `:missing`/`:gone` event row. `changed_fields` carries
  `"coverage:<kind>"` so the drill-down says which witness retired it.

  Nothing is deleted: `:missing` takes the row off every opportunity
  board (they all filter `presence == :seen`) while the flat log, the
  event history and the CSV export keep it, and any later sighting
  resets it to `:seen`.
  """

  require Ash.Query
  require Logger

  alias WandererApp.Api.ScoutStructure
  alias WandererApp.Scout.Snapshot

  # A coverage row only proves a dwell for these. See moduledoc.
  @dwell_kinds ~w(anoms sigs grid)

  # One visit's structure blob lands when the character ARRIVES and its
  # coverage row when the work finishes, so the grace window has to
  # exceed a whole dwell or a structure gets retired by the same visit
  # that just confirmed it. Measured on the live ledger 2026-10-08
  # (147 visit->grid pairs): mean 5 min, p95 11 min, max 16.3 min. Two
  # hours is far above that and still two orders of magnitude below the
  # days-old staleness this feature exists to clear, so the only thing
  # it costs is that a system re-scouted within two hours retires its
  # stale rows on the following pass instead.
  @grace_seconds 2 * 60 * 60

  # "Is the structure feed alive around this observation?" Wide enough
  # to span a bot restart, narrow enough that a client which stopped
  # reporting structures yesterday cannot retire anything today.
  @feed_window_seconds 6 * 60 * 60

  @type result :: %{retired: non_neg_integer(), gone: non_neg_integer()}

  @doc "Kinds of coverage that count as having looked at the system."
  @spec dwell_kinds() :: [String.t()]
  def dwell_kinds, do: @dwell_kinds

  @doc "Seconds of slack between a confirmation and a coverage row of the same visit."
  @spec grace_seconds() :: pos_integer()
  def grace_seconds, do: @grace_seconds

  @doc "Width (each side) of the window `feed_live?/1` looks in."
  @spec feed_window_seconds() :: pos_integer()
  def feed_window_seconds, do: @feed_window_seconds

  @doc """
  Applies coverage-derived absence for one stored coverage row.

  Returns `{:ok, %{retired: n, gone: n}}` when it ran, or `:ignored`
  when this row is not a witness (non-dwell kind, feature off, nothing
  stale in the system, or a structure feed that is not currently
  reporting).

  Never raises and never fails the ingest it hangs off -- a coverage row
  is stored whatever this concludes.
  """
  @spec from_coverage(integer(), String.t(), DateTime.t(), Ecto.UUID.t() | nil) ::
          {:ok, result()} | :ignored
  def from_coverage(solar_system_id, kind, observed_at, map_id) do
    if enabled?() and kind in @dwell_kinds do
      case candidates(solar_system_id, observed_at) do
        [] -> :ignored
        rows -> maybe_retire(rows, kind, observed_at, map_id)
      end
    else
      :ignored
    end
  rescue
    error ->
      Logger.warning("[Scout.Absence] skipped: #{inspect(error)}")
      :ignored
  end

  @doc """
  Whether the structure feed was reporting around `observed_at` -- the
  guard that keeps a client with no structure watch from retiring
  everything it drives past. See moduledoc.
  """
  @spec feed_live?(DateTime.t()) :: boolean()
  def feed_live?(observed_at) do
    from = DateTime.add(observed_at, -@feed_window_seconds, :second)
    to = DateTime.add(observed_at, @feed_window_seconds, :second)

    ScoutStructure
    |> Ash.Query.filter(last_confirmed_at >= ^from and last_confirmed_at <= ^to)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [_row | _]} -> true
      _ -> false
    end
  end

  # Both our own flags: the ledger half (this runs inside the coverage
  # ingest) and the presence half (this writes presence and its event
  # log). Either off and coverage stays a pure ledger, which is the
  # pre-patch behaviour.
  defp enabled?,
    do: WandererApp.Env.scout_coverage_enabled?() and WandererApp.Env.scout_presence_enabled?()

  # `presence != :gone`, NOT `in [:seen, :cleared]`: a row that already
  # missed once has to stay eligible or `missing_count` never reaches
  # the 2 that promotes it to `:gone`, which is exactly the trap
  # `Snapshot`'s own `in_scope?/2` documents.
  defp candidates(solar_system_id, observed_at) do
    cutoff = DateTime.add(observed_at, -@grace_seconds, :second)

    ScoutStructure
    |> Ash.Query.filter(
      solar_system_id == ^solar_system_id and presence != :gone and
        last_confirmed_at < ^cutoff
    )
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  defp maybe_retire(rows, kind, observed_at, map_id) do
    if feed_live?(observed_at) do
      {retired, gone} =
        Enum.reduce(rows, {0, 0}, fn row, {retired, gone} ->
          case Snapshot.absent(row, observed_at, map_id, ["coverage:" <> kind]) do
            {:ok, :missing} ->
              {retired + 1, gone}

            {:ok, :gone} ->
              {retired + 1, gone + 1}

            :stale ->
              {retired, gone}

            {:error, reason} ->
              Logger.warning("[Scout.Absence] absence tick failed: #{inspect(reason)}")
              {retired, gone}
          end
        end)

      if retired > 0 do
        Logger.info(
          "[Scout.Absence] #{retired} structure(s) absent on #{kind} coverage of " <>
            "#{hd(rows).solar_system_id} (#{gone} gone)"
        )

        Snapshot.announce()
      end

      {:ok, %{retired: retired, gone: gone}}
    else
      :ignored
    end
  end
end
