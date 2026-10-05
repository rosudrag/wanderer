defmodule WandererApp.Scout.Regions do
  @moduledoc """
  CHEWY PATCH: the region vocabulary `/scout/planner` scopes with.

  Both scope controls on that page used to be a free-text box taking
  `ids, comma-separated` — which meant an operator had to already know
  that Domain is `10000043`. Nothing in this app ever showed them that
  mapping; `Sweep.region_heat/1`'s table was the only place a region
  name appeared at all, and it is a 70-row aggregate over every k-space
  system, far too expensive to run on a keystroke.

  So the list lives here: one `SELECT DISTINCT` over `map_solar_system_v2`,
  cached in `WandererApp.Cache` for a day — the same idiom
  `Planner.graph/0` uses for the jump index, and for the same reason
  (static reference data that only changes when the SDE is re-imported).

  Wormhole-class systems are excluded exactly as `Sweep.region_heat/1`
  excludes them, so "a region you can pick" and "a region with a heat
  row" are the same set: a J-space region is not routable over the gate
  graph, and offering one as a sweep scope would produce an empty sweep
  with no explanation.
  """

  import Ecto.Query

  alias WandererApp.Repo
  alias WandererApp.SystemClass

  @type region :: %{region_id: integer(), region_name: String.t()}

  @cache_key "scout:planner:regions"
  @cache_ttl :timer.hours(24)

  @wh_classes SystemClass.wormhole_classes()
  @map_solar_system_table "map_solar_system_v2"

  @default_search_limit 12

  @doc "Every pickable region, by name. Cached; see moduledoc."
  @spec all() :: [region()]
  def all do
    case WandererApp.Cache.get(@cache_key) do
      nil ->
        built = load()
        WandererApp.Cache.put(@cache_key, built, ttl: @cache_ttl)
        built

      cached ->
        cached
    end
  end

  @doc """
  Regions whose name contains `query`, case-insensitively, with a prefix
  match sorting ahead of an interior one ("Der" should offer Derelik
  before Providence's neighbours). An empty query returns the head of
  the full list rather than nothing: the control is a dropdown, and a
  dropdown that is blank until you type is a text box with extra steps.
  """
  @spec search(String.t(), pos_integer()) :: [region()]
  def search(query, limit \\ @default_search_limit) do
    case query |> to_string() |> String.trim() |> String.downcase() do
      "" ->
        Enum.take(all(), limit)

      needle ->
        all()
        |> Enum.filter(&String.contains?(String.downcase(&1.region_name), needle))
        |> Enum.sort_by(fn region ->
          {not String.starts_with?(String.downcase(region.region_name), needle),
           region.region_name}
        end)
        |> Enum.take(limit)
    end
  end

  @doc "One region by id, or `nil` — used to re-label restored filters."
  @spec get(integer()) :: region() | nil
  def get(region_id) when is_integer(region_id) do
    Enum.find(all(), &(&1.region_id == region_id))
  end

  def get(_region_id), do: nil

  @doc """
  Resolves ids to `region()`s in the order given, dropping unknown ids.
  Restored localStorage filters go through this: a stored id that no
  longer names a region must disappear, not render as a blank chip.
  """
  @spec resolve([integer()]) :: [region()]
  def resolve(region_ids) do
    region_ids
    |> List.wrap()
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.map(&get/1)
    |> Enum.reject(&is_nil/1)
  end

  defp load do
    from(ms in @map_solar_system_table,
      where:
        (ms.system_class not in ^@wh_classes or is_nil(ms.system_class)) and
          not is_nil(ms.region_id) and not is_nil(ms.region_name),
      distinct: true,
      order_by: [asc: ms.region_name],
      select: %{region_id: ms.region_id, region_name: ms.region_name}
    )
    |> Repo.all()
  end
end
