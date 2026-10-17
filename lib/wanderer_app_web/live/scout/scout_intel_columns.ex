defmodule WandererAppWeb.ScoutIntelColumns do
  @moduledoc """
  CHEWY PATCH: the column specs for every table on `/scout` (both the
  structures and the spawns categories), built for
  `WandererAppWeb.ScoutTable` / `WandererAppWeb.ScoutComponents.table_head/1`.

  One function, built at RUNTIME rather than a module attribute: a
  column's `:value` is a closure, and a closure cannot live in a
  compiled constant. `all/0` is called once per mount
  (`WandererAppWeb.ScoutIntelLive.mount/3`) and the result sits on the
  socket as `@table_cols` — the read runs once, not once per render.

  Every `:value` reads the SAME thing the `<td>` it describes renders,
  through the SAME public helper (`WandererAppWeb.ScoutComponents`,
  `WandererApp.Scout.Unanchor`, or `WandererAppWeb.ScoutIntelLive`'s own
  `now_kind_label/1`) — "filter by what I can read" only holds if the
  two can never drift apart. Keys are short strings matching the board
  keys this page already uses (`@boards` in `ScoutIntelLive`); the two
  drill-down tables (`structure_history`, `spawn_history`) have no board
  of their own and are named for the modal they live in.
  """

  alias WandererApp.Scout.Unanchor
  alias WandererAppWeb.ScoutComponents
  alias WandererAppWeb.ScoutIntelLive
  alias WandererAppWeb.ScoutTable

  @spec all() :: %{String.t() => [ScoutTable.Col.t()]}
  def all do
    %{
      "asset_safety" => asset_safety_cols(),
      "asset_safety_dismissed" => asset_safety_dismissed_cols(),
      "now" => now_cols(),
      "unanchored" => unanchored_cols(),
      "timers" => timers_cols(),
      "anchoring" => anchoring_cols(),
      "unarmed" => unarmed_cols(),
      "unanchoring" => unanchoring_cols(),
      "sorted" => sorted_cols(),
      "abandoned" => abandoned_cols(),
      "no_fuel" => no_fuel_cols(),
      "archived" => archived_cols(),
      "structures" => structures_cols(),
      "fresh_spawns" => fresh_spawns_cols(),
      "spawns" => spawns_cols(),
      "structure_history" => structure_history_cols(),
      "spawn_history" => spawn_history_cols()
    }
  end

  # -------------------------------------------------------------------
  # Shared accessors — one closure per cell shape, reused across every
  # board that renders that shape, so the value and the markup can never
  # answer two different questions.
  # -------------------------------------------------------------------

  defp structure_name(row), do: row.structure_name || to_string(row.structure_id)
  defp owner(row), do: row.owner_name || "—"
  defp reported_by(row), do: row.character_name || "—"

  defp system_col, do: fn row, ctx -> ScoutComponents.system(row, ctx.systems) end
  defp status_col, do: fn row, _ctx -> row.status || "—" end
  defp where_col, do: fn row, _ctx -> ScoutComponents.where(row) end
  defp seen_col, do: fn row, _ctx -> row.last_confirmed_at end

  defp actions_col, do: ScoutTable.col("actions", "", class: "w-10")

  # EVE's own status words are a fixed vocabulary, so this one column is
  # a dropdown rather than a box -- the only kind of column that earns
  # one. A structure NAME stays free text even on a board of three rows:
  # a control that changes shape with the row count is a control a
  # reader cannot learn.
  defp status_column, do: ScoutTable.col("status", "Status", select?: true, value: status_col())

  # -------------------------------------------------------------------
  # Asset safety — `scout-asset-safety-table`
  # -------------------------------------------------------------------

  defp asset_safety_cols do
    [
      ScoutTable.col("fired", "Fired", class: "w-32", value: fn row, _ctx -> row.notified_at end),
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      ScoutTable.col("where", "Where", value: where_col()),
      ScoutTable.col("reported_by", "Reported by",
        class: "w-40",
        value: fn row, _ctx -> reported_by(row) end
      ),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Asset safety, dismissed — `scout-asset-safety-dismissed-table`
  # -------------------------------------------------------------------

  defp asset_safety_dismissed_cols do
    [
      ScoutTable.col("fired", "Fired", class: "w-32", value: fn row, _ctx -> row.notified_at end),
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      ScoutTable.col("reported_by", "Reported by",
        class: "w-40",
        value: fn row, _ctx -> reported_by(row) end
      ),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Now — `scout-now-table`
  #
  # Rows here are `%{kind:, row:, at:}` entries folded by
  # `ScoutIntelLive.now_rows/1`, not boards' own structs — `entry.at` is
  # already the one deadline the "When" cell renders (nil for a
  # structure sitting unanchored, which is the lead with no clock of its
  # own).
  # -------------------------------------------------------------------

  defp now_cols do
    [
      ScoutTable.col("when", "When", class: "w-28", value: fn entry, _ctx -> entry.at end),
      ScoutTable.col("what", "What",
        class: "w-28",
        select?: true,
        value: fn entry, _ctx -> ScoutIntelLive.now_kind_label(entry.kind) end
      ),
      ScoutTable.col("structure", "Structure",
        value: fn entry, _ctx -> structure_name(entry.row) end
      ),
      ScoutTable.col("system", "System",
        value: fn entry, ctx -> ScoutComponents.system(entry.row, ctx.systems) end
      ),
      ScoutTable.col("owner", "Owner", value: fn entry, _ctx -> owner(entry.row) end),
      ScoutTable.col("status", "Status",
        select?: true,
        value: fn entry, _ctx -> entry.row.status || "—" end
      ),
      ScoutTable.col("seen", "Seen",
        class: "w-32",
        value: fn entry, _ctx -> entry.row.last_confirmed_at end
      )
    ]
  end

  # -------------------------------------------------------------------
  # Unanchored — `scout-unanchored`
  # -------------------------------------------------------------------

  defp unanchored_cols do
    [
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      status_column(),
      ScoutTable.col("where", "Where", value: where_col()),
      ScoutTable.col("seen", "Seen", class: "w-32", value: seen_col()),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Live timers — `scout-active-timers`
  # -------------------------------------------------------------------

  defp timers_cols do
    [
      ScoutTable.col("comes_out", "Comes out",
        class: "w-28",
        value: fn row, _ctx -> row.timer_expires_at end
      ),
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      status_column(),
      ScoutTable.col("seen", "Seen", class: "w-32", value: seen_col()),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Anchoring — `scout-anchoring`
  # -------------------------------------------------------------------

  defp anchoring_cols do
    [
      ScoutTable.col("anchors_in", "Anchors in",
        class: "w-28",
        value: fn row, _ctx -> row.timer_expires_at end
      ),
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      status_column(),
      ScoutTable.col("where", "Where", value: where_col()),
      ScoutTable.col("seen", "Seen", class: "w-32", value: seen_col()),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Needs seeding — `scout-unarmed-table`
  # -------------------------------------------------------------------

  defp unarmed_cols do
    [
      ScoutTable.col("predicted_max_out", "Predicted max out",
        class: "w-36",
        value: fn row, _ctx -> Unanchor.predicted_max_at(row) end
      ),
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      ScoutTable.col("where", "Where", value: where_col()),
      ScoutTable.col("seen", "Seen", class: "w-32", value: seen_col())
    ]
  end

  # -------------------------------------------------------------------
  # Unanchoring — `scout-unanchoring`
  #
  # The Trigger column exists only while asset safety is on — same
  # guard the `<th :if={asset_safety_enabled?()}>` in the template uses,
  # so the spec list and the `<td>` list can never drift to different
  # lengths.
  # -------------------------------------------------------------------

  defp unanchoring_cols do
    [
      ScoutTable.col("predicted_max_out", "Predicted max out",
        class: "w-36",
        value: fn row, _ctx -> Unanchor.predicted_max_at(row) end
      ),
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      status_column()
    ] ++
      trigger_col() ++
      [
        ScoutTable.col("where", "Where", value: where_col()),
        ScoutTable.col("seen", "Seen", class: "w-32", value: seen_col()),
        actions_col()
      ]
  end

  defp trigger_col do
    if WandererApp.Env.scout_asset_safety_enabled?() do
      # Mirrors `ScoutComponents.armed_cell/1` exactly: the badge reads
      # "armed" or "seed it", so the filter and the `<select>` options
      # read the reader's own words back, not a boolean.
      [
        ScoutTable.col("trigger", "Trigger",
          class: "w-24",
          select?: true,
          value: fn row, ctx ->
            if Map.has_key?(ctx.armed_by, row.structure_id), do: "armed", else: "seed it"
          end
        )
      ]
    else
      []
    end
  end

  # -------------------------------------------------------------------
  # Someone else sorted it — `scout-sorted-table`
  # -------------------------------------------------------------------

  defp sorted_cols do
    [
      ScoutTable.col("ended", "Ended",
        class: "w-36",
        value: fn row, _ctx -> row.unanchor_ended_at || Unanchor.predicted_max_at(row) end
      ),
      ScoutTable.col("how", "How",
        class: "w-44",
        select?: true,
        value: fn row, ctx -> Unanchor.outcome_label(Unanchor.outcome(row, ctx.now)) end
      ),
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      ScoutTable.col("where", "Where", value: where_col()),
      ScoutTable.col("last_seen", "Last seen", class: "w-32", value: seen_col()),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Abandoned — `scout-abandoned`, No fuel — `scout-no-fuel`
  #
  # Identical shape: `<td>` list is the same five columns plus the
  # archive cell on both boards.
  # -------------------------------------------------------------------

  defp abandoned_cols, do: dead_family_cols()
  defp no_fuel_cols, do: dead_family_cols()

  defp dead_family_cols do
    [
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      status_column(),
      ScoutTable.col("where", "Where", value: where_col()),
      ScoutTable.col("seen", "Seen", class: "w-32", value: seen_col()),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Archived — `scout-archived`
  # -------------------------------------------------------------------

  defp archived_cols do
    [
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      status_column(),
      ScoutTable.col("archived", "Archived",
        class: "w-32",
        value: fn row, _ctx -> row.archived_at end
      ),
      ScoutTable.col("seen", "Seen", class: "w-32", value: seen_col()),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Structures ingest log — `scout-structures`
  # -------------------------------------------------------------------

  defp structures_cols do
    [
      ScoutTable.col("structure", "Structure", value: fn row, _ctx -> structure_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("owner", "Owner", value: fn row, _ctx -> owner(row) end),
      status_column(),
      ScoutTable.col("comes_out", "Comes out",
        class: "w-28",
        value: fn row, _ctx -> row.timer_expires_at end
      ),
      ScoutTable.col("seen", "Seen", class: "w-32", value: seen_col()),
      actions_col()
    ]
  end

  # -------------------------------------------------------------------
  # Fresh spawns — `scout-fresh-spawns`, spawns ingest log —
  # `scout-spawns`
  # -------------------------------------------------------------------

  defp spawn_name(row), do: row.spawn_name
  defp spawn_location(row), do: row.location_name
  defp spawn_local(row), do: row.players_in_local
  defp spawn_outcome(row), do: row.outcome || row.action_taken || "—"

  # ISK is stored as a `Decimal`; a FLOAT is what sorts and compares
  # numerically, never the `isk/1`-formatted string.
  defp spawn_value(row), do: row.isk_value && Decimal.to_float(row.isk_value)

  defp fresh_spawns_cols do
    [
      ScoutTable.col("seen", "Seen", class: "w-32", value: fn row, _ctx -> row.observed_at end),
      ScoutTable.col("spawn", "Spawn", value: fn row, _ctx -> spawn_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("location", "Location", value: fn row, _ctx -> spawn_location(row) end),
      ScoutTable.col("local", "Local",
        class: "w-16 text-right",
        value: fn row, _ctx -> spawn_local(row) end
      ),
      ScoutTable.col("value", "Value",
        class: "w-24 text-right",
        value: fn row, _ctx -> spawn_value(row) end
      )
    ]
  end

  defp spawns_cols do
    [
      ScoutTable.col("seen", "Seen", class: "w-32", value: fn row, _ctx -> row.observed_at end),
      ScoutTable.col("spawn", "Spawn", value: fn row, _ctx -> spawn_name(row) end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("location", "Location", value: fn row, _ctx -> spawn_location(row) end),
      ScoutTable.col("local", "Local",
        class: "w-16 text-right",
        value: fn row, _ctx -> spawn_local(row) end
      ),
      ScoutTable.col("dt_plus", "DT+",
        class: "w-16 text-right",
        title: "Minutes since downtime",
        value: fn row, _ctx -> row.minutes_since_downtime end
      ),
      ScoutTable.col("outcome", "Outcome",
        select?: true,
        value: fn row, _ctx -> spawn_outcome(row) end
      ),
      ScoutTable.col("value", "Value",
        class: "w-24 text-right",
        value: fn row, _ctx -> spawn_value(row) end
      )
    ]
  end

  # -------------------------------------------------------------------
  # Structure drill-down — `scout-structure-history` (inside `@detail`)
  # -------------------------------------------------------------------

  defp structure_history_cols do
    [
      ScoutTable.col("when", "When", class: "w-32", value: fn row, _ctx -> row.observed_at end),
      ScoutTable.col("event", "Event",
        class: "w-24",
        select?: true,
        value: fn row, _ctx -> row.kind end
      ),
      ScoutTable.col("system", "System", value: system_col()),
      # Mirrors the cell's own text exactly: "before → after", or just
      # "after" (defaulting to "—") the first time a structure is seen.
      ScoutTable.col("status", "Status",
        value: fn row, _ctx ->
          case row.status_before do
            nil -> row.status_after || "—"
            before -> "#{before} → #{row.status_after || "—"}"
          end
        end
      ),
      ScoutTable.col("what_moved", "What moved",
        value: fn row, _ctx -> Enum.join(row.changed_fields || [], ", ") end
      )
    ]
  end

  # -------------------------------------------------------------------
  # Spawn drill-down — `scout-spawn-history` (inside `@spawn_detail`)
  # -------------------------------------------------------------------

  defp spawn_history_cols do
    [
      ScoutTable.col("seen", "Seen", class: "w-32", value: fn row, _ctx -> row.observed_at end),
      ScoutTable.col("system", "System", value: system_col()),
      ScoutTable.col("location", "Location", value: fn row, _ctx -> spawn_location(row) end),
      ScoutTable.col("local", "Local",
        class: "w-16 text-right",
        value: fn row, _ctx -> spawn_local(row) end
      ),
      ScoutTable.col("dt_plus", "DT+",
        class: "w-16 text-right",
        title: "Minutes since downtime",
        value: fn row, _ctx -> row.minutes_since_downtime end
      ),
      ScoutTable.col("outcome", "Outcome",
        select?: true,
        value: fn row, _ctx -> spawn_outcome(row) end
      ),
      ScoutTable.col("value", "Value",
        class: "w-24 text-right",
        value: fn row, _ctx -> spawn_value(row) end
      )
    ]
  end
end
