defmodule WandererApp.ScoutAbsenceTest do
  @moduledoc """
  The second absence witness: a coverage row retiring a structure the
  presence feed cannot.

  The gap this closes, measured on live data 2026-10-08: the client only
  posts a structure blob when it has something to list, so once a system
  empties out nothing ever says so, and its last structure stays `:seen`
  on the Unanchoring board forever. The scout flew the route, saw
  nothing, and the page kept sending him back.

  What each case protects is the BIAS, not the mechanism: coverage is
  weaker evidence than a blob, so it may only retire a structure when
  the visit genuinely dwelled in the system, the structure was not
  confirmed by that same visit, and the client is demonstrably still
  reporting structures somewhere. Every case where the structure must
  stay `:seen` is a case where a bug would erase somebody's target list.

  See `WandererApp.Scout.Absence`.
  """

  use WandererApp.DataCase, async: false

  require Ash.Query

  alias WandererApp.Api.{ScoutStructure, ScoutStructureEvent}
  alias WandererApp.Scout.{Coverage, Snapshot}

  @system 30_000_142
  @other_system 30_000_144
  @structure_id 1_046_999_111_222
  @witness_id 1_046_999_111_333

  setup do
    Application.put_env(:wanderer_app, :scout_coverage_enabled, true)
    Application.put_env(:wanderer_app, :scout_presence_enabled, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :scout_coverage_enabled)
      Application.delete_env(:wanderer_app, :scout_presence_enabled)
    end)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %{now: now, stale_at: DateTime.add(now, -3 * 24 * 60 * 60, :second)}
  end

  defp seed(structure_id, system, observed_at, overrides \\ %{}) do
    structure =
      Map.merge(
        %{
          "structure_id" => to_string(structure_id),
          "type_name" => "Dusty Astrahus",
          "group_name" => "Citadel",
          "status" => "Unanchoring",
          "pos_x" => "1000",
          "pos_y" => "0",
          "pos_z" => "0"
        },
        overrides
      )

    blob = %{
      "solar_system_id" => to_string(system),
      "observed_at" => to_string(DateTime.to_unix(observed_at)),
      "observer_x" => "0",
      "observer_y" => "0",
      "observer_z" => "0",
      "horizon_m" => "500000",
      "structures" => [structure],
      "steady_ids" => []
    }

    assert {:ok, _result} = Snapshot.ingest(nil, blob)
  end

  defp cover(kind, observed_at, system \\ @system) do
    assert {:ok, %{stored: 1, failed: 0}} =
             Coverage.ingest_coverage(
               [
                 %{
                   "solar_system_id" => to_string(system),
                   "kind" => kind,
                   "observed_at" => to_string(DateTime.to_unix(observed_at))
                 }
               ],
               nil
             )
  end

  defp presence(structure_id) do
    assert {:ok, row} = ScoutStructure.by_structure_id(structure_id, authorize?: false)
    row
  end

  describe "a dwell retires what it did not see" do
    test "an anoms pass marks a days-old structure missing", %{now: now, stale_at: stale_at} do
      seed(@structure_id, @system, stale_at)
      seed(@witness_id, @other_system, now)

      cover("anoms", now)

      row = presence(@structure_id)
      assert row.presence == :missing
      assert row.missing_count == 1
      assert row.status == "Unanchoring"
    end

    test "the event log says which witness retired it", %{now: now, stale_at: stale_at} do
      seed(@structure_id, @system, stale_at)
      seed(@witness_id, @other_system, now)

      cover("grid", now)

      assert {:ok, events} = ScoutStructureEvent.history(@structure_id, authorize?: false)
      assert %{kind: :missing, changed_fields: ["coverage:grid"]} = hd(events)
    end

    test "a second dwell half an hour later promotes it to gone", %{
      now: now,
      stale_at: stale_at
    } do
      seed(@structure_id, @system, stale_at)
      seed(@witness_id, @other_system, now)

      cover("anoms", now)
      cover("anoms", DateTime.add(now, 31 * 60, :second))

      assert presence(@structure_id).presence == :gone
    end

    test "a later sighting brings it straight back", %{now: now, stale_at: stale_at} do
      seed(@structure_id, @system, stale_at)
      seed(@witness_id, @other_system, now)
      cover("anoms", now)

      seed(@structure_id, @system, DateTime.add(now, 60, :second))

      row = presence(@structure_id)
      assert row.presence == :seen
      assert row.missing_count == 0
    end
  end

  describe "coverage that proves nothing retires nothing" do
    test "a gate-to-gate visit is not a dwell", %{now: now, stale_at: stale_at} do
      seed(@structure_id, @system, stale_at)
      seed(@witness_id, @other_system, now)

      cover("visit", now)

      assert presence(@structure_id).presence == :seen
    end

    # The blob lands on arrival and the coverage row when the work is
    # done; measured dwells run to 16 minutes, so anything inside the
    # grace window must be read as confirmed BY this visit.
    test "a structure confirmed 90 minutes before the coverage row survives it", %{now: now} do
      seed(@structure_id, @system, DateTime.add(now, -90 * 60, :second))
      seed(@witness_id, @other_system, now)

      cover("grid", now)

      assert presence(@structure_id).presence == :seen
    end

    test "three hours is a separate visit and does retire it", %{now: now} do
      seed(@structure_id, @system, DateTime.add(now, -3 * 60 * 60, :second))
      seed(@witness_id, @other_system, now)

      cover("grid", now)

      assert presence(@structure_id).presence == :missing
    end

    test "a client whose structure feed is silent retires nothing", %{
      now: now,
      stale_at: stale_at
    } do
      # No witness: nothing anywhere has been confirmed within the
      # feed window, so this coverage row is from a client that is not
      # reporting structures at all.
      seed(@structure_id, @system, stale_at)

      cover("anoms", now)

      assert presence(@structure_id).presence == :seen
    end

    test "coverage for another system never touches this one", %{now: now, stale_at: stale_at} do
      seed(@structure_id, @system, stale_at)
      seed(@witness_id, @other_system, now)

      cover("anoms", now, 30_000_999)

      assert presence(@structure_id).presence == :seen
    end

    test "a replayed coverage row does not tick twice", %{now: now, stale_at: stale_at} do
      seed(@structure_id, @system, stale_at)
      seed(@witness_id, @other_system, now)

      cover("anoms", now)
      cover("anoms", now)

      row = presence(@structure_id)
      assert row.presence == :missing
      assert row.missing_count == 1
    end

    test "with the presence flag off coverage stays a pure ledger", %{
      now: now,
      stale_at: stale_at
    } do
      seed(@structure_id, @system, stale_at)
      seed(@witness_id, @other_system, now)

      Application.put_env(:wanderer_app, :scout_presence_enabled, false)

      cover("anoms", now)

      assert presence(@structure_id).presence == :seen
    end
  end
end
