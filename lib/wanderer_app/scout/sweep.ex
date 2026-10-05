defmodule WandererApp.Scout.Sweep do
  @moduledoc """
  CHEWY PATCH: "visit all 189 of these, cheaply, and tell me how to divide
  them" -- a different objective from `WandererApp.Scout.Planner`'s
  "what are the 10 most urgent systems near me". See
  `docs/design/wanderer-scout-region-sweeps.md` sections 1, 3, 4, 6, 7.

  Rides the SAME `WANDERER_SCOUT_PLANNER` flag `Planner` does, and is NOT
  gated in this module for the same reason `Planner` is not: a flag check
  here would be a second place to forget to update. Callers (the
  LiveView, the controller) own the gate.

  ## The graph is always the FULL k-space graph

  `Planner.graph/0` -- the same 24h-cached adjacency `rank/1`/`plan/1`
  build their BFS over -- never an induced per-region subgraph. Section 3
  of the design doc is explicit about why: Sinq Laison has two systems
  reachable only by leaving the region, so restricting the graph to the
  scope would silently strand them.

  ## Scope cap

  Nothing in this module (or any caller) may run `sweep/1` over more than
  `@max_regions` regions or `@max_scope_systems` candidate systems --
  past that the all-pairs matrix and the O(n^2) 2-opt passes stop being
  "milliseconds" and the contract (top of this file's design doc) asks
  the cap be enforced and stated where it lives. It lives here, in
  `fetch_scope/1` (region count) and `candidate_metadata/1` (system
  count, post-filter) -- both return `{:error, :scope_too_large}`.
  """

  require Ash.Query
  require Logger
  import Ecto.Query

  alias WandererApp.Api.{MapSolarSystem, ScoutSystemCoverage}
  alias WandererApp.Repo
  alias WandererApp.Scout.Planner
  alias WandererApp.SystemClass

  @type scope :: {:regions, [integer()]} | {:systems, [integer()]}

  @type sweep_stop :: %{
          solar_system_id: integer(),
          name: String.t(),
          region_name: String.t() | nil,
          constellation_name: String.t() | nil,
          system_class: integer() | nil,
          security: float() | nil,
          space: Planner.space(),
          order: pos_integer(),
          waypoint?: boolean(),
          jumps_from_prev: non_neg_integer(),
          coverage: %{
            visit: DateTime.t() | nil,
            anoms: DateTime.t() | nil,
            sigs: DateTime.t() | nil,
            grid: DateTime.t() | nil
          },
          age_s: integer(),
          reason: :unseen | :stale | :fresh
        }

  @type sweep_result :: %{
          generated_at: DateTime.t(),
          scope: scope(),
          kind: Planner.kind(),
          start: integer(),
          systems: non_neg_integer(),
          jumps: non_neg_integer(),
          stops: [sweep_stop()],
          waypoints: [integer()],
          compressed?: boolean(),
          starts: [%{solar_system_id: integer(), name: String.t(), jumps: non_neg_integer()}]
        }

  @type sweep_opts :: [
          scope: scope(),
          kind: Planner.kind(),
          security: [Planner.security_key()],
          avoid: [integer()],
          exclude: [integer()],
          include_fresh: boolean(),
          start: integer() | nil,
          compress: boolean()
        ]

  @type region_heat_row :: %{
          region_id: integer(),
          region_name: String.t(),
          systems: non_neg_integer(),
          covered: non_neg_integer(),
          stale: non_neg_integer(),
          unseen: non_neg_integer(),
          median_age_s: integer() | nil
        }

  @kinds [:visit, :anoms, :sigs, :grid]

  # Design doc top-of-file contract: "nothing may call sweep/1 with a
  # scope larger than 3 regions (~450 systems) without the caller capping
  # it". Enforced here, not left to callers.
  @max_regions 3
  @max_scope_systems 600

  # 2-opt (section 1: "costs ~3ms on a 189-node matrix... converges fast").
  # 12 rounds is the Lloyd-iteration cap `Split` uses for the same reason
  # (design section 5); borrowed here since 2-opt on a near-tree graph
  # converges even faster than that in every region measured.
  @two_opt_max_rounds 25

  # Design section 4's own number ("~45 greedy walks for Domain") --
  # bounds `border_candidates/2`'s no-real-dead-end fallback to the same
  # order of magnitude regardless of scope size.
  @fallback_start_candidates 50

  # Sentinel used ONLY for ranking decisions (greedy choice, 2-opt delta)
  # so an unreachable pair is never preferred over a real short edge.
  # Never summed into a reported `jumps` total -- see `path_cost/2`.
  @unreachable 1_000_000

  @wh_classes SystemClass.wormhole_classes()
  @map_solar_system_table "map_solar_system_v2"
  @coverage_table "scout_system_coverage_v1"

  # ---------------------------------------------------------------------
  # sweep/1
  # ---------------------------------------------------------------------

  @doc """
  Candidate set = every system in `scope`'s region(s) (or the explicit
  system id list), in an enabled security band, minus `avoid`, minus
  `exclude` (assigned to someone else), minus -- unless `include_fresh`
  -- anything still fresh for `kind` per `Planner.ttl_seconds/2`. Then:
  all-pairs `distances/1` -> best `route/3` (+ top-3 alternates) ->
  `compress/1` unless `compress: false`.
  """
  @spec sweep(sweep_opts()) :: {:ok, sweep_result()} | {:error, atom()}
  def sweep(opts) do
    with {:ok, resolved} <- resolve_sweep_opts(opts),
         {:ok, metadata_by_id} <- candidate_metadata(resolved) do
      case Map.keys(metadata_by_id) do
        [] ->
          {:error, :no_candidates}

        candidate_ids ->
          build_sweep_result(resolved, candidate_ids, metadata_by_id)
      end
    end
  end

  defp build_sweep_result(resolved, candidate_ids, metadata_by_id) do
    graph = Planner.graph()
    dist_matrix = distances(candidate_ids)
    id_set = MapSet.new(candidate_ids)

    evaluated =
      id_set
      |> border_candidates(graph)
      |> Enum.map(fn sid -> {sid, route(candidate_ids, sid, dist_matrix)} end)

    main_route = pick_main_route(resolved.start, id_set, candidate_ids, dist_matrix, evaluated)

    starts =
      evaluated
      |> Enum.sort_by(fn {_sid, r} -> r.jumps end)
      |> Enum.take(3)
      |> Enum.map(fn {sid, r} ->
        %{solar_system_id: sid, name: name_of(metadata_by_id, sid), jumps: r.jumps}
      end)

    waypoint_ids =
      if resolved.compress, do: compress(main_route.order), else: main_route.order

    stops = build_stops(main_route.order, metadata_by_id, dist_matrix, MapSet.new(waypoint_ids))

    {:ok,
     %{
       generated_at: DateTime.utc_now(),
       scope: resolved.scope,
       kind: resolved.kind,
       start: main_route.start,
       systems: length(main_route.order),
       jumps: main_route.jumps,
       stops: stops,
       waypoints: waypoint_ids,
       compressed?: resolved.compress and waypoint_ids != main_route.order,
       starts: starts
     }}
  end

  defp pick_main_route(start, id_set, candidate_ids, dist_matrix, evaluated) do
    if is_integer(start) and MapSet.member?(id_set, start) do
      route(candidate_ids, start, dist_matrix)
    else
      evaluated |> Enum.min_by(fn {_sid, r} -> r.jumps end) |> elem(1)
    end
  end

  defp name_of(metadata_by_id, sid) do
    case Map.get(metadata_by_id, sid) do
      nil -> to_string(sid)
      meta -> meta.name
    end
  end

  defp build_stops(order, metadata_by_id, dist_matrix, waypoint_set) do
    order
    |> Enum.with_index(1)
    |> Enum.map_reduce(nil, fn {sid, idx}, prev ->
      meta = Map.fetch!(metadata_by_id, sid)

      jumps_from_prev =
        case prev do
          nil -> 0
          prev_id -> dist_matrix |> Map.get(prev_id, %{}) |> Map.get(sid, 0)
        end

      stop = %{
        solar_system_id: sid,
        name: meta.name,
        region_name: meta.region_name,
        constellation_name: meta.constellation_name,
        system_class: meta.system_class,
        security: meta.security,
        space: meta.space,
        order: idx,
        waypoint?: MapSet.member?(waypoint_set, sid),
        jumps_from_prev: jumps_from_prev,
        coverage: meta.coverage,
        age_s: meta.age_s,
        reason: meta.reason
      }

      {stop, sid}
    end)
    |> elem(0)
  end

  # ---------------------------------------------------------------------
  # Option resolution -- strict, unlike `Planner.resolve_opts/2`: this
  # module has exactly one caller contract (the one in this file's
  # moduledoc), not a lenient-LiveView / strict-HTTP split.
  # ---------------------------------------------------------------------

  defp resolve_sweep_opts(opts) do
    opts = Map.new(opts)

    with {:ok, scope} <- fetch_scope(opts),
         {:ok, kind} <- fetch_kind(opts) do
      {:ok,
       %{
         scope: scope,
         kind: kind,
         security: opts |> Map.get(:security, Planner.default_security()) |> Planner.normalize_security(),
         avoid: opts |> Map.get(:avoid, []) |> List.wrap() |> Enum.filter(&is_integer/1) |> MapSet.new(),
         exclude:
           opts |> Map.get(:exclude, []) |> List.wrap() |> Enum.filter(&is_integer/1) |> MapSet.new(),
         include_fresh: Map.get(opts, :include_fresh, false) == true,
         start: fetch_start(opts),
         compress: Map.get(opts, :compress, true) != false
       }}
    end
  end

  defp fetch_scope(%{scope: {:regions, ids}}) do
    ids = ids |> List.wrap() |> Enum.filter(&is_integer/1) |> Enum.uniq()

    cond do
      ids == [] -> {:error, :empty_scope}
      length(ids) > @max_regions -> {:error, :scope_too_large}
      true -> {:ok, {:regions, ids}}
    end
  end

  defp fetch_scope(%{scope: {:systems, ids}}) do
    ids = ids |> List.wrap() |> Enum.filter(&is_integer/1) |> Enum.uniq()
    if ids == [], do: {:error, :empty_scope}, else: {:ok, {:systems, ids}}
  end

  defp fetch_scope(_opts), do: {:error, :empty_scope}

  defp fetch_kind(opts) do
    case Map.get(opts, :kind, :sigs) do
      kind when kind in @kinds -> {:ok, kind}
      _other -> {:error, :invalid_kind}
    end
  end

  defp fetch_start(%{start: start}) when is_integer(start), do: start
  defp fetch_start(_opts), do: nil

  # ---------------------------------------------------------------------
  # Candidate resolution -- region/system membership, security band,
  # avoid/exclude, freshness. Mirrors the shape of `Planner.
  # build_candidate_pool/1` but the objective is membership, not a BFS
  # ball, so it is a fresh read rather than a shared helper (design
  # section 3: "a candidate set is a MEMBERSHIP, not a ball").
  # ---------------------------------------------------------------------

  defp candidate_metadata(resolved) do
    case load_scope_systems(resolved.scope) do
      {:ok, raw} ->
        in_scope =
          raw
          |> Enum.reject(fn sys ->
            MapSet.member?(resolved.avoid, sys.solar_system_id) or
              MapSet.member?(resolved.exclude, sys.solar_system_id)
          end)
          |> Enum.filter(&security_in_scope?(&1, resolved.security))

        ids = Enum.map(in_scope, & &1.solar_system_id)
        coverage_by_id = load_coverage(ids)
        now = DateTime.utc_now()

        metadata =
          in_scope
          |> Enum.map(&build_candidate(&1, coverage_by_id, resolved, now))
          |> Enum.reject(fn {_id, meta} -> not resolved.include_fresh and meta.reason == :fresh end)
          |> Map.new()

        if map_size(metadata) > @max_scope_systems do
          {:error, :scope_too_large}
        else
          {:ok, metadata}
        end

      {:error, _reason} ->
        {:error, :no_candidates}
    end
  end

  defp load_scope_systems({:regions, region_ids}) do
    MapSolarSystem
    |> Ash.Query.filter(region_id in ^region_ids)
    |> Ash.read(authorize?: false)
  end

  defp load_scope_systems({:systems, ids}) do
    MapSolarSystem
    |> Ash.Query.filter(solar_system_id in ^ids)
    |> Ash.read(authorize?: false)
  end

  defp security_in_scope?(sys, security) do
    space = Planner.classify_space(sys.system_class, Planner.parse_security(sys.security))
    space in security
  end

  defp build_candidate(sys, coverage_by_id, resolved, now) do
    security_float = Planner.parse_security(sys.security)
    space = Planner.classify_space(sys.system_class, security_float)
    kind_coverage = Map.get(coverage_by_id, sys.solar_system_id, %{})

    coverage = %{
      visit: Map.get(kind_coverage, :visit),
      anoms: Map.get(kind_coverage, :anoms),
      sigs: Map.get(kind_coverage, :sigs),
      grid: Map.get(kind_coverage, :grid)
    }

    observed = Map.get(kind_coverage, resolved.kind)
    age_s = if observed, do: DateTime.diff(now, observed, :second), else: -1
    reason = reason_for(observed, age_s, Planner.ttl_seconds(resolved.kind, sys.system_class))

    {sys.solar_system_id,
     %{
       solar_system_id: sys.solar_system_id,
       name: sys.solar_system_name,
       region_name: sys.region_name,
       constellation_name: sys.constellation_name,
       system_class: sys.system_class,
       security: security_float,
       space: space,
       coverage: coverage,
       age_s: age_s,
       reason: reason
     }}
  end

  defp reason_for(nil, _age_s, _ttl), do: :unseen
  defp reason_for(_observed, age_s, ttl), do: if(age_s >= ttl, do: :stale, else: :fresh)

  defp load_coverage([]), do: %{}

  defp load_coverage(ids) do
    case ScoutSystemCoverage
         |> Ash.Query.filter(solar_system_id in ^ids)
         |> Ash.read(authorize?: false) do
      {:ok, rows} ->
        rows
        |> Enum.group_by(& &1.solar_system_id)
        |> Map.new(fn {id, kind_rows} -> {id, Map.new(kind_rows, &{&1.kind, &1.observed_at})} end)

      {:error, _reason} ->
        %{}
    end
  end

  # ---------------------------------------------------------------------
  # distances/1 -- one BFS per source over the FULL cached k-space graph
  # (`Planner.graph/0`), restricted to the given ids as sources/targets.
  # Design section 3: "189 BFS x ~7k edges, measured in milliseconds".
  # ---------------------------------------------------------------------

  @spec distances([integer()]) :: %{integer() => %{integer() => non_neg_integer()}}
  def distances(ids) do
    graph = Planner.graph()
    target_set = MapSet.new(ids)

    ids
    |> Enum.map(fn source -> {source, bfs_row(graph, source, target_set)} end)
    |> Map.new()
  end

  # Full BFS from `source` over the whole graph, keeping only entries for
  # `target_set` members (other than `source` itself) -- entries for
  # genuinely unreachable targets are simply absent, not `nil`, so
  # `route/3`'s ranking sentinel is the only place "unreachable" shows up
  # as a value.
  defp bfs_row(graph, source, target_set) do
    do_bfs_row(graph, :queue.from_list([{source, 0}]), MapSet.new([source]), %{})
    |> Map.take(MapSet.to_list(MapSet.delete(target_set, source)))
  end

  defp do_bfs_row(graph, queue, visited, distances) do
    case :queue.out(queue) do
      {{:value, {node, depth}}, queue} ->
        neighbors = Map.get(graph, node, MapSet.new())

        {queue, visited, distances} =
          Enum.reduce(neighbors, {queue, visited, distances}, fn n, {q, v, d} ->
            if MapSet.member?(v, n) do
              {q, v, d}
            else
              {:queue.in({n, depth + 1}, q), MapSet.put(v, n), Map.put(d, n, depth + 1)}
            end
          end)

        do_bfs_row(graph, queue, visited, distances)

      {:empty, _queue} ->
        distances
    end
  end

  # ---------------------------------------------------------------------
  # route/3 -- greedy nearest-unvisited + 2-opt. `nil` start evaluates
  # every dead-end/border candidate (design section 4) and keeps the
  # cheapest; an explicit start outside `ids` falls back the same way.
  # ---------------------------------------------------------------------

  @spec route([integer()] | MapSet.t(integer()), integer() | nil, %{
          integer() => %{integer() => non_neg_integer()}
        }) :: %{order: [integer()], jumps: non_neg_integer(), start: integer() | nil}
  def route(ids, start, dist_matrix) do
    id_set = normalize_ids(ids)

    case MapSet.size(id_set) do
      0 ->
        %{order: [], jumps: 0, start: nil}

      1 ->
        only = id_set |> MapSet.to_list() |> hd()
        %{order: [only], jumps: 0, start: only}

      _ ->
        best_route(id_set, start, dist_matrix)
    end
  end

  defp normalize_ids(%MapSet{} = ms), do: ms
  defp normalize_ids(list) when is_list(list), do: MapSet.new(list)

  defp best_route(id_set, start, dist_matrix) when is_integer(start) do
    if MapSet.member?(id_set, start) do
      build_route(id_set, start, dist_matrix)
    else
      best_route(id_set, nil, dist_matrix)
    end
  end

  defp best_route(id_set, nil, dist_matrix) do
    graph = Planner.graph()

    id_set
    |> border_candidates(graph)
    |> Enum.map(&build_route(id_set, &1, dist_matrix))
    |> Enum.min_by(& &1.jumps)
  end

  # Dead ends (<= 1 neighbour inside scope) plus border systems (>= 1
  # neighbour outside scope) -- design section 4's "~45 greedy walks for
  # Domain". A real k-space scope is a near-tree (design section 1) so
  # this is virtually never empty; the fallback below only matters for
  # a fully-enclosed, maximally-connected scope (no real dead end or
  # border exists), and is capped at `@fallback_start_candidates` --
  # evaluating every one of up to 600 scope systems with a full
  # greedy+2opt pass each would turn "milliseconds" into seconds for no
  # benefit over a bounded, lowest-degree-first sample.
  defp border_candidates(id_set, graph) do
    case Enum.filter(id_set, &border_or_dead_end?(&1, id_set, graph)) do
      [] -> lowest_degree_candidates(id_set, graph)
      candidates -> candidates
    end
  end

  defp lowest_degree_candidates(id_set, graph) do
    id_set
    |> Enum.map(fn id -> {id, in_scope_degree(id, id_set, graph)} end)
    |> Enum.sort_by(fn {_id, degree} -> degree end)
    |> Enum.take(@fallback_start_candidates)
    |> Enum.map(fn {id, _degree} -> id end)
  end

  defp in_scope_degree(id, id_set, graph) do
    graph |> Map.get(id, MapSet.new()) |> MapSet.intersection(id_set) |> MapSet.size()
  end

  defp border_or_dead_end?(id, id_set, graph) do
    neighbors = Map.get(graph, id, MapSet.new())
    in_scope_degree = neighbors |> MapSet.intersection(id_set) |> MapSet.size()
    has_outside_neighbor = neighbors |> MapSet.difference(id_set) |> MapSet.size() > 0
    in_scope_degree <= 1 or has_outside_neighbor
  end

  defp build_route(id_set, start, dist_matrix) do
    order = greedy_order(id_set, start, dist_matrix)
    final_order = two_opt(order, dist_matrix)
    %{order: final_order, jumps: path_cost(final_order, dist_matrix), start: start}
  end

  defp greedy_order(id_set, start, dist_matrix) do
    remaining = MapSet.delete(id_set, start)
    do_greedy(remaining, start, dist_matrix, [start])
  end

  defp do_greedy(remaining, current, dist_matrix, acc) do
    if MapSet.size(remaining) == 0 do
      Enum.reverse(acc)
    else
      row = Map.get(dist_matrix, current, %{})
      next = pick_next(remaining, row)
      do_greedy(MapSet.delete(remaining, next), next, dist_matrix, [next | acc])
    end
  end

  defp pick_next(remaining, row) do
    reachable = Enum.filter(remaining, &Map.has_key?(row, &1))

    case reachable do
      [] -> Enum.min(remaining)
      _ -> Enum.min_by(reachable, &Map.fetch!(row, &1))
    end
  end

  # Open-path 2-opt on the shortest-path metric: for i < j (with a j+1
  # tail), reverse [i+1..j] when d(a,c)+d(b,d) < d(a,b)+d(c,d). Repeats
  # until a full pass finds no improving move, capped at
  # `@two_opt_max_rounds`. Design section 1: "worth 8-13% and costs ~3ms".
  defp two_opt(order, _dist_matrix) when length(order) < 4, do: order

  defp two_opt(order, dist_matrix) do
    Enum.reduce_while(1..@two_opt_max_rounds, order, fn _round, current ->
      case best_two_opt_move(current, dist_matrix) do
        :none -> {:halt, current}
        {:improved, next} -> {:cont, next}
      end
    end)
  end

  defp best_two_opt_move(order, dist_matrix) do
    arr = List.to_tuple(order)
    n = tuple_size(arr)

    best =
      for i <- 0..(n - 3), j <- (i + 2)..(n - 2)//1, reduce: nil do
        acc ->
          a = elem(arr, i)
          b = elem(arr, i + 1)
          c = elem(arr, j)
          d = elem(arr, j + 1)

          delta =
            edge_cost(dist_matrix, a, c) + edge_cost(dist_matrix, b, d) -
              (edge_cost(dist_matrix, a, b) + edge_cost(dist_matrix, c, d))

          cond do
            delta >= 0 -> acc
            is_nil(acc) -> {delta, i, j}
            delta < elem(acc, 0) -> {delta, i, j}
            true -> acc
          end
      end

    case best do
      nil -> :none
      {_delta, i, j} -> {:improved, reverse_segment(order, i + 1, j)}
    end
  end

  defp reverse_segment(order, i, j) do
    {head, rest} = Enum.split(order, i)
    {middle, tail} = Enum.split(rest, j - i + 1)
    head ++ Enum.reverse(middle) ++ tail
  end

  defp edge_cost(dist_matrix, a, b), do: dist_matrix |> Map.get(a, %{}) |> Map.get(b, @unreachable)

  # Reported route cost: real known legs only. A genuinely unreachable
  # pair (sentinel-scored during ranking so it is never preferred) does
  # NOT inflate the headline `jumps` figure -- the stop is still in
  # `order` (coverage completeness), it just does not pretend to have a
  # jump count that was never computed.
  defp path_cost(order, dist_matrix) do
    order
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0, fn [a, b], acc -> acc + (dist_matrix |> Map.get(a, %{}) |> Map.get(b, 0)) end)
  end

  # ---------------------------------------------------------------------
  # compress/1 -- the strict forced-stop rule (design section 6): drop a
  # stop only when EVERY shortest path between the surrounding kept
  # waypoints passes through it, i.e. deleting it from the FULL graph
  # lengthens (or breaks) the distance between the anchors either side of
  # it. Asserts coverage by re-walking the result; falls back to the
  # uncompressed list (logged) rather than ship a route with holes.
  # ---------------------------------------------------------------------

  @spec compress([integer()]) :: [integer()]
  def compress(waypoints) when length(waypoints) <= 2, do: waypoints

  def compress(waypoints) do
    graph = Planner.graph()
    compressed = drop_forced(waypoints, graph)

    if fully_covered?(waypoints, compressed, graph) do
      compressed
    else
      Logger.warning(
        "[Sweep.compress/1] coverage check failed for #{length(waypoints)} stops " <>
          "(compressed to #{length(compressed)}); returning the uncompressed list"
      )

      waypoints
    end
  end

  defp drop_forced([first | rest], graph) do
    last = List.last(rest)
    middle = rest |> Enum.reverse() |> tl() |> Enum.reverse()
    kept_middle = scan_forced(middle, first, last, graph, [])
    [first] ++ Enum.reverse(kept_middle) ++ [last]
  end

  defp scan_forced([], _left, _last, _graph, acc), do: acc

  defp scan_forced([candidate | more], left, last, graph, acc) do
    right = List.first(more) || last

    if forced_stop?(graph, left, candidate, right) do
      scan_forced(more, left, last, graph, acc)
    else
      scan_forced(more, candidate, last, graph, [candidate | acc])
    end
  end

  defp forced_stop?(graph, left, candidate, right) do
    before = bfs_distance(graph, left, right)
    pruned = delete_node(graph, candidate)
    after_removal = bfs_distance(pruned, left, right)

    case {before, after_removal} do
      {_before, nil} -> true
      {before, after_removal} -> after_removal > before
    end
  end

  defp delete_node(graph, node) do
    case Map.fetch(graph, node) do
      :error ->
        graph

      {:ok, neighbors} ->
        graph
        |> Map.delete(node)
        |> then(fn g ->
          Enum.reduce(neighbors, g, fn n, acc ->
            Map.update(acc, n, MapSet.new(), &MapSet.delete(&1, node))
          end)
        end)
    end
  end

  defp bfs_distance(_graph, a, a), do: 0

  defp bfs_distance(graph, a, b) do
    do_bfs_distance(graph, :queue.from_list([{a, 0}]), MapSet.new([a]), b)
  end

  defp do_bfs_distance(graph, queue, visited, target) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        nil

      {{:value, {node, depth}}, queue} ->
        if node == target do
          depth
        else
          neighbors = Map.get(graph, node, MapSet.new())

          {queue, visited} =
            Enum.reduce(neighbors, {queue, visited}, fn n, {q, v} ->
              if MapSet.member?(v, n),
                do: {q, v},
                else: {:queue.in({n, depth + 1}, q), MapSet.put(v, n)}
            end)

          do_bfs_distance(graph, queue, visited, target)
        end
    end
  end

  defp fully_covered?(waypoints, compressed, graph) do
    visited =
      compressed
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(MapSet.new(compressed), fn [a, b], acc ->
        case shortest_path(graph, a, b) do
          nil -> acc
          path -> MapSet.union(acc, MapSet.new(path))
        end
      end)

    Enum.all?(waypoints, &MapSet.member?(visited, &1))
  end

  defp shortest_path(_graph, a, a), do: [a]

  defp shortest_path(graph, a, b) do
    do_shortest_path(graph, :queue.from_list([a]), MapSet.new([a]), %{}, b)
  end

  defp do_shortest_path(graph, queue, visited, parents, target) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        nil

      {{:value, node}, queue} ->
        if node == target do
          reconstruct_path(parents, target, [target])
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

          do_shortest_path(graph, queue, visited, parents, target)
        end
    end
  end

  defp reconstruct_path(parents, node, acc) do
    case Map.fetch(parents, node) do
      {:ok, parent} -> reconstruct_path(parents, parent, [parent | acc])
      :error -> acc
    end
  end

  # ---------------------------------------------------------------------
  # region_heat/1 -- Ash has no general GROUP BY (see `WandererApp.Scout.
  # Stats`'s moduledoc); one schemaless Ecto query, same idiom, joining
  # `map_solar_system_v2` to `scout_system_coverage_v1` for `kind`.
  #
  # "systems" is a k-space count -- wormhole-class systems are excluded
  # (design doc section 1's "5069 k-space systems" is this same filter),
  # which is also why a single TTL (`Planner.ttl_seconds(kind, nil)`,
  # i.e. never wormhole-halved) is correct for every row in one pass.
  # ---------------------------------------------------------------------

  @spec region_heat(Planner.kind()) :: [region_heat_row()]
  def region_heat(kind) when kind in @kinds do
    ttl = Planner.ttl_seconds(kind, nil)
    now = NaiveDateTime.utc_now()
    cutoff = NaiveDateTime.add(now, -trunc(ttl), :second)
    kind_str = Atom.to_string(kind)

    from(ms in @map_solar_system_table,
      where: (ms.system_class not in ^@wh_classes or is_nil(ms.system_class)) and not is_nil(ms.region_id),
      left_join: cov in ^@coverage_table,
      on: cov.solar_system_id == ms.solar_system_id and cov.kind == ^kind_str,
      group_by: [ms.region_id, ms.region_name],
      order_by: [asc: ms.region_name],
      select: %{
        region_id: ms.region_id,
        region_name: ms.region_name,
        systems: count(ms.solar_system_id),
        covered: filter(count(cov.id), cov.observed_at >= ^cutoff),
        stale: filter(count(cov.id), cov.observed_at < ^cutoff),
        unseen: filter(count(ms.solar_system_id), is_nil(cov.id)),
        median_age_s:
          filter(
            fragment(
              "percentile_cont(0.5) within group (order by extract(epoch from (? - ?)))",
              ^now,
              cov.observed_at
            ),
            not is_nil(cov.observed_at)
          )
      }
    )
    |> Repo.all()
    |> Enum.map(&finalize_region_heat_row/1)
  end

  defp finalize_region_heat_row(row), do: %{row | median_age_s: round_or_nil(row.median_age_s)}

  defp round_or_nil(nil), do: nil
  defp round_or_nil(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp round_or_nil(value) when is_float(value), do: round(value)
  defp round_or_nil(value) when is_integer(value), do: value
end
