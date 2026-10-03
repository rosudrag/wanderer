defmodule WandererApp.Scout.Stats do
  @moduledoc """
  CHEWY PATCH: the aggregate reads behind `WandererAppWeb.ScoutIntelLive`
  that an Ash read action cannot express.

  Three of them, all schemaless Ecto against the two scout tables:

    * `last_observed_at/0` — how fresh the log is. Without it a dead
      eveknob client and a quiet region render identically, which is the
      one failure mode of a push-only log.

    * `totals/0` — "nothing ever reported" vs "nothing in this window".
      Only called when a table came back empty, because `count(*)` on an
      append-only table is a sequential scan.

    * `spawn_hotspots/2` — `GROUP BY system, location, spawn` with a
      count and an ISK sum. Ash has no general group-by, and folding the
      window in Elixir would reintroduce exactly the unbounded read that
      the page's `limit` exists to prevent.

  The table names are literals rather than the resources' `postgres do
  table ... end`, which is a real coupling: renaming a table means
  editing here too. Deliberate — the alternative is `Ash.Resource.Info`
  lookups at runtime to save one grep.
  """

  import Ecto.Query

  alias WandererApp.Repo

  @spawns "scout_spawn_sightings_v1"
  @structures "scout_structure_sightings_v1"

  # A hotspot list is read, not scrolled.
  @max_hotspots 100

  @doc """
  Newest observation in each log, or `nil` for an empty one. Cheap: both
  tables carry an index on `observed_at`.
  """
  @spec last_observed_at() :: %{spawns: DateTime.t() | nil, structures: DateTime.t() | nil}
  def last_observed_at do
    %{
      spawns: max_observed_at(@spawns),
      structures: max_observed_at(@structures)
    }
  end

  @doc """
  Row counts for both logs, ignoring any window. Call only on an empty
  table: this is a sequential scan.
  """
  @spec totals() :: %{spawns: non_neg_integer(), structures: non_neg_integer()}
  def totals do
    %{
      spawns: Repo.one(from(s in @spawns, select: count())),
      structures: Repo.one(from(s in @structures, select: count()))
    }
  end

  @doc """
  Spawns in the window grouped by system + location + spawn name, most
  frequent first.

  Takes the same optional `:system_id` and `:q` filters as the
  `:search` read action, so the aggregate always describes the same rows
  the flat table below it is showing.
  """
  @spec spawn_hotspots(DateTime.t(), keyword()) :: [map()]
  def spawn_hotspots(since, opts \\ []) do
    from(s in @spawns,
      where: s.observed_at >= ^since,
      group_by: [s.solar_system_id, s.solar_system_name, s.location_name, s.spawn_name],
      order_by: [desc: count(s.id), desc: max(s.observed_at)],
      limit: @max_hotspots,
      select: %{
        solar_system_id: s.solar_system_id,
        solar_system_name: s.solar_system_name,
        location_name: s.location_name,
        spawn_name: s.spawn_name,
        sightings: count(s.id),
        last_seen: max(s.observed_at),
        isk_value: sum(s.isk_value)
      }
    )
    |> hotspot_system(opts[:system_id])
    |> hotspot_search(opts[:q])
    |> Repo.all()
    |> Enum.map(&%{&1 | last_seen: to_utc(&1.last_seen)})
  end

  defp hotspot_system(query, nil), do: query
  defp hotspot_system(query, system_id), do: where(query, [s], s.solar_system_id == ^system_id)

  defp hotspot_search(query, nil), do: query

  defp hotspot_search(query, q) do
    where(
      query,
      [s],
      fragment(
        "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
        s.spawn_name,
        s.location_name,
        s.solar_system_name,
        s.spawn_category,
        ^q
      )
    )
  end

  defp max_observed_at(table) do
    from(s in table, select: max(s.observed_at))
    |> Repo.one()
    |> to_utc()
  end

  # Schemaless Ecto hands back whatever Postgrex decoded, and these
  # columns are `timestamp(0)` without a zone, i.e. NaiveDateTime. The
  # page formats DateTimes.
  defp to_utc(nil), do: nil
  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc(%DateTime{} = datetime), do: datetime
end
