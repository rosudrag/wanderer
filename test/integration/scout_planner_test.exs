defmodule WandererApp.ScoutPlannerTest do
  @moduledoc """
  Proves `WandererApp.Scout.Planner.rank/1` and `plan/1` actually RUN
  against the Ash pipelines they are built on, not just compile --
  `AGENTS.md`'s documented trap is that `Ash.read(Resource, ...) |>
  Ash.Query.filter(...)` compiles clean and can still raise on first
  execution. Mirrors `test/integration/scout_coverage_test.exs`'s style.

  Fixture systems use solar_system_ids in the 990_100_0xx range, well
  outside any real EVE static data, so these tests cannot collide with
  seeded rows or another test's fixtures.

  Graph: A -- B -- C -- E, and A -- D (avoided).
    A = origin, highsec, never scouted.
    B = highsec, 1 jump, never scouted.
    C = nullsec, 2 jumps, scouted recently (fresh).
    D = highsec, 1 jump, always excluded via opts[:avoid].
    E = nullsec, 3 jumps -- outside `max_jumps: 2`, inside `max_jumps: 0`.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapSolarSystem, MapSolarSystemJumps, ScoutSystemCoverage}
  alias WandererApp.Scout.Planner

  @a 990_100_001
  @b 990_100_002
  @c 990_100_003
  @d 990_100_004
  @e 990_100_005

  setup do
    # The adjacency cache is process-global (WandererApp.Cache), not
    # part of the Ecto sandbox transaction -- drop it so each test's
    # fixture jumps are the ones BFS actually walks.
    WandererApp.Cache.delete("scout:planner:adjacency")

    put_system(@a, "Alpha", "Region A", 7, "1.0")
    put_system(@b, "Bravo", "Region A", 7, "0.9")
    put_system(@c, "Charlie", "Region A", 9, "-0.2")
    put_system(@d, "Delta", "Region A", 7, "0.8")
    put_system(@e, "Echo", "Region A", 9, "-0.3")

    put_jump(@a, @b)
    put_jump(@b, @c)
    put_jump(@a, @d)
    put_jump(@c, @e)

    put_coverage(@c, :sigs, DateTime.utc_now())

    :ok
  end

  describe "option validation" do
    test "origin is required" do
      assert {:error, :invalid_origin} = Planner.rank(kind: :sigs)
    end

    test "kind must be one of the closed vocabulary" do
      assert {:error, :invalid_kind} = Planner.rank(origin: @a, kind: :bogus)
    end
  end

  describe "rank/1 against the real graph and coverage tables" do
    test "scopes by max_jumps and avoid, and ranks unseen above fresh" do
      assert {:ok, result} =
               Planner.rank(
                 origin: @a,
                 kind: :sigs,
                 max_jumps: 2,
                 avoid: [@d],
                 security: [:hs, :ns]
               )

      ids = Enum.map(result.stops, & &1.solar_system_id)

      # In scope: A (origin), B (1 jump), C (2 jumps).
      assert @a in ids
      assert @b in ids
      assert @c in ids
      # D is avoided outright -- hard zero, never just penalised.
      refute @d in ids
      # E is 3 jumps away, outside max_jumps: 2.
      refute @e in ids
      assert result.candidates == length(result.stops)

      stop_b = Enum.find(result.stops, &(&1.solar_system_id == @b))
      stop_c = Enum.find(result.stops, &(&1.solar_system_id == @c))

      assert stop_b.reason == :unseen
      assert stop_b.age_s == -1
      assert stop_b.jumps == 1
      assert stop_b.leg == :gate

      assert stop_c.reason == :fresh
      assert stop_c.age_s >= 0
      assert stop_c.jumps == 2

      # Unseen beats freshly-covered (design doc section 5), even though
      # C is nullsec (higher `value`) -- `need` dominates at NEED_MAX.
      assert stop_b.score > stop_c.score
    end

    test "need is capped at NEED_MAX for a very old observation" do
      ancient = DateTime.add(DateTime.utc_now(), -1000 * 24 * 3600, :second)
      put_coverage(@b, :sigs, ancient)

      assert {:ok, result} =
               Planner.rank(origin: @a, kind: :sigs, max_jumps: 1, security: [:hs, :ns])

      stop_b = Enum.find(result.stops, &(&1.solar_system_id == @b))

      assert stop_b.reason == :stale
      assert stop_b.terms.need == 5.0
    end

    test "max_jumps: 0 removes the ball entirely" do
      assert {:ok, capped} =
               Planner.rank(origin: @a, kind: :sigs, max_jumps: 2, security: [:hs, :ns])

      assert {:ok, unlimited} =
               Planner.rank(origin: @a, kind: :sigs, max_jumps: 0, security: [:hs, :ns])

      refute @e in Enum.map(capped.stops, & &1.solar_system_id)

      stop_e = Enum.find(unlimited.stops, &(&1.solar_system_id == @e))

      assert stop_e.jumps == 3
      assert stop_e.leg == :gate
    end
  end

  describe "plan/1 against the real graph" do
    test "returns an ordered, budget-capped route of gate legs" do
      assert {:ok, result} =
               Planner.plan(
                 origin: @a,
                 kind: :sigs,
                 limit: 2,
                 max_jumps: 2,
                 avoid: [@d],
                 security: [:hs, :ns]
               )

      assert length(result.stops) <= 2

      Enum.each(result.stops, fn stop ->
        assert stop.solar_system_id in [@a, @b, @c]
        assert stop.leg == :gate
      end)
    end

    test "max_jumps: 0 walks past the default budget without an arithmetic error" do
      assert {:ok, result} =
               Planner.plan(
                 origin: @a,
                 kind: :sigs,
                 limit: 10,
                 max_jumps: 0,
                 avoid: [@d],
                 security: [:hs, :ns]
               )

      ids = Enum.map(result.stops, & &1.solar_system_id)

      # Every reachable, non-avoided, in-band system, E included -- it
      # sits at 3 jumps, which the `max_jumps: 2` test above excludes.
      assert @e in ids
      assert Enum.sum(Enum.map(result.stops, & &1.jumps)) >= 3
      refute @a in ids
    end
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
        constellation_name: "Constellation A",
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

  defp put_coverage(solar_system_id, kind, observed_at) do
    {:ok, _row} =
      ScoutSystemCoverage.create(
        %{
          solar_system_id: solar_system_id,
          kind: kind,
          observed_at: observed_at,
          source: "test"
        },
        authorize?: false
      )
  end
end
