defmodule WandererApp.ScoutSnapshotTest do
  @moduledoc """
  The structure presence feed end to end: a blob goes in, current state
  and the derived event log come out.

  `test/unit/scout/snapshot_test.exs` gates the pure `diff/2` and
  `normalize/1`. This file gates the part that writes: the presence
  LIFECYCLE, which is the whole reason the feed exists and the only place
  a bug deletes somebody's target list.

  The transitions that matter:

    * a structure appears, is confirmed, and its freshness moves without
      spamming the event log;
    * absence inside the proven sphere marks it `:missing`, and only a
      SECOND absence from a distinct visit promotes it to `:gone`;
    * an unanchoring hull whose timer has already run out needs only one;
    * any positive sighting resets the whole thing -- no state is
      terminal, so a false `:gone` self-heals;
    * nothing is ever deleted.

  See `docs/design/wanderer-scout-presence.md` section 5.
  """

  use WandererApp.DataCase, async: false

  require Ash.Query

  alias WandererApp.Api.{ScoutStructure, ScoutStructureEvent}
  alias WandererApp.Scout.Snapshot

  @jita 30_000_142
  @structure_id 1_046_123_456_789

  # 1 km off the observer, well inside every horizon below.
  defp structure_row(overrides \\ %{}) do
    Map.merge(
      %{
        "structure_id" => to_string(@structure_id),
        "type_name" => "Moonlight Mouse Hole",
        "group_name" => "Citadel",
        "owner_id" => "98123456",
        "status" => "NoFuel",
        "upkeep_state" => "2",
        "structure_state" => "110",
        "shield_pct" => "100",
        "armor_pct" => "100",
        "hull_pct" => "100",
        "pos_x" => "1000",
        "pos_y" => "0",
        "pos_z" => "0"
      },
      overrides
    )
  end

  defp blob(overrides \\ %{}) do
    Map.merge(
      %{
        "solar_system_id" => to_string(@jita),
        "observed_at" => to_string(DateTime.to_unix(DateTime.utc_now())),
        "source" => "eveknob/1.0",
        "observer_x" => "0",
        "observer_y" => "0",
        "observer_z" => "0",
        "horizon_m" => "500000",
        "structures" => [structure_row()],
        "steady_ids" => []
      },
      overrides
    )
  end

  defp minutes_ago(n), do: DateTime.utc_now() |> DateTime.add(-n, :minute) |> DateTime.to_unix()

  defp stored! do
    {:ok, row} = ScoutStructure.by_structure_id(@structure_id, authorize?: false)
    row
  end

  defp events do
    {:ok, rows} = ScoutStructureEvent.history(@structure_id, authorize?: false)
    Enum.map(rows, & &1.kind)
  end

  defp unanchoring(overrides \\ %{}) do
    [structure_row(Map.merge(%{"status" => "Unanchoring", "unanchoring" => "true"}, overrides))]
  end

  describe "a structure appearing and being confirmed" do
    test "the first blob creates current state and one appeared event" do
      assert {:ok, %{appeared: 1, changed: 0, missing: 0}} = Snapshot.ingest(nil, blob())

      row = stored!()
      assert row.presence == :seen
      assert row.status == "NoFuel"
      assert row.structure_name == "Moonlight Mouse Hole"
      assert row.pos_x == 1000.0
      assert events() == [:appeared]
    end

    test "re-reporting an unchanged structure moves its freshness and writes NO event" do
      assert {:ok, _} = Snapshot.ingest(nil, blob(%{"observed_at" => to_string(minutes_ago(30))}))
      first = stored!()

      assert {:ok, %{appeared: 0, changed: 0}} = Snapshot.ingest(nil, blob())

      assert DateTime.compare(stored!().last_confirmed_at, first.last_confirmed_at) == :gt
      assert events() == [:appeared]
    end

    test "a status move is one changed event carrying what moved" do
      assert {:ok, _} = Snapshot.ingest(nil, blob(%{"observed_at" => to_string(minutes_ago(30))}))

      assert {:ok, %{changed: 1}} =
               Snapshot.ingest(
                 nil,
                 blob(%{"structures" => [structure_row(%{"status" => "Abandoned"})]})
               )

      assert stored!().status == "Abandoned"

      assert [%{kind: :changed, status_before: "NoFuel", status_after: "Abandoned"} = event | _] =
               elem(ScoutStructureEvent.history(@structure_id, authorize?: false), 1)

      assert "status" in event.changed_fields
    end

    test "a steady id for a structure that was notable clears it off the boards" do
      assert {:ok, _} = Snapshot.ingest(nil, blob(%{"observed_at" => to_string(minutes_ago(30))}))

      assert {:ok, %{cleared: 1}} =
               Snapshot.ingest(
                 nil,
                 blob(%{"structures" => [], "steady_ids" => [to_string(@structure_id)]})
               )

      row = stored!()
      assert row.presence == :cleared
      # A steady id carries no state, so the last specific status stands.
      assert row.status == "NoFuel"
      assert :cleared in events()
    end
  end

  describe "absence" do
    setup do
      {:ok, _} = Snapshot.ingest(nil, blob(%{"observed_at" => to_string(minutes_ago(90))}))
      :ok
    end

    test "one absence inside the proven sphere is missing, not gone" do
      assert {:ok, %{missing: 1, gone: 0}} =
               Snapshot.ingest(
                 nil,
                 blob(%{
                   "observed_at" => to_string(minutes_ago(60)),
                   "structures" => [structure_row(%{"structure_id" => "999"})]
                 })
               )

      row = stored!()
      assert row.presence == :missing
      assert row.missing_count == 1
      assert row.missing_since
    end

    test "a second absence from a distinct visit promotes it to gone" do
      other = [structure_row(%{"structure_id" => "999"})]

      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{"observed_at" => to_string(minutes_ago(60)), "structures" => other})
        )

      assert {:ok, %{gone: 1}} =
               Snapshot.ingest(nil, blob(%{"structures" => other}))

      assert stored!().presence == :gone
      assert :gone in events()
    end

    test "two absences seconds apart are one observation and do not promote" do
      other = [structure_row(%{"structure_id" => "999"})]
      now = DateTime.to_unix(DateTime.utc_now())

      {:ok, _} =
        Snapshot.ingest(nil, blob(%{"observed_at" => to_string(now - 4), "structures" => other}))

      {:ok, result} =
        Snapshot.ingest(nil, blob(%{"observed_at" => to_string(now), "structures" => other}))

      assert result.gone == 0
      assert stored!().presence == :missing
    end

    test "a structure outside the proven sphere is never touched" do
      assert {:ok, %{missing: 0}} =
               Snapshot.ingest(
                 nil,
                 blob(%{
                   "horizon_m" => "100",
                   "structures" => [structure_row(%{"structure_id" => "999", "pos_x" => "50"})]
                 })
               )

      assert stored!().presence == :seen
    end

    test "an incomplete blob archives nothing" do
      assert {:ok, %{missing: 0}} =
               Snapshot.ingest(
                 nil,
                 blob(%{
                   "complete" => false,
                   "structures" => [structure_row(%{"structure_id" => "999"})]
                 })
               )

      assert stored!().presence == :seen
    end

    test "seeing it again resets the count -- gone is never terminal" do
      other = [structure_row(%{"structure_id" => "999"})]

      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{"observed_at" => to_string(minutes_ago(60)), "structures" => other})
        )

      {:ok, _} = Snapshot.ingest(nil, blob(%{"structures" => other}))
      assert stored!().presence == :gone

      {:ok, _} = Snapshot.ingest(nil, blob())

      row = stored!()
      assert row.presence == :seen
      assert row.missing_count == 0
      refute row.missing_since
    end

    test "the row is never deleted, whatever happens to it" do
      other = [structure_row(%{"structure_id" => "999"})]

      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{"observed_at" => to_string(minutes_ago(60)), "structures" => other})
        )

      {:ok, _} = Snapshot.ingest(nil, blob(%{"structures" => other}))

      assert {:ok, _row} = ScoutStructure.by_structure_id(@structure_id, authorize?: false)
    end
  end

  describe "an unanchoring hull whose timer has run out" do
    test "needs only one absence -- CCP's own timer is the second opinion" do
      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{
            "observed_at" => to_string(minutes_ago(60)),
            "structures" => [
              structure_row(%{
                "status" => "Unanchoring",
                "unanchoring" => "true",
                "timer_seconds" => "60"
              })
            ]
          })
        )

      assert {:ok, %{gone: 1}} =
               Snapshot.ingest(
                 nil,
                 blob(%{"structures" => [structure_row(%{"structure_id" => "999"})]})
               )

      assert stored!().presence == :gone
    end

    test "a timer still running does not shortcut the two-visit rule" do
      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{
            "observed_at" => to_string(minutes_ago(60)),
            "structures" => [
              structure_row(%{
                "status" => "Unanchoring",
                "unanchoring" => "true",
                "timer_seconds" => "86400"
              })
            ]
          })
        )

      assert {:ok, %{gone: 0, missing: 1}} =
               Snapshot.ingest(
                 nil,
                 blob(%{"structures" => [structure_row(%{"structure_id" => "999"})]})
               )

      assert stored!().presence == :missing
    end
  end

  describe "when a decommission started -- the Unanchoring board's only deadline" do
    test "the first sweep that sees it unanchoring is the anchor" do
      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{"observed_at" => to_string(minutes_ago(45)), "structures" => unanchoring()})
        )

      row = stored!()
      assert row.unanchoring_since
      assert_in_delta DateTime.diff(DateTime.utc_now(), row.unanchoring_since), 45 * 60, 60
    end

    test "a later sweep confirming the SAME run never pushes the anchor forward" do
      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{"observed_at" => to_string(minutes_ago(90)), "structures" => unanchoring()})
        )

      anchor = stored!().unanchoring_since

      # Same status, something else moved: the `changed` path.
      {:ok, %{changed: 1}} =
        Snapshot.ingest(nil, blob(%{"structures" => unanchoring(%{"shield_pct" => "40"})}))

      assert stored!().unanchoring_since == anchor

      # And the `unchanged` path.
      {:ok, _} =
        Snapshot.ingest(nil, blob(%{"structures" => unanchoring(%{"shield_pct" => "40"})}))

      assert stored!().unanchoring_since == anchor
    end

    test "leaving the family ENDS the run, and a restart anchors on the restart" do
      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{"observed_at" => to_string(minutes_ago(90)), "structures" => unanchoring()})
        )

      first = stored!().unanchoring_since

      # Somebody stopped it. The anchor stays (it dates the run on the
      # resolved board) and the ending is recorded; EVE restarts the
      # full 7 days, so a RESTART must re-anchor rather than reuse it.
      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{
            "observed_at" => to_string(minutes_ago(60)),
            "structures" => [structure_row(%{"status" => "FullPower", "upkeep_state" => "1"})]
          })
        )

      ended = stored!()
      assert ended.unanchor_outcome == :stopped
      assert ended.unanchor_ended_at
      # An ended run has no live deadline, whatever the anchor still says.
      assert WandererApp.Scout.Unanchor.predicted_max_at(ended) == nil

      {:ok, _} = Snapshot.ingest(nil, blob(%{"structures" => unanchoring()}))

      restarted = stored!()
      assert restarted.unanchoring_since
      assert DateTime.compare(restarted.unanchoring_since, first) == :gt
      refute restarted.unanchor_outcome
      refute restarted.unanchor_ended_at
    end

    test "a steady id ends the run: it is still there, and it is boring now" do
      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{"observed_at" => to_string(minutes_ago(90)), "structures" => unanchoring()})
        )

      {:ok, %{cleared: 1}} =
        Snapshot.ingest(
          nil,
          blob(%{"structures" => [], "steady_ids" => [to_string(@structure_id)]})
        )

      row = stored!()
      # `status` is untouched by a steady id -- which is exactly why the
      # ending has to be its own column.
      assert row.status == "Unanchoring"
      assert row.presence == :cleared
      assert row.unanchor_outcome == :stopped
    end

    test "an absence promoted to :gone ends the run as vanished, one miss does not" do
      {:ok, _} =
        Snapshot.ingest(
          nil,
          blob(%{"observed_at" => to_string(minutes_ago(120)), "structures" => unanchoring()})
        )

      {:ok, %{missing: 1, gone: 0}} =
        Snapshot.ingest(
          nil,
          blob(%{
            "observed_at" => to_string(minutes_ago(90)),
            "structures" => [structure_row(%{"structure_id" => "1000"})]
          })
        )

      refute stored!().unanchor_outcome

      {:ok, %{gone: 1}} =
        Snapshot.ingest(
          nil,
          blob(%{"structures" => [structure_row(%{"structure_id" => "1000"})]})
        )

      row = stored!()
      assert row.presence == :gone
      assert row.unanchor_outcome == :vanished
      assert row.unanchor_ended_at
    end
  end

  describe "refusals" do
    test "a blob that saw nothing at all is refused outright" do
      assert {:error, :no_observation} =
               Snapshot.ingest(nil, blob(%{"structures" => [], "steady_ids" => []}))
    end

    test "a replayed older blob never drags a row backwards" do
      {:ok, _} = Snapshot.ingest(nil, blob())
      fresh = stored!().last_confirmed_at

      {:ok, _} = Snapshot.ingest(nil, blob(%{"observed_at" => to_string(minutes_ago(600))}))

      assert stored!().last_confirmed_at == fresh
    end
  end
end
