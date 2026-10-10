defmodule WandererApp.Scout.Planner do
  @moduledoc """
  CHEWY PATCH: turns `scout_system_coverage_v1` rows -- accumulating
  since phase 1 and read by nothing -- into a ranked "needs scouting"
  list (`rank/1`) and a nearest-neighbour route over it (`plan/1`). See
  `docs/design/wanderer-scout-planner.md` sections 5-7.

  Two consumers:

    * `WandererAppWeb.ScoutPlannerLive` (`/scout/planner`) calls
      `rank_plan/1` directly, in-process.
    * `WandererAppWeb.ScoutPlanAPIController` (`GET
      .../scout/plan`) calls `plan/1` and renders `json` / `text` /
      `flat`.

  Both are gated by `WandererApp.Env.scout_planner_enabled?/0`
  (`WANDERER_SCOUT_PLANNER`); this module itself is NOT gated -- a flag
  check here would be a second place to forget to update.

  ## The graph

  BFS over the cached k-space jump index (`WandererApp.Api.
  MapSolarSystemJumps`, ~13k undirected edges). Built ONCE per node and
  cached in `WandererApp.Cache` (the idiom every other long-lived lookup
  table in this app uses -- `WandererApp.Scout.Alerts.count_cached/0`,
  `WandererApp.CachedInfo`) -- never queried per hop. When `opts[:chain]`
  is true and `opts[:map_id]` is set, that map's current connections
  (`MapConnection.get_link_pairs_advanced`, every mass/EOL/frig filter
  OFF so the overlay sees the whole chain) are unioned into a COPY of
  the cached k-space graph for that one call; the cached graph itself is
  never mutated, because the chain is per-map and the gate graph is not.

  A stop's `leg` is `:gate` when it is reachable over the gate-only graph
  within budget, `:advisory` when it is reachable ONLY via a chain edge.
  Gate reachability is checked first and wins even when a chain edge
  would be shorter -- mode A (design section 6) only ever waypoints
  `:gate` legs, so the distance a route planner actually cares about is
  the gate distance, not the shortest graph distance.

  ## The frontier term

  Only computed when `opts[:map_id]` is given (the design's "the only
  reason the map is consulted at all" -- section 5). Two classes, both
  evaluated against the CURRENT state of that map, never cached (unlike
  the gate graph, connections and signatures change on a human
  timescale):

    * a `Wormhole`-group signature on a chain system with no
      `map_connection` hanging off it (an un-jumped hole);
    * a chain connection whose far side has no `sigs` coverage.

  Reads use the purpose-built actions (`MapSystem.read_all_by_map`,
  `MapConnection.read_by_map`, `MapSystemSignature.by_system_ids`) with
  `authorize?: false`, never the actor-less primary `MapConnection`
  read -- `AGENTS.md`'s documented trap: that read is prepared with
  `FilterConnectionsByActorMap` and silently returns zero rows with no
  actor.

  ## Every TTL and weight below is a GUESS

  Nothing in either repo measures respawn cadence or has ever had a
  human tune a ranking weight -- design doc section 5 is explicit that
  this must ship labelled as such, not silently presented as tuned.
  `opts[:weights]` overrides `@default_weights` per call; there is
  currently no equivalent override for the TTL table, because nothing
  has asked for one yet.
  """

  require Ash.Query

  alias WandererApp.Api.{
    MapConnection,
    MapSolarSystem,
    MapSolarSystemJumps,
    MapSystem,
    MapSystemSignature,
    ScoutSystemCoverage
  }

  alias WandererApp.SystemClass

  @type kind :: :visit | :anoms | :sigs | :grid
  @type security_key :: :hs | :ls | :ns | :wh | :pochven
  @type space :: :hs | :ls | :ns | :wh | :pochven | :unknown
  @type reason :: :unseen | :frontier | :stale | :fresh
  @type leg :: :gate | :advisory

  @type opts :: [
          origin: integer(),
          kind: kind(),
          limit: pos_integer(),
          max_jumps: pos_integer() | 0 | :infinity,
          regions: [integer()],
          security: [security_key()],
          avoid: [integer()],
          map_id: String.t() | nil,
          chain: boolean(),
          weights: map()
        ]

  @type stop :: %{
          solar_system_id: integer(),
          name: String.t(),
          region_name: String.t() | nil,
          constellation_name: String.t() | nil,
          system_class: integer() | nil,
          class_title: String.t() | nil,
          security: float() | nil,
          space: space(),
          jumps: non_neg_integer(),
          score: float(),
          reason: reason(),
          age_s: integer(),
          coverage: %{
            visit: DateTime.t() | nil,
            anoms: DateTime.t() | nil,
            sigs: DateTime.t() | nil,
            grid: DateTime.t() | nil
          },
          legs_scanned: integer() | nil,
          sig_count: integer() | nil,
          spawns_found: integer() | nil,
          legs_total: integer() | nil,
          claimed_by: String.t() | nil,
          leg: leg(),
          terms: %{
            need: float(),
            frontier: float(),
            value: float(),
            distance: number(),
            claimed: float()
          }
        }

  @type result :: %{
          generated_at: DateTime.t(),
          origin: integer(),
          kind: kind(),
          weights: map(),
          candidates: non_neg_integer(),
          stops: [stop()]
        }

  # ---------------------------------------------------------------------
  # Tunables -- every value here is a GUESS, see moduledoc.
  # ---------------------------------------------------------------------

  @default_weights %{
    need: 10.0,
    frontier: 8.0,
    value: 3.0,
    distance: 0.5,
    claimed: 4.0
  }

  # `need` for a never-observed system -- and the ceiling `age/ttl`
  # itself is clamped to, so one ancient row cannot out-rank "we have
  # literally never looked here" (design section 5, "unseen beats old").
  @need_max 5.0

  # k-space defaults, seconds. Wormhole space gets a shorter TTL (see
  # `ttl_seconds/2`) because hole lifetimes run in hours, not days.
  @default_ttls %{
    visit: 6 * 3600,
    anoms: 2 * 3600,
    sigs: 4 * 3600,
    grid: 12 * 3600
  }
  @wormhole_ttl_factor 0.5

  # How recent a `:visit` row from someone else counts as "claimed".
  # Advisory only -- see moduledoc and design section 5.
  @claim_window_s 30 * 60

  @pochven_class 25
  @hs_threshold 0.45

  @kinds [:visit, :anoms, :sigs, :grid]
  @security_keys [:hs, :ls, :ns, :wh, :pochven]
  @default_security [:hs, :ls, :ns]

  @default_max_jumps 25

  @default_rank_limit 50
  @default_plan_limit 10

  @adjacency_cache_key "scout:planner:adjacency"
  @adjacency_cache_ttl :timer.hours(24)

  # ---------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------

  @doc """
  The default k-space security bands (`#{inspect(@default_security)}`),
  shared with `WandererApp.Scout.Sweep` so a sweep's unscoped security
  filter matches `rank/1`/`plan/1` rather than restating the list.
  """
  @spec default_security() :: [security_key()]
  def default_security, do: @default_security

  @doc "Every in-scope system, newest-need first. See moduledoc."
  @spec rank(opts()) :: {:ok, result()} | {:error, atom()}
  def rank(opts) do
    with {:ok, resolved} <- resolve_opts(opts, @default_rank_limit),
         {:ok, pool} <- build_candidate_pool(resolved) do
      {:ok, build_result(resolved, pool.candidates, rank_stops(pool, resolved))}
    end
  end

  @doc """
  Repeated nearest-neighbour route from `opts[:origin]`, capped at
  `opts[:limit]` stops and `opts[:max_jumps]` cumulative jumps. See
  moduledoc; not a TSP solve -- design section 6 is explicit that this
  is intentional, because the ranking is re-queried after every leg.

  `max_jumps: 0` (or `:infinity`) removes the jump budget: the walk runs
  until `:limit` stops are taken or nothing scoped is left. EVE caps no
  route, so this is a COST knob, not a rule -- the budget is ALSO the
  radius of the candidate ball (`build_candidate_pool/1`), so unbounded
  means a BFS plus a metadata read over the whole k-space graph (5268
  nodes / 13978 edges, measured 2026-10-10) instead of a neighbourhood.

  Measured from Jita over that real graph, warm adjacency cache, no
  coverage rows (every system `:unseen`, the worst pool):
  `max_jumps: 25` ranked 2756 candidates in ~80 ms and the budget
  truncated the route at 25 stops however many were asked for;
  `max_jumps: 0` ranked 5228 in ~450 ms at `limit: 50` and ~800 ms at
  `limit: 100`, returning the full 50/100 stops. The default stays
  #{@default_max_jumps} for that reason; the operator opts into the rest.
  """
  @spec plan(opts()) :: {:ok, result()} | {:error, atom()}
  def plan(opts) do
    with {:ok, resolved} <- resolve_opts(opts, @default_plan_limit),
         {:ok, pool} <- build_candidate_pool(resolved) do
      {:ok, build_result(resolved, pool.candidates, plan_stops(pool, resolved))}
    end
  end

  @doc """
  `rank/1` and `plan/1` over ONE candidate pool.

  `/scout/planner` needs both at once -- the table is the ranking, the
  copy box and the "Set route" button are the plan -- and calling them
  separately paid for the whole pool twice: a BFS ball, a metadata read,
  a coverage read and a frontier pass each, per control change, with a
  human waiting. The pool is identical for both (same resolved opts), so
  the second build was pure duplicated work.

  Only the limit default differs between the two entry points, and this
  one takes `rank/1`'s; every caller of this function passes an explicit
  `:limit` anyway.
  """
  @spec rank_plan(opts()) :: {:ok, %{rank: result(), plan: result()}} | {:error, atom()}
  def rank_plan(opts) do
    with {:ok, resolved} <- resolve_opts(opts, @default_rank_limit),
         {:ok, pool} <- build_candidate_pool(resolved) do
      {:ok,
       %{
         rank: build_result(resolved, pool.candidates, rank_stops(pool, resolved)),
         plan: build_result(resolved, pool.candidates, plan_stops(pool, resolved))
       }}
    end
  end

  defp rank_stops(pool, resolved) do
    pool.stops
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(resolved.limit)
  end

  defp plan_stops(pool, resolved) do
    # The origin is dropped here and ONLY here. `rank/1` keeps it --
    # "the system you are sitting in has never been swept" is a true
    # and useful row on the queue page. A ROUTE cannot carry it: the
    # client pushes the first stop with `ISXBob.Travel:SetDestination`,
    # and a destination equal to the current system leaves EVE with no
    # route at all, so `${ISXBob.Travel.NextRouteSystemID}` reads NULL,
    # obj_Scout declares the route exhausted and asks for another plan
    # -- the same plan -- every pacing window, without ever moving.
    remaining =
      pool.stops
      |> Enum.reject(&(&1.solar_system_id == resolved.origin))
      |> Map.new(&{&1.solar_system_id, &1})

    do_walk(
      remaining,
      pool.gate_graph,
      pool.combined_graph,
      resolved.origin,
      resolved.max_jumps,
      resolved.limit,
      resolved.weights,
      []
    )
  end

  defp build_result(resolved, candidates, stops) do
    %{
      generated_at: DateTime.utc_now(),
      origin: resolved.origin,
      kind: resolved.kind,
      weights: resolved.weights,
      candidates: candidates,
      stops: stops
    }
  end

  # ---------------------------------------------------------------------
  # Option resolution -- lenient (clamps), NOT the strict-error contract
  # the HTTP endpoint owns. `WandererAppWeb.ScoutPlanAPIController`
  # validates before ever calling here; direct Elixir callers (the
  # LiveView) get sane defaults instead of a crash on a stray value.
  # ---------------------------------------------------------------------

  defp resolve_opts(opts, default_limit) do
    opts = Map.new(opts)

    with {:ok, origin} <- fetch_origin(opts),
         {:ok, kind} <- fetch_kind(opts) do
      {:ok,
       %{
         origin: origin,
         kind: kind,
         limit: opts |> Map.get(:limit, default_limit) |> positive_int(default_limit),
         max_jumps: opts |> Map.get(:max_jumps, @default_max_jumps) |> jump_budget(),
         regions: opts |> Map.get(:regions, []) |> List.wrap() |> Enum.filter(&is_integer/1),
         security: opts |> Map.get(:security, @default_security) |> normalize_security(),
         avoid: opts |> Map.get(:avoid, []) |> List.wrap() |> Enum.filter(&is_integer/1),
         map_id: Map.get(opts, :map_id),
         chain: Map.get(opts, :chain, false) == true,
         weights: Map.merge(@default_weights, opts |> Map.get(:weights, %{}) |> Map.new())
       }}
    end
  end

  defp fetch_origin(%{origin: origin}) when is_integer(origin) and origin > 0, do: {:ok, origin}
  defp fetch_origin(_opts), do: {:error, :invalid_origin}

  defp fetch_kind(opts) do
    case Map.get(opts, :kind, :sigs) do
      kind when kind in @kinds -> {:ok, kind}
      kind when is_binary(kind) -> normalize_kind_string(kind)
      _other -> {:error, :invalid_kind}
    end
  end

  defp normalize_kind_string(kind) do
    normalized = String.downcase(kind)

    if normalized in ~w(visit anoms sigs grid) do
      {:ok, String.to_existing_atom(normalized)}
    else
      {:error, :invalid_kind}
    end
  end

  @doc """
  Normalizes a security-bucket list (atoms or strings) to valid
  `security_key()`s, dropping anything unrecognised. Public, shared with
  `Sweep`'s `security:` option.
  """
  @spec normalize_security([term()] | term()) :: [security_key()]
  def normalize_security(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_security_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_security_key(key) when key in @security_keys, do: key

  defp normalize_security_key(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.to_existing_atom()
    if normalized in @security_keys, do: normalized, else: nil
  rescue
    ArgumentError -> nil
  end

  defp normalize_security_key(_key), do: nil

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  # The jump budget doubles as the BFS depth cap, so "no limit" has to be
  # a value `depth < max_depth` and `budget <= 0` both answer correctly.
  # `:infinity` is it: in Erlang's term order every integer sorts BEFORE
  # every atom, so an integer depth is always `<` it and it is never
  # `<= 0`. `0` is the WIRE spelling of the same thing (a number input
  # and a localStorage int cannot carry an atom); anything else
  # unparseable falls back to the default rather than silently running
  # unbounded.
  defp jump_budget(:infinity), do: :infinity
  defp jump_budget(0), do: :infinity
  defp jump_budget(value) when is_integer(value) and value > 0, do: value
  defp jump_budget(_value), do: @default_max_jumps

  # ---------------------------------------------------------------------
  # Candidate pool -- shared by rank/1 and plan/1. Scored against
  # `resolved.origin`; plan/1's walk recomputes `jumps`/`leg`/`score`
  # per leg from the CURRENT position (see `finalize_stop/4`).
  # ---------------------------------------------------------------------

  defp build_candidate_pool(resolved) do
    gate_graph = graph()

    combined_graph =
      if resolved.chain and resolved.map_id, do: combined_graph(gate_graph, resolved.map_id)

    gate_d = bfs(gate_graph, resolved.origin, resolved.max_jumps)

    combined_d =
      if combined_graph, do: bfs(combined_graph, resolved.origin, resolved.max_jumps), else: %{}

    avoid_set = MapSet.new(resolved.avoid)

    raw_ids =
      (Map.keys(gate_d) ++ Map.keys(combined_d))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(avoid_set, &1))

    metadata = load_metadata(raw_ids)

    filtered_ids = Enum.filter(raw_ids, &in_scope?(Map.get(metadata, &1), resolved))

    coverage = load_coverage(filtered_ids)
    frontier_set = frontier_systems(resolved.map_id)
    now = DateTime.utc_now()

    stops =
      Enum.map(filtered_ids, fn id ->
        {jumps, leg} = classify_jumps(id, gate_d, combined_d)

        build_stop(
          id,
          jumps,
          leg,
          Map.fetch!(metadata, id),
          Map.get(coverage, id, %{}),
          frontier_set,
          resolved,
          now
        )
      end)

    {:ok,
     %{
       stops: stops,
       candidates: length(stops),
       gate_graph: gate_graph,
       combined_graph: combined_graph
     }}
  end

  defp in_scope?(nil, _resolved), do: false

  defp in_scope?(sys, resolved) do
    space = classify_space(sys.system_class, parse_security(sys.security))
    space_ok = space in resolved.security
    region_ok = resolved.regions == [] or sys.region_id in resolved.regions
    space_ok and region_ok
  end

  defp classify_jumps(id, gate_d, combined_d) do
    case Map.fetch(gate_d, id) do
      {:ok, jumps} ->
        {jumps, :gate}

      :error ->
        case Map.fetch(combined_d, id) do
          {:ok, jumps} -> {jumps, :advisory}
          :error -> nil
        end
    end
  end

  defp build_stop(id, jumps, leg, sys, kind_coverage, frontier_set, resolved, now) do
    security_float = parse_security(sys.security)
    space = classify_space(sys.system_class, security_float)

    coverage = %{
      visit: observed_at(kind_coverage, :visit),
      anoms: observed_at(kind_coverage, :anoms),
      sigs: observed_at(kind_coverage, :sigs),
      grid: observed_at(kind_coverage, :grid)
    }

    kind_row = Map.get(kind_coverage, resolved.kind)
    observed = kind_row && kind_row.observed_at
    age_s = if observed, do: DateTime.diff(now, observed, :second), else: -1

    need =
      if is_nil(observed) do
        @need_max
      else
        min(age_s / ttl_seconds(resolved.kind, sys.system_class), @need_max)
      end

    frontier = if MapSet.member?(frontier_set, id), do: 1.0, else: 0.0
    value = value_score(space)
    {claimed, claimed_by} = claim(Map.get(kind_coverage, :visit), now)

    terms = %{need: need, frontier: frontier, value: value, distance: jumps, claimed: claimed}

    %{
      solar_system_id: id,
      name: sys.solar_system_name,
      region_name: sys.region_name,
      constellation_name: sys.constellation_name,
      system_class: sys.system_class,
      class_title: sys.class_title,
      security: security_float,
      space: space,
      jumps: jumps,
      score: compute_score(terms, resolved.weights),
      reason: reason_for(frontier, observed, need),
      age_s: age_s,
      coverage: coverage,
      legs_scanned: kind_row && kind_row.legs_scanned,
      sig_count: kind_row && kind_row.sig_count,
      spawns_found: kind_row && kind_row.spawns_found,
      legs_total: kind_row && kind_row.legs_total,
      claimed_by: claimed_by,
      leg: leg,
      terms: terms
    }
  end

  defp compute_score(terms, weights) do
    terms.need * weights.need +
      terms.frontier * weights.frontier +
      terms.value * weights.value -
      terms.distance * weights.distance -
      terms.claimed * weights.claimed
  end

  defp reason_for(frontier, observed, need) do
    cond do
      frontier > 0.0 -> :frontier
      is_nil(observed) -> :unseen
      need >= 1.0 -> :stale
      true -> :fresh
    end
  end

  defp claim(nil, _now), do: {0.0, nil}

  defp claim(%{observed_at: observed_at, character_eve_id: char}, now) do
    if DateTime.diff(now, observed_at, :second) <= @claim_window_s do
      {1.0, char}
    else
      {0.0, nil}
    end
  end

  defp observed_at(kind_map, kind) do
    case Map.get(kind_map, kind) do
      nil -> nil
      row -> row.observed_at
    end
  end

  # ---------------------------------------------------------------------
  # Classification -- `security` is a STRING column; parse once.
  # `wh`/`pochven` come from `system_class` (authoritative, see
  # `WandererApp.Scout.Space`'s moduledoc for why truesec alone cannot
  # tell a wormhole from Delve); everything else from the parsed float.
  # ---------------------------------------------------------------------

  @doc "Parses the `security` string column once; public, shared with `Sweep`."
  @spec parse_security(String.t() | float() | nil) :: float() | nil
  def parse_security(nil), do: nil
  def parse_security(value) when is_float(value), do: value

  def parse_security(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  def parse_security(_value), do: nil

  @doc "Buckets a system into a `security_key()`; public, shared with `Sweep`."
  @spec classify_space(integer() | nil, float() | nil) :: space()
  def classify_space(system_class, security) do
    cond do
      SystemClass.wormhole?(system_class) -> :wh
      system_class == @pochven_class -> :pochven
      is_float(security) and security >= @hs_threshold -> :hs
      is_float(security) and security > 0.0 -> :ls
      is_float(security) -> :ns
      true -> :unknown
    end
  end

  @doc """
  TTL for `kind`, halved in wormhole space (`@wormhole_ttl_factor`). Public
  so `Sweep`'s freshness filter and `region_heat/1` use the SAME ladder
  `rank/1`/`plan/1` do, not a restated copy.
  """
  @spec ttl_seconds(kind(), integer() | nil) :: number()
  def ttl_seconds(kind, system_class) do
    base = Map.fetch!(@default_ttls, kind)
    if SystemClass.wormhole?(system_class), do: base * @wormhole_ttl_factor, else: base * 1.0
  end

  # GUESS -- "value" has no measured definition anywhere in either repo.
  # This treats scouting more dangerous/remote space as more valuable to
  # keep fresh (nullsec/WH intel ages worse for an op than a highsec
  # market hub does); tune once real route feedback exists.
  defp value_score(:wh), do: 0.8
  defp value_score(:pochven), do: 0.9
  defp value_score(:ns), do: 0.7
  defp value_score(:ls), do: 0.4
  defp value_score(:hs), do: 0.1
  defp value_score(:unknown), do: 0.0

  # ---------------------------------------------------------------------
  # Nearest-neighbour walk (plan/1 only). Recomputes distance/leg/score
  # from the CURRENT position at every step -- see moduledoc.
  # ---------------------------------------------------------------------

  defp do_walk(_remaining, _gate_graph, _combined_graph, _current, _budget, 0, _weights, acc) do
    Enum.reverse(acc)
  end

  defp do_walk(remaining, gate_graph, combined_graph, current, budget, limit, weights, acc) do
    if map_size(remaining) == 0 or budget <= 0 do
      Enum.reverse(acc)
    else
      gate_d = bfs(gate_graph, current, budget)
      combined_d = if combined_graph, do: bfs(combined_graph, current, budget), else: %{}

      reachable =
        remaining
        |> Map.values()
        |> Enum.flat_map(fn stop ->
          case classify_jumps(stop.solar_system_id, gate_d, combined_d) do
            nil -> []
            {jumps, leg} -> [finalize_stop(stop, jumps, leg, weights)]
          end
        end)

      case reachable do
        [] ->
          Enum.reverse(acc)

        stops ->
          best = Enum.max_by(stops, &(&1.score / (1 + &1.jumps)))

          do_walk(
            Map.delete(remaining, best.solar_system_id),
            gate_graph,
            combined_graph,
            best.solar_system_id,
            spend(budget, best.jumps),
            limit - 1,
            weights,
            [best | acc]
          )
      end
    end
  end

  # `:infinity - 5` is an ArithmeticError, so the one place the budget is
  # decremented has to say what unbounded means. Nowhere else needs a
  # clause: `:infinity <= 0` is false and `depth < :infinity` is true,
  # both by term order.
  defp spend(:infinity, _jumps), do: :infinity
  defp spend(budget, jumps), do: budget - jumps

  defp finalize_stop(stop, jumps, leg, weights) do
    terms = %{stop.terms | distance: jumps}
    %{stop | jumps: jumps, leg: leg, terms: terms, score: compute_score(terms, weights)}
  end

  # ---------------------------------------------------------------------
  # Graph: cached k-space adjacency + per-call chain overlay.
  # ---------------------------------------------------------------------

  @doc """
  The cached k-space jump adjacency (`WandererApp.Api.MapSolarSystemJumps`,
  ~13k undirected edges), built once and cached 24h under
  `#{inspect(@adjacency_cache_key)}` -- see moduledoc. Public because
  `WandererApp.Scout.Sweep` routes over the SAME graph (never an induced
  per-region subgraph -- see the sweep design doc section 3) and must
  reuse this cache rather than rebuild it.
  """
  @spec graph() :: %{integer() => MapSet.t(integer())}
  def graph do
    case WandererApp.Cache.get(@adjacency_cache_key) do
      nil ->
        built = build_adjacency()
        WandererApp.Cache.put(@adjacency_cache_key, built, ttl: @adjacency_cache_ttl)
        built

      cached ->
        cached
    end
  end

  defp build_adjacency do
    case MapSolarSystemJumps.read(authorize?: false) do
      {:ok, rows} ->
        Enum.reduce(rows, %{}, fn %{from_solar_system_id: a, to_solar_system_id: b}, acc ->
          add_edge(acc, a, b)
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp combined_graph(gate_graph, map_id) do
    case MapConnection.get_link_pairs_advanced(
           %{map_id: map_id, include_mass_crit: true, include_eol: true, include_frig: true},
           authorize?: false
         ) do
      {:ok, connections} ->
        Enum.reduce(connections, gate_graph, fn conn, acc ->
          add_edge(acc, conn.solar_system_source, conn.solar_system_target)
        end)

      {:error, _reason} ->
        gate_graph
    end
  end

  defp add_edge(graph, a, b) do
    graph
    |> Map.update(a, MapSet.new([b]), &MapSet.put(&1, b))
    |> Map.update(b, MapSet.new([a]), &MapSet.put(&1, a))
  end

  defp bfs(graph, origin, max_depth) do
    do_bfs(
      graph,
      :queue.from_list([{origin, 0}]),
      MapSet.new([origin]),
      %{origin => 0},
      max_depth
    )
  end

  defp do_bfs(graph, queue, visited, distances, max_depth) do
    case :queue.out(queue) do
      {{:value, {node, depth}}, queue} when depth < max_depth ->
        neighbors = Map.get(graph, node, MapSet.new())

        {queue, visited, distances} =
          Enum.reduce(neighbors, {queue, visited, distances}, fn n, {q, v, d} ->
            if MapSet.member?(v, n) do
              {q, v, d}
            else
              {:queue.in({n, depth + 1}, q), MapSet.put(v, n), Map.put(d, n, depth + 1)}
            end
          end)

        do_bfs(graph, queue, visited, distances, max_depth)

      {{:value, _at_max_depth}, queue} ->
        do_bfs(graph, queue, visited, distances, max_depth)

      {:empty, _queue} ->
        distances
    end
  end

  # ---------------------------------------------------------------------
  # Batched metadata / coverage reads.
  # ---------------------------------------------------------------------

  defp load_metadata([]), do: %{}

  defp load_metadata(ids) do
    case MapSolarSystem
         |> Ash.Query.filter(solar_system_id in ^ids)
         |> Ash.read(authorize?: false) do
      {:ok, rows} -> Map.new(rows, &{&1.solar_system_id, &1})
      {:error, _reason} -> %{}
    end
  end

  defp load_coverage([]), do: %{}

  defp load_coverage(ids) do
    case ScoutSystemCoverage
         |> Ash.Query.filter(solar_system_id in ^ids)
         |> Ash.read(authorize?: false) do
      {:ok, rows} ->
        rows
        |> Enum.group_by(& &1.solar_system_id)
        |> Map.new(fn {id, kind_rows} -> {id, Map.new(kind_rows, &{&1.kind, &1})} end)

      {:error, _reason} ->
        %{}
    end
  end

  # ---------------------------------------------------------------------
  # Frontier term -- only when `map_id` is given. Never cached: a chain's
  # signatures/connections change on a human timescale, unlike the gate
  # graph. See moduledoc.
  # ---------------------------------------------------------------------

  defp frontier_systems(nil), do: MapSet.new()

  defp frontier_systems(map_id) do
    case MapSystem.read_all_by_map(%{map_id: map_id}, authorize?: false) do
      {:ok, []} ->
        MapSet.new()

      {:ok, map_systems} ->
        ssid_by_internal_id = Map.new(map_systems, &{&1.id, &1.solar_system_id})
        chain_ids = Map.values(ssid_by_internal_id)

        connections =
          case MapConnection.read_by_map(%{map_id: map_id}, authorize?: false) do
            {:ok, rows} -> rows
            {:error, _reason} -> []
          end

        connected_ssids =
          connections
          |> Enum.flat_map(&[&1.solar_system_source, &1.solar_system_target])
          |> MapSet.new()

        wh_signature_ssids =
          wormhole_signature_systems(Map.keys(ssid_by_internal_id), ssid_by_internal_id)

        class1 = MapSet.difference(wh_signature_ssids, connected_ssids)

        sigs_seen = sigs_covered_set(chain_ids)

        class2 =
          connections
          |> Enum.flat_map(fn c ->
            [
              unless_covered(c.solar_system_target, sigs_seen),
              unless_covered(c.solar_system_source, sigs_seen)
            ]
          end)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        MapSet.union(class1, class2)

      {:error, _reason} ->
        MapSet.new()
    end
  end

  defp unless_covered(ssid, sigs_seen) do
    if MapSet.member?(sigs_seen, ssid), do: nil, else: ssid
  end

  defp wormhole_signature_systems(internal_ids, ssid_by_internal_id) do
    case MapSystemSignature.by_system_ids(internal_ids, authorize?: false) do
      {:ok, rows} ->
        rows
        |> Enum.filter(&(&1.group == "Wormhole" and &1.deleted == false))
        |> Enum.flat_map(fn sig -> List.wrap(Map.get(ssid_by_internal_id, sig.system_id)) end)
        |> MapSet.new()

      {:error, _reason} ->
        MapSet.new()
    end
  end

  defp sigs_covered_set([]), do: MapSet.new()

  defp sigs_covered_set(chain_ids) do
    case ScoutSystemCoverage
         |> Ash.Query.filter(solar_system_id in ^chain_ids and kind == :sigs)
         |> Ash.read(authorize?: false) do
      {:ok, rows} -> rows |> Enum.map(& &1.solar_system_id) |> MapSet.new()
      {:error, _reason} -> MapSet.new()
    end
  end
end
