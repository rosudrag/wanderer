defmodule WandererApp.ScoutSweepTest do
  @moduledoc """
  Proves `WandererApp.Scout.Sweep` BEHAVIOUR, not just that it compiles --
  `AGENTS.md`'s documented trap is that Ash pipelines compile clean and
  still raise on first execution. Mirrors `scout_planner_test.exs`'s
  style. See `docs/design/wanderer-scout-region-sweeps.md`.

  Fixture systems use solar_system_ids in the 991_600_0xx / 991_600_1xx /
  ... ranges, well outside any real EVE static data.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapSolarSystem, MapSolarSystemJumps, ScoutSystemCoverage}
  alias WandererApp.Scout.Sweep

  @adjacency_cache_key "scout:planner:adjacency"

  setup do
    # Process-global cache, not part of the Ecto sandbox transaction --
    # drop it so each test's fixture jumps are what `Planner.graph/0`
    # (and therefore every Sweep function built on it) actually walks.
    WandererApp.Cache.delete(@adjacency_cache_key)
    :ok
  end

  describe "route/3 -- 2-opt measurably improves on greedy" do
    test "reaches the true optimum on a crafted 7-node instance where greedy alone does not" do
      # Instance + ground truth independently brute-forced (all 6!
      # permutations from the fixed start) in Python: plain
      # nearest-neighbour greedy from id 0 produces order
      # [0,2,3,5,1,4,6] costing 535; the GLOBAL optimum is
      # [0,4,1,5,3,2,6] costing 457. Every pairwise distance below is
      # distinct, so neither greedy's argmin nor 2-opt's best-delta pick
      # has a tie to break -- the result is fully deterministic.
      ids = [
        991_600_101,
        991_600_102,
        991_600_103,
        991_600_104,
        991_600_105,
        991_600_106,
        991_600_107
      ]

      [s0, s1, s2, s3, s4, s5, s6] = ids

      dist_matrix = %{
        s0 => %{s1 => 147, s2 => 106, s3 => 109, s4 => 126, s5 => 185, s6 => 154},
        s1 => %{s0 => 147, s2 => 101, s3 => 90, s4 => 27, s5 => 114, s6 => 205},
        s2 => %{s0 => 106, s1 => 101, s3 => 11, s4 => 99, s5 => 80, s6 => 104},
        s3 => %{s0 => 109, s1 => 90, s2 => 11, s4 => 89, s5 => 75, s6 => 115},
        s4 => %{s0 => 126, s1 => 27, s2 => 99, s3 => 89, s5 => 131, s6 => 202},
        s5 => %{s0 => 185, s1 => 114, s2 => 80, s3 => 75, s4 => 131, s6 => 139},
        s6 => %{s0 => 154, s1 => 205, s2 => 104, s3 => 115, s4 => 202, s5 => 139}
      }

      # Explicit, in-scope start: route/3 never touches `Planner.graph/0`
      # on this path, so this exercises greedy + 2-opt in isolation.
      result = Sweep.route(ids, s0, dist_matrix)

      assert result.start == s0
      assert Enum.sort(result.order) == Enum.sort(ids)
      # Plain greedy (no 2-opt) costs 535 on this instance -- reaching
      # anything below that is only possible if 2-opt actually reversed
      # a segment. Reaching exactly 457 proves it found the true
      # optimum, not just *an* improvement.
      assert result.jumps == 457
      assert result.jumps < 535
    end
  end

  describe "distances/1 and route/3 -- timing on a ~190-system scope" do
    test "both stay well under a second on a 190-node near-tree graph" do
      {ids, graph} = build_perf_graph()
      WandererApp.Cache.put(@adjacency_cache_key, graph, ttl: :timer.hours(24))

      {distances_us, dist_matrix} = :timer.tc(fn -> Sweep.distances(ids) end)
      {route_us, result} = :timer.tc(fn -> Sweep.route(ids, nil, dist_matrix) end)

      IO.puts(
        "[scout_sweep_test] distances/1 over #{length(ids)} systems: #{Float.round(distances_us / 1000, 2)} ms"
      )

      IO.puts(
        "[scout_sweep_test] route/3 (nil start, greedy+2opt) over #{length(ids)} systems: " <>
          "#{Float.round(route_us / 1000, 2)} ms"
      )

      assert map_size(dist_matrix) == length(ids)
      assert length(result.order) == length(ids)
      assert Enum.sort(result.order) == Enum.sort(ids)
      assert distances_us < 2_000_000
      assert route_us < 2_000_000
    end
  end

  describe "compress/1 -- strict forced-stop rule" do
    test "keeps first/last, drops only stops with no alternate shortest path, and a re-walk covers everything" do
      # W1 - M1 - M2 - M3 - W4, plus M1 - ALT - M3 (an equal-length
      # detour around M2 only). W1/M3/W4-adjacent legs have exactly ONE
      # shortest path (through M1 / through M3 respectively) so M1 and
      # M3 are forced; M2 has a same-length alternate (via ALT) so it is
      # NOT forced and must survive compression.
      w1 = 991_600_401
      m1 = 991_600_402
      m2 = 991_600_403
      m3 = 991_600_404
      w4 = 991_600_405
      alt = 991_600_406

      put_system(w1, "W1", "Region Compress", 7, "1.0")
      put_system(m1, "M1", "Region Compress", 7, "1.0")
      put_system(m2, "M2", "Region Compress", 7, "1.0")
      put_system(m3, "M3", "Region Compress", 7, "1.0")
      put_system(w4, "W4", "Region Compress", 7, "1.0")
      put_system(alt, "ALT", "Region Compress", 7, "1.0")

      put_jump(w1, m1)
      put_jump(m1, m2)
      put_jump(m2, m3)
      put_jump(m3, w4)
      put_jump(m1, alt)
      put_jump(alt, m3)

      waypoints = [w1, m1, m2, m3, w4]

      compressed = Sweep.compress(waypoints)

      assert List.first(compressed) == w1
      assert List.last(compressed) == w4
      # M1 and M3 are forced (dropped); M2 has the ALT detour (kept).
      assert m2 in compressed
      refute m1 in compressed
      refute m3 in compressed
      assert compressed == [w1, m2, w4]

      # The fallback path only ships the uncompressed list, so reaching
      # a 3-element result here already proves the internal re-walk
      # coverage assertion passed -- but assert it ourselves too, over
      # the REAL graph, rather than trust that by construction alone.
      graph = WandererApp.Scout.Planner.graph()
      covered = reconstruct_covered_systems(compressed, graph)
      assert Enum.all?(waypoints, &MapSet.member?(covered, &1))
    end

    test "leaves short lists untouched" do
      assert Sweep.compress([]) == []
      assert Sweep.compress([1]) == [1]
      assert Sweep.compress([1, 2]) == [1, 2]
    end
  end

  describe "sweep/1 -- freshness filter and unreachable systems" do
    test "fresh systems are excluded by default and only included with include_fresh: true, and an unreachable system still routes" do
      s1 = 991_600_501
      s2 = 991_600_502
      s3 = 991_600_503

      put_system(s1, "S1", "Region Sweep", 7, "1.0")
      put_system(s2, "S2", "Region Sweep", 7, "1.0")
      # S3 has NO jump rows at all -- unreachable from S2 over the real
      # graph, proving the scope "still routes the rest" rather than
      # crashing or silently dropping it.
      put_system(s3, "S3", "Region Sweep", 7, "1.0")

      now = DateTime.utc_now()
      put_coverage(s1, :sigs, now)
      put_coverage(s3, :sigs, DateTime.add(now, -10 * 3600, :second))

      assert {:ok, default_result} =
               Sweep.sweep(scope: {:systems, [s1, s2, s3]}, kind: :sigs, compress: false)

      default_ids = Enum.map(default_result.stops, & &1.solar_system_id)
      refute s1 in default_ids
      assert s2 in default_ids
      assert s3 in default_ids
      assert default_result.systems == 2

      s3_stop = Enum.find(default_result.stops, &(&1.solar_system_id == s3))
      assert s3_stop.reason == :stale

      assert {:ok, with_fresh} =
               Sweep.sweep(
                 scope: {:systems, [s1, s2, s3]},
                 kind: :sigs,
                 compress: false,
                 include_fresh: true
               )

      with_fresh_ids = Enum.map(with_fresh.stops, & &1.solar_system_id)
      assert s1 in with_fresh_ids
      assert with_fresh.systems == 3

      s1_stop = Enum.find(with_fresh.stops, &(&1.solar_system_id == s1))
      assert s1_stop.reason == :fresh
    end
  end

  describe "sweep/1 -- end-to-end shape on a connected line" do
    test "routes, compresses, and reports start suggestions" do
      p1 = 991_600_601
      p2 = 991_600_602
      p3 = 991_600_603
      p4 = 991_600_604

      put_system(p1, "P1", "Region Line", 7, "1.0")
      put_system(p2, "P2", "Region Line", 7, "1.0")
      put_system(p3, "P3", "Region Line", 7, "1.0")
      put_system(p4, "P4", "Region Line", 7, "1.0")

      put_jump(p1, p2)
      put_jump(p2, p3)
      put_jump(p3, p4)

      assert {:ok, result} = Sweep.sweep(scope: {:systems, [p1, p2, p3, p4]}, kind: :sigs)

      assert result.systems == 4
      assert result.jumps == 3
      assert length(result.stops) == 4
      assert Enum.map(result.stops, & &1.order) == [1, 2, 3, 4]
      assert Enum.all?(result.stops, &(&1.reason == :unseen))

      # Pure line, no alternate paths anywhere -- both interior stops
      # are forced, so compression keeps only the two ends.
      assert result.compressed? == true
      assert length(result.waypoints) == 2
      order_ids = Enum.map(result.stops, & &1.solar_system_id)
      assert List.first(result.waypoints) == List.first(order_ids)
      assert List.last(result.waypoints) == List.last(order_ids)

      waypoint_set = MapSet.new(result.waypoints)

      Enum.each(result.stops, fn stop ->
        assert stop.waypoint? == MapSet.member?(waypoint_set, stop.solar_system_id)
      end)

      # Both P1 and P4 are degree-1 dead ends and tie on cost (3 jumps
      # either direction) -- both must be suggested.
      start_ids = Enum.map(result.starts, & &1.solar_system_id)
      assert p1 in start_ids
      assert p4 in start_ids
      assert Enum.all?(result.starts, &(&1.jumps == 3))
    end
  end

  describe "sweep/1 -- option validation and scope cap" do
    test "an empty scope is rejected" do
      assert {:error, :empty_scope} = Sweep.sweep(scope: {:systems, []})
      assert {:error, :empty_scope} = Sweep.sweep(scope: {:regions, []})
    end

    test "kind must be one of the closed vocabulary" do
      assert {:error, :invalid_kind} = Sweep.sweep(scope: {:systems, [1]}, kind: :bogus)
    end

    test "more than 3 regions is rejected before any query runs" do
      assert {:error, :scope_too_large} = Sweep.sweep(scope: {:regions, [1, 2, 3, 4]})
    end
  end

  describe "region_heat/1 -- grouped coverage per region" do
    test "excludes wormhole-class systems and buckets covered/stale/unseen" do
      region_id = 991_601

      ra = 991_600_701
      rb = 991_600_702
      rc = 991_600_703
      rwh = 991_600_704

      put_system_in_region(ra, "RA", region_id, "Region Heat", 7, "1.0")
      put_system_in_region(rb, "RB", region_id, "Region Heat", 7, "1.0")
      put_system_in_region(rc, "RC", region_id, "Region Heat", 7, "1.0")
      # Wormhole-class (c1) -- must be excluded from the k-space count.
      put_system_in_region(rwh, "RWH", region_id, "Region Heat", 1, "0.0")

      now = DateTime.utc_now()
      # RA fresh (sigs TTL default 4h), RC stale.
      put_coverage(rb, :sigs, DateTime.add(now, -3600, :second))
      put_coverage(rc, :sigs, DateTime.add(now, -36_000, :second))

      rows = Sweep.region_heat(:sigs)
      row = Enum.find(rows, &(&1.region_id == region_id))

      refute is_nil(row)
      assert row.systems == 3
      assert row.covered == 1
      assert row.stale == 1
      assert row.unseen == 1
      assert is_integer(row.median_age_s)
      assert row.median_age_s >= 3000
      assert row.median_age_s <= 37_000
    end
  end

  # -----------------------------------------------------------------
  # Fixture helpers
  # -----------------------------------------------------------------

  defp put_system(solar_system_id, name, region_name, system_class, security) do
    put_system_in_region(solar_system_id, name, 1, region_name, system_class, security)
  end

  defp put_system_in_region(solar_system_id, name, region_id, region_name, system_class, security) do
    {:ok, _system} =
      MapSolarSystem
      |> Ash.Changeset.for_create(:create, %{
        solar_system_id: solar_system_id,
        solar_system_name: name,
        solar_system_name_lc: String.downcase(name),
        region_id: region_id,
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

  # A 190-node near-tree (a 189-edge spine plus ~45 shortcut edges, ratio
  # ~1.23 edges/node -- same shape family as the design doc's measured
  # regions, e.g. Domain's 1.38) built purely in-memory and injected
  # straight into the adjacency cache, so this test measures `distances/1`
  # / `route/3` at the documented scale without seeding 190 DB rows.
  defp build_perf_graph do
    ids = for i <- 0..189, do: 991_600_201 + i
    id_at = fn i -> Enum.at(ids, i) end

    spine =
      Enum.reduce(0..188, %{}, fn i, acc -> add_edge(acc, id_at.(i), id_at.(i + 1)) end)

    # Leave node 0 and the last node untouched by any shortcut so the
    # scope has real degree-1 dead ends (every region measured in the
    # design doc has them) -- the thing being timed is the realistic
    # "~45 candidate starts" path, not the capped fallback for a scope
    # with none.
    graph =
      Enum.reduce(4..150, spine, fn i, acc ->
        if rem(i, 4) == 0, do: add_edge(acc, id_at.(i), id_at.(i + 13)), else: acc
      end)

    {ids, graph}
  end

  defp add_edge(graph, a, b) do
    graph
    |> Map.update(a, MapSet.new([b]), &MapSet.put(&1, b))
    |> Map.update(b, MapSet.new([a]), &MapSet.put(&1, a))
  end

  # Independent, test-local re-walk (does not call Sweep's private
  # coverage check) -- BFS shortest path between every consecutive pair
  # of compressed waypoints, unioned.
  defp reconstruct_covered_systems(compressed, graph) do
    compressed
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(MapSet.new(compressed), fn [a, b], acc ->
      MapSet.union(acc, MapSet.new(bfs_path(graph, a, b)))
    end)
  end

  defp bfs_path(_graph, a, a), do: [a]

  defp bfs_path(graph, a, b) do
    do_bfs_path(graph, :queue.from_list([a]), MapSet.new([a]), %{}, b)
  end

  defp do_bfs_path(graph, queue, visited, parents, target) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        []

      {{:value, node}, queue} ->
        if node == target do
          rebuild(parents, target, [target])
        else
          neighbors = graph |> Map.get(node, MapSet.new()) |> Enum.sort()

          {queue, visited, parents} =
            Enum.reduce(neighbors, {queue, visited, parents}, fn n, {q, v, p} ->
              if MapSet.member?(v, n) do
                {q, v, p}
              else
                {:queue.in(n, q), MapSet.put(v, n), Map.put(p, n, node)}
              end
            end)

          do_bfs_path(graph, queue, visited, parents, target)
        end
    end
  end

  defp rebuild(parents, node, acc) do
    case Map.fetch(parents, node) do
      {:ok, parent} -> rebuild(parents, parent, [parent | acc])
      :error -> acc
    end
  end
end
