defmodule WandererApp.Scout.Split do
  @moduledoc """
  CHEWY PATCH: splits a sweep's system list into `k` roughly-equal-WORKLOAD
  parts -- balanced k-medoids seeded by farthest-point sampling, then a
  route-cost rebalance. See `docs/design/wanderer-scout-region-sweeps.md`
  section 5, which measured every number referenced below on the real
  Domain/Sinq Laison/Fountain/Catch graphs.

  Four steps, in the order the design doc requires, and all four are
  load-bearing:

    1. Farthest-point seeds (`k` of them), the FIRST seed forced to be a
       local dead end -- section 4's finding that the best sweep START is
       always a degree-1 system applies just as much to a part's own route.
    2. Capacity-balanced assignment: every candidate sorted by distance to
       its nearest medoid DESCENDING, assigned to its nearest medoid not yet
       at `ceil(n/k)`. The descending order is what keeps a remote system
       from being shut out of its own part by nearer, easier systems eating
       the capacity first.
    3. Lloyd iterations: recompute each part's 1-median, reassign, repeat
       until the partition stops changing (design doc: converges in under
       12 rounds on every region measured).
    4. Route-cost rebalance: repeatedly move one boundary system (a system
       in the worst part with a direct 1-jump neighbour in another part)
       into that ADJACENT part, accepting the move only if it strictly
       lowers the MAKESPAN (the slowest part's route). This step alone is
       worth ~35% of the measured speedup on Domain k=4 (131 jumps makespan
       before it, 87 after) -- equal system COUNTS are not equal work,
       because one part can be all dead-end spurs.

  The objective throughout step 4 is makespan, not total jumps -- total
  jumps go UP when a region is split (more backtracking per part); that is
  the correct trade, see the design doc's closing line on this.

  ## What this module does NOT do

  It does not resolve a sweep's candidate systems (`WandererApp.Scout.
  Sweep.sweep/1` does that) and it does not decide WHICH character gets
  which part or persist that decision (`WandererApp.Scout.Assignments`
  does). `split/3` is a pure function of a system list and `k`.

  ## Degree is a proxy, not a real adjacency read

  `Sweep.distances/1` is the only graph primitive this module has -- there
  is no raw adjacency list in the shared contract. "Local degree" and
  "adjacent part" below both reconstruct what they need from the all-pairs
  distance matrix: two systems are directly connected if and only if their
  shortest-path distance is 1, which is exactly a real one-jump gate edge
  (the matrix is BFS over the FULL k-space graph, not an induced subgraph,
  so a distance of 1 is never an artefact of restricting to the scope).
  """

  alias WandererApp.Scout.Sweep

  @type part :: %{
          index: non_neg_integer(),
          system_ids: [integer()],
          order: [integer()],
          jumps: non_neg_integer(),
          start: integer()
        }

  # Sentinel for "no path found between these two in the distance matrix" --
  # large enough to never win a `min_by`/`max_by` against any real jump
  # count, never so large it risks integer overflow surprises downstream.
  @unreachable 1_000_000

  # Design doc: "converges in <12 rounds on every region measured".
  @default_max_lloyd_rounds 12

  # The design doc gives no fixed cap for step 4 -- only "repeatedly ...
  # accepting only moves that lower the makespan", which is itself a
  # monotonically-decreasing non-negative integer and therefore finite on
  # its own. This is a compute guard, not a correctness one; it is far
  # above anything the ~450-system cross-region ceiling needs.
  @default_max_rebalance_rounds 200

  # Wall-clock guard for step 4, measured on the real Domain graph
  # (189 systems, 2026-10-05): k=2 ran 15.3 s to exhaustion, k=3 5.4 s,
  # k=4 3.7 s -- k=2 is worst because its parts are biggest and its
  # boundary longest. A human waits on this synchronously from
  # /scout/refresh, so the loop stops here and keeps the improvement it
  # already has. 0 disables the guard (tests that assert the full
  # improvement pass it).
  @default_rebalance_budget_ms 2_000

  @doc """
  Splits `system_ids` into `k` parts.

  opts:
    * `:distances` -- a precomputed `Sweep.distances/1` result, to avoid
      recomputing it when the caller already has one (e.g. the sweep that
      produced `system_ids` already paid for it).
    * `:rebalance` -- defaults `true`. `false` returns the Lloyd-converged
      split WITHOUT step 4, which is the "before" side when measuring step
      4's own contribution to the makespan.
    * `:max_lloyd_rounds` -- defaults #{@default_max_lloyd_rounds}.
    * `:max_rebalance_rounds` -- defaults #{@default_max_rebalance_rounds}.
    * `:budget_ms` -- wall-clock cap on step 4, defaults
      #{@default_rebalance_budget_ms}. `0` disables it and runs the
      rebalance to exhaustion.

  Errors: `:empty_scope` (empty `system_ids`), `:invalid_k` (`k` not a
  positive integer), `:too_few_systems` (`k` exceeds the distinct system
  count).
  """
  @spec split([integer()], pos_integer(), keyword()) :: {:ok, [part()]} | {:error, atom()}
  def split(system_ids, k, opts \\ [])

  def split([], _k, _opts), do: {:error, :empty_scope}

  def split(_system_ids, k, _opts) when not is_integer(k) or k < 1,
    do: {:error, :invalid_k}

  def split(system_ids, k, opts) do
    ids = Enum.uniq(system_ids)
    n = length(ids)

    if k > n do
      {:error, :too_few_systems}
    else
      distances = Keyword.get(opts, :distances) || Sweep.distances(ids)
      capacity = ceil_div(n, k)

      assignment =
        ids
        |> farthest_point_seeds(distances, k)
        |> then(&capacity_balanced_assign(ids, &1, distances, capacity))
        |> lloyd(
          ids,
          distances,
          capacity,
          k,
          Keyword.get(opts, :max_lloyd_rounds, @default_max_lloyd_rounds)
        )

      parts =
        assignment
        |> build_parts(k, distances)
        |> maybe_rebalance(distances, opts)
        |> finalize()

      {:ok, parts}
    end
  end

  defp maybe_rebalance(parts, distances, opts) do
    if Keyword.get(opts, :rebalance, true) do
      rebalance(
        parts,
        distances,
        Keyword.get(opts, :max_rebalance_rounds, @default_max_rebalance_rounds),
        System.monotonic_time(:millisecond),
        Keyword.get(opts, :budget_ms, @default_rebalance_budget_ms)
      )
    else
      parts
    end
  end

  # ---------------------------------------------------------------------
  # Step 1: farthest-point seeds, first seed a local dead end.
  # ---------------------------------------------------------------------

  defp farthest_point_seeds(ids, distances, k) do
    first = first_seed(ids, distances)
    grow_seeds([first], ids, distances, k)
  end

  defp first_seed(ids, distances) do
    degree = Map.new(ids, &{&1, local_degree(&1, ids, distances)})
    dead_ends = Enum.filter(ids, &(Map.fetch!(degree, &1) == 1))
    candidates = if dead_ends == [], do: ids, else: dead_ends

    Enum.max_by(candidates, &eccentricity(&1, ids, distances))
  end

  defp local_degree(id, ids, distances) do
    Enum.count(ids, &(&1 != id and dist(distances, id, &1) == 1))
  end

  defp eccentricity(id, ids, distances) do
    Enum.reduce(ids, 0, fn other, acc -> max(acc, dist(distances, id, other)) end)
  end

  defp grow_seeds(seeds, _ids, _distances, k) when length(seeds) >= k, do: seeds

  defp grow_seeds(seeds, ids, distances, k) do
    next =
      Enum.max_by(ids -- seeds, fn id ->
        Enum.min(Enum.map(seeds, &dist(distances, id, &1)))
      end)

    grow_seeds([next | seeds], ids, distances, k)
  end

  # ---------------------------------------------------------------------
  # Step 2: capacity-balanced assignment. Returns %{system_id => part_index}.
  # ---------------------------------------------------------------------

  defp capacity_balanced_assign(ids, medoids, distances, capacity) do
    indexed = Enum.with_index(medoids, fn m, i -> {i, m} end)

    ids
    |> Enum.map(fn id -> {id, nearest_distance(id, indexed, distances)} end)
    |> Enum.sort_by(fn {_id, d} -> d end, :desc)
    |> Enum.reduce({%{}, %{}}, fn {id, _d}, {assign, counts} ->
      idx = pick_medoid(id, indexed, distances, counts, capacity)
      {Map.put(assign, id, idx), Map.update(counts, idx, 1, &(&1 + 1))}
    end)
    |> elem(0)
  end

  defp nearest_distance(id, indexed, distances) do
    indexed |> Enum.map(fn {_idx, m} -> dist(distances, id, m) end) |> Enum.min()
  end

  defp pick_medoid(id, indexed, distances, counts, capacity) do
    by_distance =
      indexed
      |> Enum.map(fn {idx, m} -> {idx, dist(distances, id, m)} end)
      |> Enum.sort_by(fn {_idx, d} -> d end)

    case Enum.find(by_distance, fn {idx, _d} -> Map.get(counts, idx, 0) < capacity end) do
      nil -> by_distance |> Enum.min_by(fn {_idx, d} -> d end) |> elem(0)
      {idx, _d} -> idx
    end
  end

  # ---------------------------------------------------------------------
  # Step 3: Lloyd iterations.
  # ---------------------------------------------------------------------

  defp lloyd(assignment, _ids, _distances, _capacity, _k, 0), do: assignment

  defp lloyd(assignment, ids, distances, capacity, k, rounds_left) do
    medoids = recompute_medoids(assignment, ids, distances, k)
    new_assignment = capacity_balanced_assign(ids, medoids, distances, capacity)

    if new_assignment == assignment do
      new_assignment
    else
      lloyd(new_assignment, ids, distances, capacity, k, rounds_left - 1)
    end
  end

  defp recompute_medoids(assignment, ids, distances, k) do
    groups = Enum.group_by(ids, &Map.fetch!(assignment, &1))

    Enum.map(0..(k - 1), fn idx ->
      case Map.get(groups, idx, []) do
        [] -> reseed_medoid(ids, groups, distances)
        members -> one_median(members, distances)
      end
    end)
  end

  defp one_median(members, distances) do
    Enum.min_by(members, fn candidate ->
      Enum.reduce(members, 0, fn other, acc -> acc + dist(distances, candidate, other) end)
    end)
  end

  # A Lloyd round can (rarely, on a lopsided capacity) empty a part. Reseed
  # it with the point farthest from everyone currently assigned anywhere --
  # the same farthest-point intuition as step 1 -- so the next
  # capacity-balanced pass has somewhere to put it back.
  defp reseed_medoid(ids, groups, distances) do
    existing = groups |> Map.values() |> List.flatten()

    Enum.max_by(ids, fn id ->
      Enum.reduce(existing, 0, fn other, acc -> acc + dist(distances, id, other) end)
    end)
  end

  # ---------------------------------------------------------------------
  # Parts: route each part over the FULL graph distances (a part's route
  # may transit outside the part -- Sinq Laison's internally-disconnected
  # systems are why).
  # ---------------------------------------------------------------------

  defp build_parts(assignment, k, distances) do
    groups = Enum.group_by(Map.keys(assignment), &Map.fetch!(assignment, &1))

    0..(k - 1)
    |> Enum.map(fn idx -> route_for(idx, Map.get(groups, idx, []), distances) end)
    |> Enum.reject(&is_nil/1)
  end

  defp route_for(_idx, [], _distances), do: nil

  defp route_for(idx, system_ids, distances) do
    %{order: order, jumps: jumps, start: start} = Sweep.route(system_ids, nil, distances)
    %{index: idx, system_ids: system_ids, order: order, jumps: jumps, start: start}
  end

  # Re-number sequentially 0..length-1 -- a part emptied by an unlucky
  # Lloyd round is dropped in `build_parts/3`, and callers should never see
  # a gap in `index`.
  defp finalize(parts) do
    parts
    |> Enum.sort_by(& &1.index)
    |> Enum.with_index(fn part, idx -> %{part | index: idx} end)
  end

  # ---------------------------------------------------------------------
  # Step 4: rebalance on route cost. Each accepted move strictly lowers the
  # makespan (a bounded non-negative integer), so this terminates on its
  # own; `max_rounds` is only a compute guard.
  #
  # The second guard is WALL CLOCK, and it is not theoretical: measured on
  # the real Domain graph (189 systems, 2026-10-05), k=2 spent 15.3 s here
  # -- every candidate move re-routes two ~95-system parts, and k=2 has the
  # biggest parts and the most boundary. k=3/k=4 took 5.4 s / 3.7 s. A
  # human clicking "split" is waiting on this synchronously, so the loop
  # stops at `:budget_ms` and keeps whatever improvement it has: the result
  # is always a valid partition, just a less polished one.
  # ---------------------------------------------------------------------

  defp rebalance(parts, _distances, 0, _started_at, _budget_ms), do: parts

  defp rebalance(parts, distances, rounds_left, started_at, budget_ms) do
    if budget_ms > 0 and System.monotonic_time(:millisecond) - started_at >= budget_ms do
      parts
    else
      worst = Enum.max_by(parts, & &1.jumps)
      current_makespan = worst.jumps

      case best_move(worst, parts, distances) do
        {moved_parts, new_makespan} when new_makespan < current_makespan ->
          rebalance(moved_parts, distances, rounds_left - 1, started_at, budget_ms)

        _no_improving_move ->
          parts
      end
    end
  end

  defp best_move(worst, parts, distances) do
    if length(worst.system_ids) <= 1 do
      nil
    else
      worst
      |> boundary_candidates(parts, distances)
      |> Enum.map(fn {system_id, target_idx} ->
        simulate_move(parts, worst.index, target_idx, system_id, distances)
      end)
      |> Enum.min_by(fn {_parts, makespan} -> makespan end, fn -> nil end)
    end
  end

  # Systems in the worst part that sit exactly one jump from a system in
  # some OTHER part -- real gate-adjacent boundary systems, paired with
  # every part they border.
  defp boundary_candidates(worst, parts, distances) do
    other_ids_by_part =
      parts
      |> Enum.reject(&(&1.index == worst.index))
      |> Map.new(&{&1.index, &1.system_ids})

    worst.system_ids
    |> Enum.flat_map(fn sid ->
      other_ids_by_part
      |> Enum.filter(fn {_idx, ids} -> Enum.any?(ids, &(dist(distances, sid, &1) == 1)) end)
      |> Enum.map(fn {idx, _ids} -> {sid, idx} end)
    end)
    |> Enum.uniq()
  end

  defp simulate_move(parts, from_idx, to_idx, system_id, distances) do
    updated =
      Enum.map(parts, fn
        %{index: ^from_idx} = p ->
          route_for(from_idx, List.delete(p.system_ids, system_id), distances)

        %{index: ^to_idx} = p ->
          route_for(to_idx, [system_id | p.system_ids], distances)

        p ->
          p
      end)

    {updated, updated |> Enum.map(& &1.jumps) |> Enum.max()}
  end

  # ---------------------------------------------------------------------
  # Distance lookup -- missing entries (no path in the matrix) treated as a
  # very large but finite cost rather than crashing a `min_by`/`max_by`.
  # ---------------------------------------------------------------------

  defp dist(_distances, a, a), do: 0

  defp dist(distances, a, b) do
    distances |> Map.get(a, %{}) |> Map.get(b, @unreachable)
  end

  defp ceil_div(n, k), do: div(n + k - 1, k)
end
