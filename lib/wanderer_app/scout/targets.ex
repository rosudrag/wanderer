defmodule WandererApp.Scout.Targets do
  @moduledoc """
  CHEWY PATCH (target routing): "take me round every system where we last
  saw a structure coming out of the ground".

  The planner's other two modes answer coverage questions --
  `WandererApp.Scout.Planner` ranks what has not been looked at near an
  origin, `WandererApp.Scout.Sweep` routes a whole region. This module
  answers a FINDINGS question: the candidate set is not a region and not
  a ball, it is the systems named by rows in `scout_structures_v1`.

  ## It is a membership source, not a second router

  Everything after "which systems" is `Sweep.sweep/1` unchanged -- the
  same full-k-space graph, the same greedy + 2-opt tour, the same
  waypoint compression, the same `sweep_result` shape the page and the
  wire format already render. This module only decides the id list and
  hands it over as `scope: {:systems, ids}`. Two consequences worth
  stating because they are deliberate:

    * `include_fresh: true`, always. A sweep normally drops a system
      that was scouted inside `Planner.ttl_seconds/2` -- correct when the
      objective is coverage, wrong here: a structure does not stop
      unanchoring because someone flew past an hour ago. Coverage is
      shown on the route (the ladder column) and never filters it.
    * `kind: :visit`. With freshness disabled the kind decides nothing
      but which coverage column the `reason` badge is computed against,
      and "have we been there at all" is the honest one for a go-and-look
      route. It is not a knob on the page for that reason.

  ## Five filters, each one a question someone asked

    * `families` -- which status families count as a target. Default
      `[:unanchoring]`, the one this was built for.
    * `window_days` -- ignore a finding nobody has re-confirmed in that
      many days. A structure last seen six days ago is a guess, not a
      target.
    * `hide_past_window` -- for an unanchoring hull, drop it once
      `WandererApp.Scout.Unanchor.predicted_max_at/1` is in the past: the
      decommission can no longer be running, so the trip is wasted. Only
      ever drops rows that CARRY a prediction (orbitals and rows with no
      `unanchoring_since` are never dropped by it).
    * `ignore` -- explicit system ids the operator struck off. Applied
      here rather than as `Sweep`'s `avoid:` so the counts this module
      reports ("3 ignored") match what the page shows.
    * `security` / `radius` -- band membership, and, when a start system
      is given, how far from it a target may be. Radius is the answer to
      the real shape of this data: 39 target systems spread over 14
      regions is not one route.

  Anything the filters drop is REPORTED, never silently removed: an
  operator who cannot see that four targets sit outside their radius
  will read the short route as "there is nothing else out there".
  """

  require Ash.Query
  require Logger

  alias WandererApp.Api.{MapSolarSystem, ScoutStructure}
  alias WandererApp.Scout.{Planner, Status, Sweep, Unanchor}

  @type family :: :unanchoring | :unanchored | :anchoring | :dead | :reinforced

  @type target :: %{
          solar_system_id: integer(),
          name: String.t(),
          region_name: String.t() | nil,
          space: Planner.space(),
          structures: pos_integer(),
          statuses: [String.t()],
          owners: [String.t()],
          earliest_deadline: DateTime.t() | nil,
          last_confirmed_at: DateTime.t(),
          oldest_confirmed_at: DateTime.t()
        }

  @type result :: %{
          generated_at: DateTime.t(),
          families: [family()],
          route: Sweep.sweep_result(),
          targets: %{integer() => target()},
          candidates: non_neg_integer(),
          excluded: %{
            past_window: non_neg_integer(),
            ignored: non_neg_integer(),
            band: non_neg_integer(),
            radius: [target()],
            unroutable: [target()]
          }
        }

  @type opts :: [
          families: [family()],
          window_days: pos_integer() | nil,
          hide_past_window: boolean(),
          ignore: [integer()],
          security: [Planner.security_key()],
          start: integer() | nil,
          radius: non_neg_integer(),
          compress: boolean()
        ]

  @family_keys [:unanchoring, :unanchored, :anchoring, :dead, :reinforced]
  @default_families [:unanchoring]

  @window_days [1, 3, 7, 14]
  @default_window_days 7

  # The default answers the measured shape of the data (2026-10-08: 39
  # unanchoring systems in 14 regions). 30 jumps from a parked character
  # is a long evening; the cap exists so a typo cannot ask for a tour of
  # the cluster.
  @default_radius 30
  @max_radius 60

  @doc "The status families this mode can target, in display order."
  @spec families() :: [family()]
  def families, do: @family_keys

  @doc "Chip labels, so the page never restates the vocabulary."
  @spec family_label(family()) :: String.t()
  def family_label(:unanchoring), do: "Unanchoring"
  def family_label(:unanchored), do: "Unanchored"
  def family_label(:anchoring), do: "Anchoring"
  def family_label(:dead), do: "Abandoned / no fuel"
  def family_label(:reinforced), do: "Reinforced"

  @doc "Default families (`#{inspect(@default_families)}`)."
  @spec default_families() :: [family()]
  def default_families, do: @default_families

  @doc "The window selector's values, in days."
  @spec window_days_options() :: [pos_integer()]
  def window_days_options, do: @window_days

  @spec default_window_days() :: pos_integer()
  def default_window_days, do: @default_window_days

  @spec default_radius() :: pos_integer()
  def default_radius, do: @default_radius

  @spec max_radius() :: pos_integer()
  def max_radius, do: @max_radius

  @doc "The EVE status strings one family covers."
  @spec statuses(family()) :: [String.t()]
  def statuses(:unanchoring), do: Status.unanchoring_family()
  def statuses(:unanchored), do: Status.unanchored_family()
  def statuses(:anchoring), do: Status.anchoring_family()
  def statuses(:dead), do: Status.dead_family()
  def statuses(:reinforced), do: Status.reinforced_family()

  @doc """
  The target systems, and a route over them.

  `{:error, :no_targets}` when nothing survives the filters -- which is a
  normal answer here, unlike in a region sweep: "nothing is unanchoring
  anywhere you can reach" is the good day.
  """
  @spec plan(opts()) :: {:ok, result()} | {:error, atom()}
  def plan(opts \\ []) do
    resolved = resolve(opts)
    now = DateTime.utc_now()

    with {:ok, rows} <- load_rows(resolved, now) do
      build(resolved, rows, now)
    end
  end

  defp build(resolved, rows, now) do
    kept = Enum.reject(rows, &past_window?(&1, resolved, now))
    past_window = length(rows) - length(kept)

    by_system = Enum.group_by(kept, & &1.solar_system_id)
    candidates = map_size(by_system)

    {ignored, by_system} = drop_ignored(by_system, resolved.ignore)

    case targets_for(by_system) do
      [] ->
        {:error, :no_targets}

      targets ->
        {in_band, band} = Enum.split_with(targets, &(&1.space in resolved.security))
        {routable, unroutable} = Enum.split_with(in_band, &routable?/1)
        {near, far} = within_radius(routable, resolved)

        route(resolved, near, %{
          generated_at: now,
          families: resolved.families,
          candidates: candidates,
          excluded: %{
            past_window: past_window,
            ignored: ignored,
            band: length(band),
            radius: far,
            unroutable: unroutable
          }
        })
    end
  end

  defp route(_resolved, [], _envelope), do: {:error, :no_targets}

  defp route(resolved, targets, envelope) do
    ids = Enum.map(targets, & &1.solar_system_id)

    opts = [
      scope: {:systems, ids},
      kind: :visit,
      include_fresh: true,
      security: resolved.security,
      start: resolved.start,
      compress: resolved.compress
    ]

    case Sweep.sweep(opts) do
      {:ok, sweep_result} ->
        {:ok,
         envelope
         |> Map.put(:route, sweep_result)
         |> Map.put(:targets, Map.new(targets, &{&1.solar_system_id, &1}))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Filters
  # -------------------------------------------------------------------

  # Only ever drops a row that carries a real prediction: `nil` is
  # "nothing honest to say" (an orbital, or no `unanchoring_since`), and
  # dropping those would hide every finding this mode exists for.
  defp past_window?(_row, %{hide_past_window: false}, _now), do: false

  defp past_window?(row, _resolved, now) do
    case Unanchor.predicted_max_at(row) do
      nil -> false
      at -> DateTime.compare(at, now) == :lt
    end
  end

  defp drop_ignored(by_system, ignore) do
    kept = Map.drop(by_system, MapSet.to_list(ignore))
    {map_size(by_system) - map_size(kept), kept}
  end

  # A system with no node in the k-space jump graph (a wormhole, or an
  # id the static map does not know) cannot be waypointed. Listed, not
  # dropped silently -- it is still a real finding, just not one an
  # autopilot can fly to.
  defp routable?(target), do: Map.has_key?(Planner.graph(), target.solar_system_id)

  # Radius is measured from the START, so it only exists when one is
  # pinned; with no start the sweep picks the cheapest opening itself and
  # "within 30 of what" has no answer.
  defp within_radius(targets, %{start: start, radius: radius})
       when is_integer(start) and is_integer(radius) and radius > 0 do
    ids = Enum.map(targets, & &1.solar_system_id)
    from_start = ids |> then(&Sweep.distances([start | &1])) |> Map.get(start, %{})

    Enum.split_with(targets, fn target ->
      case Map.get(from_start, target.solar_system_id) do
        jumps when is_integer(jumps) -> jumps <= radius
        _ -> false
      end
    end)
  end

  defp within_radius(targets, _resolved), do: {targets, []}

  # -------------------------------------------------------------------
  # Reads
  # -------------------------------------------------------------------

  defp load_rows(%{families: []}, _now), do: {:error, :no_families}

  defp load_rows(resolved, now) do
    statuses = Enum.flat_map(resolved.families, &statuses/1)
    since = since(resolved.window_days, now)

    case ScoutStructure.targets(statuses, since, authorize?: false) do
      {:ok, rows} ->
        {:ok, rows}

      {:error, reason} ->
        Logger.error("[scout targets] structure read failed: #{inspect(reason)}")
        {:error, :read_failed}
    end
  end

  defp since(nil, _now), do: ~U[2000-01-01 00:00:00Z]
  defp since(days, now), do: DateTime.add(now, -days, :day)

  defp targets_for(by_system) when map_size(by_system) == 0, do: []

  defp targets_for(by_system) do
    metadata = load_metadata(Map.keys(by_system))

    by_system
    |> Enum.map(fn {system_id, rows} -> target(system_id, rows, Map.get(metadata, system_id)) end)
    |> Enum.sort_by(&{deadline_sort(&1.earliest_deadline), &1.name})
  end

  # A system the static map has no row for still routes (the graph is
  # keyed on ids, not names) and still has findings, so it keeps its id
  # as a name rather than disappearing.
  defp target(system_id, rows, nil) do
    base(system_id, rows)
    |> Map.merge(%{name: to_string(system_id), region_name: nil, space: :unknown})
  end

  defp target(system_id, rows, sys) do
    base(system_id, rows)
    |> Map.merge(%{
      name: sys.solar_system_name,
      region_name: sys.region_name,
      space: Planner.classify_space(sys.system_class, Planner.parse_security(sys.security))
    })
  end

  defp base(system_id, rows) do
    confirmations = Enum.map(rows, & &1.last_confirmed_at)

    %{
      solar_system_id: system_id,
      structures: length(rows),
      statuses: rows |> Enum.map(& &1.status) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      owners: rows |> Enum.map(& &1.owner_name) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      earliest_deadline: earliest_deadline(rows),
      last_confirmed_at: Enum.max(confirmations, DateTime),
      oldest_confirmed_at: Enum.min(confirmations, DateTime)
    }
  end

  # The tightest upper bound in the system: whichever hull here must be
  # out of the ground first. Never a timer -- see `Unanchor`.
  defp earliest_deadline(rows) do
    rows
    |> Enum.map(&Unanchor.predicted_max_at/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      deadlines -> Enum.min(deadlines, DateTime)
    end
  end

  # Soonest deadline first, then everything with no deadline at all.
  defp deadline_sort(nil), do: {1, 0}
  defp deadline_sort(at), do: {0, DateTime.to_unix(at)}

  defp load_metadata(ids) do
    case MapSolarSystem
         |> Ash.Query.filter(solar_system_id in ^ids)
         |> Ash.read(authorize?: false) do
      {:ok, systems} -> Map.new(systems, &{&1.solar_system_id, &1})
      {:error, _reason} -> %{}
    end
  end

  # -------------------------------------------------------------------
  # Options
  # -------------------------------------------------------------------

  defp resolve(opts) do
    opts = Map.new(opts)

    %{
      families: normalize_families(Map.get(opts, :families, @default_families)),
      window_days: normalize_window(Map.get(opts, :window_days, @default_window_days)),
      hide_past_window: Map.get(opts, :hide_past_window, true) != false,
      ignore:
        opts |> Map.get(:ignore, []) |> List.wrap() |> Enum.filter(&is_integer/1) |> MapSet.new(),
      security:
        opts |> Map.get(:security, Planner.default_security()) |> Planner.normalize_security(),
      start: normalize_start(Map.get(opts, :start)),
      radius: normalize_radius(Map.get(opts, :radius, @default_radius)),
      compress: Map.get(opts, :compress, true) != false
    }
  end

  @doc """
  Normalizes a family list (atoms or strings), dropping anything
  unrecognised. Public for the same reason `Planner.normalize_security/1`
  is: the LiveView restores these from localStorage, which is
  user-writable.
  """
  @spec normalize_families([term()] | term()) :: [family()]
  def normalize_families(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_family/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> then(fn
      [] -> @default_families
      families -> Enum.filter(@family_keys, &(&1 in families))
    end)
  end

  defp normalize_family(key) when key in @family_keys, do: key

  defp normalize_family(key) when is_binary(key) do
    normalized = String.to_existing_atom(String.downcase(key))
    if normalized in @family_keys, do: normalized, else: nil
  rescue
    ArgumentError -> nil
  end

  defp normalize_family(_key), do: nil

  @doc "A stored/queried window value, or nil for \"any age\"."
  @spec normalize_window(term()) :: pos_integer() | nil
  def normalize_window(days) when days in @window_days, do: days
  def normalize_window(_days), do: nil

  defp normalize_start(start) when is_integer(start) and start > 0, do: start
  defp normalize_start(_start), do: nil

  defp normalize_radius(radius) when is_integer(radius) and radius > 0,
    do: min(radius, @max_radius)

  defp normalize_radius(_radius), do: 0
end
