defmodule WandererApp.ScoutTargetsTest do
  @moduledoc """
  Proves `WandererApp.Scout.Targets` BEHAVIOUR -- `AGENTS.md`'s
  documented trap is that an Ash pipeline compiles clean and raises on
  first execution, and every filter here is one.

  What is pinned is the membership contract, not the route: the tour
  itself is `WandererApp.Scout.Sweep`'s and has its own tests. Fixture
  ids are in the 991_610_xxx range, outside any real EVE static data.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapSolarSystem, MapSolarSystemJumps, ScoutStructure}
  alias WandererApp.Scout.Targets

  @adjacency_cache_key "scout:planner:adjacency"

  setup do
    # Process-global, outside the Ecto sandbox -- without this the graph
    # a previous test built is the graph these routes walk.
    WandererApp.Cache.delete(@adjacency_cache_key)
    :ok
  end

  describe "the decommission window" do
    test "drops an unanchoring hull whose predicted maximum has passed, and only one that carries a prediction" do
      [expired, live, no_anchor] = chain(3, 991_610_100, "Region Window")
      now = DateTime.utc_now()

      # First seen 9 days ago: 7-day decommission cannot still be
      # running, so the trip is wasted.
      put_structure(991_610_191, expired, "Unanchoring", DateTime.add(now, -9, :day))
      put_structure(991_610_192, live, "Unanchoring", DateTime.add(now, -2, :day))
      # No `unanchoring_since` -- nothing honest to predict, so the
      # filter must never remove it.
      put_structure(991_610_193, no_anchor, "Unanchoring", nil)

      assert {:ok, hidden} = Targets.plan(radius: 0)

      refute expired in stop_ids(hidden)
      assert live in stop_ids(hidden)
      assert no_anchor in stop_ids(hidden)
      assert hidden.excluded.past_window == 1

      assert {:ok, shown} = Targets.plan(radius: 0, hide_past_window: false)

      assert expired in stop_ids(shown)
      assert shown.excluded.past_window == 0
    end

    test "a system's deadline is the EARLIEST of its hulls, and its last seen the newest" do
      [system, _neighbour] = chain(2, 991_610_200, "Region Earliest")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      put_structure(991_610_291, system, "Unanchoring", DateTime.add(now, -5, :day),
        last_confirmed_at: DateTime.add(now, -6, :hour)
      )

      put_structure(991_610_292, system, "Unanchoring", DateTime.add(now, -1, :day),
        last_confirmed_at: DateTime.add(now, -1, :hour)
      )

      assert {:ok, result} = Targets.plan(radius: 0)
      target = result.targets[system]

      assert target.structures == 2
      # 5 days in beats 1 day in: the tighter upper bound is the one a
      # fleet has to beat.
      assert DateTime.diff(target.earliest_deadline, DateTime.add(now, 2, :day), :second) |> abs() <
               120

      assert DateTime.diff(target.last_confirmed_at, DateTime.add(now, -1, :hour), :second)
             |> abs() < 120
    end
  end

  describe "the strike-off list" do
    test "an ignored system leaves the route and is counted, and the rest still route" do
      [a, b, c] = chain(3, 991_610_300, "Region Ignore")
      since = DateTime.add(DateTime.utc_now(), -1, :day)

      put_structure(991_610_391, a, "Unanchoring", since)
      put_structure(991_610_392, b, "Unanchoring", since)
      put_structure(991_610_393, c, "Unanchoring", since)

      assert {:ok, all} = Targets.plan(radius: 0)
      assert Enum.sort(stop_ids(all)) == Enum.sort([a, b, c])

      assert {:ok, without} = Targets.plan(radius: 0, ignore: [b])

      refute b in stop_ids(without)
      assert Enum.sort(stop_ids(without)) == Enum.sort([a, c])
      assert without.excluded.ignored == 1
    end
  end

  describe "the radius" do
    test "is measured from a start that is not itself a target, and anything beyond it is reported, not dropped silently" do
      # start - a - b - c, plus an island nothing can gate to.
      [start, a, b, c] = chain(4, 991_610_400, "Region Radius")
      island = 991_610_409
      put_system(island, "ISLAND", "Region Radius", 7, "0.5")

      since = DateTime.add(DateTime.utc_now(), -1, :day)
      put_structure(991_610_491, a, "Unanchoring", since)
      put_structure(991_610_492, b, "Unanchoring", since)
      put_structure(991_610_493, c, "Unanchoring", since)
      put_structure(991_610_494, island, "Unanchoring", since)

      assert {:ok, result} = Targets.plan(start: start, radius: 2)

      # a is 1 jump out, b is 2, c is 3.
      assert Enum.sort(stop_ids(result)) == Enum.sort([a, b])
      assert Enum.map(result.excluded.radius, & &1.solar_system_id) == [c]
      assert Enum.map(result.excluded.unroutable, & &1.solar_system_id) == [island]
      # The approach leg from an out-of-scope start is real work and is
      # not silently dropped, but the start itself is not a stop.
      refute start in stop_ids(result)

      # radius: 0 turns it off; the island stays unroutable regardless.
      assert {:ok, unbounded} = Targets.plan(start: start, radius: 0)
      assert Enum.sort(stop_ids(unbounded)) == Enum.sort([a, b, c])
      assert unbounded.excluded.radius == []
    end
  end

  describe "families" do
    test "a NoFuel structure is not a target until the dead family is ticked" do
      [unanchoring, no_fuel] = chain(2, 991_610_500, "Region Family")
      since = DateTime.add(DateTime.utc_now(), -1, :day)

      put_structure(991_610_591, unanchoring, "Unanchoring", since)
      put_structure(991_610_592, no_fuel, "NoFuel", nil)

      assert {:ok, default} = Targets.plan(radius: 0)
      assert stop_ids(default) == [unanchoring]

      assert {:ok, both} = Targets.plan(radius: 0, families: [:unanchoring, :dead])
      assert Enum.sort(stop_ids(both)) == Enum.sort([unanchoring, no_fuel])

      # A finding with no deadline is still a target; it just has
      # nothing to say in the deadline column.
      assert both.targets[no_fuel].earliest_deadline == nil
    end

    test "nothing matching is :no_targets, not an empty route" do
      assert Targets.plan(radius: 0, families: [:unanchored]) == {:error, :no_targets}
    end
  end

  describe "the confirmation window" do
    test "a finding nobody has re-confirmed inside the window is not a target" do
      [fresh, stale] = chain(2, 991_610_600, "Region Confirm")
      now = DateTime.utc_now()
      since = DateTime.add(now, -1, :day)

      put_structure(991_610_691, fresh, "Unanchoring", since,
        last_confirmed_at: DateTime.add(now, -2, :hour)
      )

      put_structure(991_610_692, stale, "Unanchoring", since,
        last_confirmed_at: DateTime.add(now, -4, :day)
      )

      assert {:ok, narrow} = Targets.plan(radius: 0, window_days: 1)
      assert stop_ids(narrow) == [fresh]

      assert {:ok, wide} = Targets.plan(radius: 0, window_days: 7)
      assert Enum.sort(stop_ids(wide)) == Enum.sort([fresh, stale])
    end
  end

  describe "presence and archiving" do
    test "a structure the absence pipeline has taken off grid is not somewhere to fly" do
      [gone, seen] = chain(2, 991_610_700, "Region Presence")
      since = DateTime.add(DateTime.utc_now(), -1, :day)

      put_structure(991_610_791, gone, "Unanchoring", since, presence: :gone)
      put_structure(991_610_792, seen, "Unanchoring", since)

      assert {:ok, result} = Targets.plan(radius: 0)
      assert stop_ids(result) == [seen]
    end
  end

  # -------------------------------------------------------------------
  # Fixtures
  # -------------------------------------------------------------------

  defp stop_ids(%{route: route}), do: Enum.map(route.stops, & &1.solar_system_id)

  # `n` highsec systems in one region, wired into a line so every
  # distance is unambiguous.
  defp chain(n, base, region_name) do
    ids = Enum.map(1..n, &(base + &1))

    Enum.each(ids, fn id -> put_system(id, "SYS#{id}", region_name, 7, "0.6") end)

    ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] -> put_jump(a, b) end)

    ids
  end

  defp put_system(solar_system_id, name, region_name, system_class, security) do
    {:ok, _system} =
      MapSolarSystem
      |> Ash.Changeset.for_create(:create, %{
        solar_system_id: solar_system_id,
        solar_system_name: name,
        solar_system_name_lc: String.downcase(name),
        region_id: 1,
        region_name: region_name,
        constellation_id: 1,
        constellation_name: "Constellation",
        system_class: system_class,
        security: security
      })
      |> Ash.create(authorize?: false)
  end

  defp put_jump(from_id, to_id) do
    {:ok, _jump} =
      MapSolarSystemJumps
      |> Ash.Changeset.for_create(:create, %{
        from_solar_system_id: from_id,
        to_solar_system_id: to_id
      })
      |> Ash.create(authorize?: false)
  end

  defp put_structure(structure_id, solar_system_id, status, unanchoring_since, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _row} =
      ScoutStructure
      |> Ash.Changeset.for_create(:create, %{
        structure_id: structure_id,
        solar_system_id: solar_system_id,
        structure_name: "FIX #{structure_id}",
        group_name: "Citadel",
        status: status,
        presence: Keyword.get(opts, :presence, :seen),
        unanchoring_since: unanchoring_since,
        first_seen_at: DateTime.add(now, -3, :day),
        last_confirmed_at: Keyword.get(opts, :last_confirmed_at, DateTime.add(now, -1, :hour))
      })
      |> Ash.create(authorize?: false)
  end
end
