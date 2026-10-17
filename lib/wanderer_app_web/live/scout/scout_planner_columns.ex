defmodule WandererAppWeb.ScoutPlannerColumns do
  @moduledoc """
  CHEWY PATCH (scout column sort/filter): the column specs for every
  table `ScoutPlannerLive` renders -- `WandererAppWeb.ScoutTable.col/3`
  built at RUNTIME (a closure cannot live in a module attribute), kept
  here rather than inline in the LiveView so the live module stays
  reads-and-events, same split `ScoutComponents` already draws between
  rendering and the socket.

  Column order MUST match each table's `<td>` list exactly -- see
  `scout_planner_live.html.heex`'s five `<.grid>`s -- and a `:value`
  function must read exactly what that row's cell shows, through the
  same public helper the cell calls, so "filter by what I can read"
  holds for every column, not just the obvious ones.
  """

  alias WandererAppWeb.ScoutComponents
  alias WandererAppWeb.ScoutTable

  @doc "Every table's column list, keyed by the `table` string `<.table_head>` takes."
  @spec all() :: %{String.t() => [ScoutTable.Col.t()]}
  def all do
    %{
      "rank" => rank_cols(),
      "sweep" => sweep_cols(),
      "heat" => heat_cols(),
      "targets" => targets_cols(),
      "targets_excluded" => targets_excluded_cols()
    }
  end

  # -------------------------------------------------------------------
  # Rank -- `Planner.rank_plan/1`'s stops (`Planner.stop/0`). `ctx` is
  # `%{now:, kind:}`: `kind` is the ladder entry `coverage_ladder/1`
  # bolds, so the Coverage column reads the SAME age it highlights.
  # -------------------------------------------------------------------

  defp rank_cols do
    [
      ScoutTable.col("system", "System", value: fn stop, _ctx -> stop.name end),
      ScoutTable.col("region", "Region", value: fn stop, _ctx -> stop.region_name end),
      # `stop_class/1`'s own rule: a w-space/Pochven class title OR a
      # k-space security status, never both -- `security/1` is the same
      # public formatter the cell calls.
      ScoutTable.col("class", "Class / Sec",
        value: fn stop, _ctx -> stop.class_title || ScoutComponents.security(stop.security) end
      ),
      ScoutTable.col("coverage", "Coverage",
        value: fn stop, ctx -> Map.get(stop.coverage, ctx.kind) end
      ),
      # `grid_verdict/1`'s `verdict_text/1` is private to `ScoutComponents`
      # -- this mirrors it over the same public fields rather than
      # reaching into a private function, since both read `spawns_found`
      # / `legs_scanned` / `legs_total` off the row either way.
      ScoutTable.col("verdict", "Verdict", value: fn stop, _ctx -> verdict_text(stop) end),
      ScoutTable.col("score", "Score", value: fn stop, _ctx -> stop.score end),
      # Four words (`unseen`/`stale`/`frontier`/`fresh`), so a dropdown.
      ScoutTable.col("reason", "Reason",
        select?: true,
        value: fn stop, _ctx -> stop.reason end
      ),
      ScoutTable.col("jumps", "Jumps",
        class: "text-right",
        value: fn stop, _ctx -> stop.jumps end
      ),
      ScoutTable.col("leg", "Leg", select?: true, value: fn stop, _ctx -> stop.leg end),
      # `terms_hint/1`'s own sentence, built from the same public
      # `score_fmt/1` it calls -- the breakdown is read-only, so the
      # rendered text and the filtered value must be identical.
      ScoutTable.col("why", "Why", value: fn stop, _ctx -> terms_text(stop.terms) end),
      # `stale_cell/1` -- a destructive action, not data.
      ScoutTable.col("actions", "", class: "w-24")
    ]
  end

  defp verdict_text(%{spawns_found: nil}), do: nil

  defp verdict_text(%{spawns_found: found}) when found > 0,
    do: "#{found} spawn#{if found == 1, do: "", else: "s"}"

  defp verdict_text(%{spawns_found: 0, legs_scanned: scanned, legs_total: total}) do
    if is_nil(total) or scanned == total, do: "clean", else: "partial (#{scanned || 0}/#{total})"
  end

  defp terms_text(terms) do
    "need #{ScoutComponents.score_fmt(terms.need)} · " <>
      "frontier #{ScoutComponents.score_fmt(terms.frontier)} · " <>
      "value #{ScoutComponents.score_fmt(terms.value)} · " <>
      "distance #{ScoutComponents.score_fmt(terms.distance)} · " <>
      "claimed #{ScoutComponents.score_fmt(terms.claimed)}"
  end

  # -------------------------------------------------------------------
  # Sweep -- `Sweep.sweep/1`'s stops (`Sweep.sweep_stop/0`). `ctx` is
  # `%{now:, kind:}`, same shape as rank's. The table carries its own
  # `#`: the stop's `order` field, fixed when the route was built, so a
  # sort here reorders what is SHOWN and never renumbers a stop.
  # -------------------------------------------------------------------

  defp sweep_cols do
    [
      ScoutTable.col("index", "#", class: "text-right", value: fn stop, _ctx -> stop.order end),
      ScoutTable.col("system", "System", value: fn stop, _ctx -> stop.name end),
      ScoutTable.col("region", "Region", value: fn stop, _ctx -> stop.region_name end),
      # `sweep_class_cell/1` has no class title to show, unlike rank's
      # stop -- `Sweep.sweep_stop` carries `security` alone.
      ScoutTable.col("class", "Class / Sec",
        value: fn stop, _ctx -> ScoutComponents.security(stop.security) end
      ),
      ScoutTable.col("coverage", "Coverage",
        value: fn stop, ctx -> Map.get(stop.coverage, ctx.kind) end
      ),
      ScoutTable.col("reason", "Reason",
        select?: true,
        value: fn stop, _ctx -> stop.reason end
      ),
      ScoutTable.col("jumps", "Jumps",
        class: "text-right",
        value: fn stop, _ctx -> stop.jumps_from_prev end
      ),
      ScoutTable.col("wp", "WP", select?: true, value: fn stop, _ctx -> waypoint_text(stop) end)
    ]
  end

  # -------------------------------------------------------------------
  # Region heat -- `Sweep.region_heat/2`'s rows (`Sweep.region_heat_row/0`).
  # `ctx` only needs `now:` -- median age has no backing timestamp (it is
  # a MEDIAN across many systems' own ages), so it is reconstructed as a
  # timestamp relative to `now` purely so the shared `<2h` / `>7d`
  # age-filter syntax applies to it, the same syntax every other age
  # column on this page already gets for free because its value IS a
  # `DateTime`. `age_fmt/1` still renders the pretty string in the cell.
  # -------------------------------------------------------------------

  defp heat_cols do
    [
      ScoutTable.col("region", "Region", value: fn row, _ctx -> row.region_name end),
      ScoutTable.col("systems", "Systems",
        class: "text-right",
        value: fn row, _ctx -> row.systems end
      ),
      # `heat_bar/1` prints `covered/systems`; `covered` is the number
      # that text names.
      ScoutTable.col("coverage", "Coverage", value: fn row, _ctx -> row.covered end),
      ScoutTable.col("stale", "Stale",
        class: "text-right",
        value: fn row, _ctx -> row.stale end
      ),
      ScoutTable.col("unseen", "Unseen",
        class: "text-right",
        value: fn row, _ctx -> row.unseen end
      ),
      ScoutTable.col("median_age", "Median age",
        class: "text-right",
        value: fn row, ctx -> synthetic_age_at(row.median_age_s, ctx.now) end
      )
    ]
  end

  defp synthetic_age_at(nil, _now), do: nil
  defp synthetic_age_at(seconds, now), do: DateTime.add(now, -seconds, :second)

  # -------------------------------------------------------------------
  # Targets -- `Targets.plan/1`'s route stops, the SAME `Sweep.sweep_stop`
  # shape sweep mode uses, routed over a finding set instead of a region.
  # `ctx` carries `targets:` (`result.targets`, keyed by system id) so
  # Findings/Out by/Last seen can read the finding the stop is ABOUT --
  # that data lives beside the stop, not on it.
  # -------------------------------------------------------------------

  defp targets_cols do
    [
      ScoutTable.col("index", "#", class: "text-right", value: fn stop, _ctx -> stop.order end),
      ScoutTable.col("system", "System", value: fn stop, _ctx -> stop.name end),
      ScoutTable.col("region", "Region", value: fn stop, _ctx -> stop.region_name end),
      # `target_findings/1` names the structure count; the status badges
      # beside it are a second column's worth of vocabulary, not this
      # one's single comparable.
      ScoutTable.col("findings", "Findings",
        value: fn stop, ctx -> target_field(ctx, stop.solar_system_id, :structures) end
      ),
      # `target_deadline/1` -- the soonest predicted decommission, an
      # upper bound, never a timer.
      ScoutTable.col("out_by", "Out by",
        value: fn stop, ctx -> target_field(ctx, stop.solar_system_id, :earliest_deadline) end
      ),
      ScoutTable.col("last_seen", "Last seen",
        value: fn stop, ctx -> target_field(ctx, stop.solar_system_id, :last_confirmed_at) end
      ),
      ScoutTable.col("jumps", "Jumps",
        class: "text-right",
        value: fn stop, _ctx -> stop.jumps_from_prev end
      ),
      ScoutTable.col("wp", "WP", select?: true, value: fn stop, _ctx -> waypoint_text(stop) end),
      # "Drop this system" -- an action, not data.
      ScoutTable.col("actions", "")
    ]
  end

  defp target_field(ctx, system_id, key) do
    case Map.get(ctx.targets, system_id) do
      nil -> nil
      target -> Map.get(target, key)
    end
  end

  defp waypoint_text(%{waypoint?: true}), do: "WP"
  defp waypoint_text(%{waypoint?: false}), do: "·"

  # -------------------------------------------------------------------
  # Targets, left out -- `{target, why}` pairs built where the rows are
  # produced (`ScoutPlannerLive.apply_targets/2`), not here: a column
  # reads a row, it does not know how the page assembled it.
  # -------------------------------------------------------------------

  defp targets_excluded_cols do
    [
      ScoutTable.col("system", "System", value: fn {target, _why}, _ctx -> target.name end),
      ScoutTable.col("region", "Region", value: fn {target, _why}, _ctx -> target.region_name end),
      ScoutTable.col("findings", "Findings",
        value: fn {target, _why}, _ctx -> target.structures end
      ),
      # Exactly two sentences, both written by `targets_excluded_rows/2`.
      ScoutTable.col("why", "Why", select?: true, value: fn {_target, why}, _ctx -> why end),
      ScoutTable.col("last_seen", "Last seen",
        value: fn {target, _why}, _ctx -> target.last_confirmed_at end
      )
    ]
  end
end
