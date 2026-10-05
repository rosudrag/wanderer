defmodule WandererApp.ScoutSplitTest do
  @moduledoc """
  Proves `WandererApp.Scout.Split.split/3` and `WandererApp.Scout.
  Assignments` actually RUN against the Ash/graph pipelines they are built
  on, not just compile -- `AGENTS.md`'s documented trap is that an Ash
  pipeline can compile clean and still raise on first execution. Mirrors
  `test/integration/scout_planner_test.exs`'s style.

  Fixture systems use solar_system_ids in the 993_500_0xx range, well
  outside any real EVE static data, so these tests cannot collide with
  seeded rows or another test's fixtures.

  ## The split fixture: one hub, four uneven spurs

  ```
            S1_1 - S1_2 - S1_3 - S1_4   (spur 1, length 4)
           /
    S3_2 - S3_1 - H - S2_1 - S2_2 - S2_3   (spur 2, length 3)
                  |
                  D1 - D2 - D3   (spur "D", length 3; spur 3 length 2)
  ```

  13 systems, one junction (`H`), four spurs of lengths 4/3/2/3 hanging
  off it directly -- the shape `docs/design/wanderer-scout-region-sweeps.md`
  section 5 describes as "one part may be all dead-end spurs": a
  capacity-balanced (count-only) k-medoids pass can split a single spur
  across two parts (nothing in steps 1-3 reasons about route cost, only
  node-to-medoid distance), stranding part of a spur -- even `H` itself --
  behind a system owned by the OTHER part. Step 4 is the only step that
  can see that and fix it, which is exactly what the rebalance test below
  measures (observed on this fixture: makespan 10 -> 7).
  """

  use WandererApp.DataCase, async: false

  require Ash.Query

  alias WandererApp.Api.{MapSolarSystemJumps, ScoutAssignment}
  alias WandererApp.Scout.{Assignments, Coverage, Split}

  @h 993_500_001

  @s1_1 993_500_011
  @s1_2 993_500_012
  @s1_3 993_500_013
  @s1_4 993_500_014

  @s2_1 993_500_021
  @s2_2 993_500_022
  @s2_3 993_500_023

  @s3_1 993_500_031
  @s3_2 993_500_032

  @d1 993_500_041
  @d2 993_500_042
  @d3 993_500_043

  @all_ids [
    @h,
    @s1_1,
    @s1_2,
    @s1_3,
    @s1_4,
    @s2_1,
    @s2_2,
    @s2_3,
    @s3_1,
    @s3_2,
    @d1,
    @d2,
    @d3
  ]

  setup do
    # The adjacency cache is process-global (WandererApp.Cache), not part
    # of the Ecto sandbox transaction -- drop it so each test's fixture
    # jumps are the ones `Sweep.distances/1`/`route/3` actually BFS over.
    # Same reason `scout_planner_test.exs` does this.
    WandererApp.Cache.delete("scout:planner:adjacency")

    put_jump(@h, @s1_1)
    put_jump(@s1_1, @s1_2)
    put_jump(@s1_2, @s1_3)
    put_jump(@s1_3, @s1_4)

    put_jump(@h, @s2_1)
    put_jump(@s2_1, @s2_2)
    put_jump(@s2_2, @s2_3)

    put_jump(@h, @s3_1)
    put_jump(@s3_1, @s3_2)

    put_jump(@h, @d1)
    put_jump(@d1, @d2)
    put_jump(@d2, @d3)

    :ok
  end

  describe "split/3 -- disjoint coverage" do
    test "k=3 split produces disjoint parts covering every system" do
      assert {:ok, parts} = Split.split(@all_ids, 3)

      all_assigned = Enum.flat_map(parts, & &1.system_ids)

      # Every system appears, and appears exactly once -- no system is
      # dropped and no system is double-assigned.
      assert Enum.sort(all_assigned) == Enum.sort(@all_ids)
      assert length(all_assigned) == length(@all_ids)

      # Pairwise disjoint, the same fact checked a different way.
      for {a, b} <- pairs(parts) do
        assert MapSet.disjoint?(MapSet.new(a.system_ids), MapSet.new(b.system_ids))
      end

      # Every part's `order` is a permutation of its own `system_ids`, and
      # `start` is one of them.
      Enum.each(parts, fn part ->
        assert Enum.sort(part.order) == Enum.sort(part.system_ids)
        assert part.start in part.system_ids
        assert part.jumps >= 0
      end)

      # Sequential, gap-free indices.
      assert Enum.map(parts, & &1.index) == Enum.to_list(0..(length(parts) - 1))
    end

    test "k larger than the distinct system count is refused" do
      assert {:error, :too_few_systems} = Split.split([@h, @s1_1], 5)
    end

    test "an empty scope is refused" do
      assert {:error, :empty_scope} = Split.split([], 2)
    end
  end

  describe "split/3 -- step 4 rebalance" do
    test "rebalance strictly lowers the makespan versus the pre-rebalance (Lloyd-only) split" do
      assert {:ok, lloyd_only_parts} = Split.split(@all_ids, 2, rebalance: false)
      assert {:ok, rebalanced_parts} = Split.split(@all_ids, 2, rebalance: true)

      lloyd_only_makespan = lloyd_only_parts |> Enum.map(& &1.jumps) |> Enum.max()
      rebalanced_makespan = rebalanced_parts |> Enum.map(& &1.jumps) |> Enum.max()

      # Step 4 must actually have found and taken an improving move on
      # this fixture -- not merely "no worse".
      assert rebalanced_makespan < lloyd_only_makespan

      # Coverage is never sacrificed to buy that improvement.
      rebalanced_ids = rebalanced_parts |> Enum.flat_map(& &1.system_ids) |> Enum.sort()
      assert rebalanced_ids == Enum.sort(@all_ids)

      for {a, b} <- pairs(rebalanced_parts) do
        assert MapSet.disjoint?(MapSet.new(a.system_ids), MapSet.new(b.system_ids))
      end
    end
  end

  describe "Assignments.assign/2 and active_system_ids/1" do
    test "an expired assignment is not active" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      assert {:ok, %{rows: 1}} =
               Assignments.assign(
                 [%{character_eve_id: "991000001", system_ids: [@s1_1]}],
                 kind: :sigs,
                 expires_at: past
               )

      refute MapSet.member?(Assignments.active_system_ids(:sigs), @s1_1)
      assert Assignments.owned_by("991000001", :sigs) == []
    end

    test "re-assigning a system actively owned by a DIFFERENT character is refused" do
      assert {:ok, %{assignment_id: _id, rows: 1}} =
               Assignments.assign(
                 [%{character_eve_id: "991000002", system_ids: [@s2_1]}],
                 kind: :sigs
               )

      assert {:error, :already_assigned} =
               Assignments.assign(
                 [%{character_eve_id: "991000003", system_ids: [@s2_1]}],
                 kind: :sigs
               )

      # The original owner is unaffected -- refusal, not theft.
      assert Assignments.owned_by("991000002", :sigs) == [@s2_1]

      # Re-assigning to the SAME character is not a conflict with itself.
      assert {:ok, %{rows: 1}} =
               Assignments.assign(
                 [%{character_eve_id: "991000002", system_ids: [@s2_1]}],
                 kind: :sigs
               )
    end

    test "two groups in the same batch claiming the same system is refused before any write" do
      assert {:error, :conflicting_batch} =
               Assignments.assign(
                 [
                   %{character_eve_id: "991000004", system_ids: [@d1]},
                   %{character_eve_id: "991000005", system_ids: [@d1]}
                 ],
                 kind: :sigs
               )

      assert Assignments.active_system_ids(:sigs) |> MapSet.member?(@d1) == false
    end

    test "a different kind is an independent ownership space" do
      assert {:ok, _} =
               Assignments.assign(
                 [%{character_eve_id: "991000006", system_ids: [@d2]}],
                 kind: :sigs
               )

      assert {:ok, _} =
               Assignments.assign(
                 [%{character_eve_id: "991000007", system_ids: [@d2]}],
                 kind: :anoms
               )

      assert Assignments.owned_by("991000006", :sigs) == [@d2]
      assert Assignments.owned_by("991000007", :anoms) == [@d2]
    end
  end

  describe "coverage arriving completes an assignment" do
    test "a coverage row for an assigned system+kind marks the assignment completed" do
      assert {:ok, %{assignment_id: assignment_id}} =
               Assignments.assign(
                 [%{character_eve_id: "991000008", system_ids: [@d3]}],
                 kind: :sigs
               )

      assert MapSet.member?(Assignments.active_system_ids(:sigs), @d3)

      assert {:ok, %{stored: 1, failed: 0}} =
               Coverage.ingest_coverage(
                 [
                   %{
                     "solar_system_id" => @d3,
                     "kind" => "sigs",
                     "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
                     "character_eve_id" => "991000008",
                     "source" => "test"
                   }
                 ],
                 nil
               )

      refute MapSet.member?(Assignments.active_system_ids(:sigs), @d3)

      assert {:ok, [row]} =
               ScoutAssignment
               |> Ash.Query.filter(assignment_id == ^assignment_id)
               |> Ash.read(authorize?: false)

      refute is_nil(row.completed_at)
    end

    test "coverage for a different kind does not complete an unrelated assignment" do
      assert {:ok, _} =
               Assignments.assign(
                 [%{character_eve_id: "991000009", system_ids: [@s3_2]}],
                 kind: :grid
               )

      assert {:ok, %{stored: 1}} =
               Coverage.ingest_coverage(
                 [
                   %{
                     "solar_system_id" => @s3_2,
                     "kind" => "visit",
                     "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
                     "source" => "test"
                   }
                 ],
                 nil
               )

      assert MapSet.member?(Assignments.active_system_ids(:grid), @s3_2)
    end
  end

  defp pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
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
end
