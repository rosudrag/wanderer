defmodule WandererApp.Scout.Alerts do
  @moduledoc """
  CHEWY PATCH: the one finding in the scout log that is worth interrupting
  a reader for — a structure reported `Unanchored`.

  `Unanchored` (`structure_state == 1`, STATE_UNANCHORED) means the thing
  is floating in space fully undeployed: no fitting, no services, no
  reinforcement timer to wait out, nothing shooting back. It used to be
  one row in the Anchoring table among half-built Astrahuses, which is
  the same as not reporting it.

  Two readers:

    * `/scout` leads with it — a banner above the toolbar on BOTH tabs,
      its own panel, its own card.
    * the sidebar badge (`WandererAppWeb.ScoutNav`), which is the only
      part of this feature visible while you are on the map canvas.

  The sidebar is the constraint. `WandererAppWeb.Nav.on_mount/4` runs for
  EVERY LiveView mount, map canvas included, so the badge may not cost a
  query per mount — the same rule that forced
  `ScoutAccess.can_view_cached?/1`. So `count_cached/0` answers from
  `WandererApp.Cache`, `WandererApp.Scout.Ingest` invalidates it whenever
  a structure batch stores anything, and the TTL is only a backstop for a
  row written around the ingest path.

  ## The horizon

  Reads here are bounded by `horizon_days/0`, NOT by the page's window
  selector. An unanchored structure stays unanchored until somebody moves
  it or shoots it, so "did you pick 24 hours or 90 days" is the wrong
  question — but a sighting from last spring is not actionable either.
  Seven days is the compromise, and it is the same reasoning the live
  timer table and the "Still out there" spawn list already use to ignore
  that selector.
  """

  require Ash.Query

  alias WandererApp.Api.ScoutStructureSighting
  alias WandererApp.Scout.Space

  @horizon_days 7

  # The badge reads "9+" past this, so counting further is wasted work.
  @count_cap 9

  @cache_key "scout:unanchored_count"
  @cache_ttl :timer.minutes(5)

  @doc "How far back a sighting still counts as an alert."
  @spec horizon_days() :: pos_integer()
  def horizon_days, do: @horizon_days

  @doc "The cutoff `horizon_days/0` implies."
  @spec since(DateTime.t()) :: DateTime.t()
  def since(now \\ DateTime.utc_now()), do: DateTime.add(now, -@horizon_days, :day)

  @doc """
  The latest sighting of each structure currently reported `Unanchored`.

  Options: `:system_id` and `:space` (both the page's own filters, so the
  banner narrows with the rest of the page), and `:limit`.

  Deliberately takes no `:q`: the text search is tab vocabulary — on the
  spawns tab it is belt and spawn names — and an alert that a search box
  can hide is not an alert.
  """
  @spec unanchored(keyword()) :: [ScoutStructureSighting.t()]
  def unanchored(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    ScoutStructureSighting
    |> Ash.Query.for_read(:unanchored, %{
      since: since(),
      system_id: Keyword.get(opts, :system_id)
    })
    |> Space.filter(Keyword.get(opts, :space, Space.all()))
    # Latest row per structure, folded by Postgres -- the same
    # DISTINCT ON every other board on this page uses.
    |> Ash.Query.distinct([:structure_id])
    |> Ash.Query.distinct_sort(observed_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  @doc """
  How many structures are reported unanchored right now, capped at
  `9` with a `true` flag meaning "more than that".

  Cached: see the moduledoc. Unfiltered on purpose — the badge is drawn
  from pages that have no scout filters at all.
  """
  @spec count_cached() :: {non_neg_integer(), boolean()}
  def count_cached do
    case WandererApp.Cache.get(@cache_key) do
      nil ->
        counted = count()
        WandererApp.Cache.put(@cache_key, counted, ttl: @cache_ttl)
        counted

      counted ->
        counted
    end
  end

  @doc "Drops the cached badge count. Called by the ingest."
  @spec invalidate() :: any()
  def invalidate, do: WandererApp.Cache.delete(@cache_key)

  defp count do
    rows = unanchored(limit: @count_cap + 1)
    capped? = length(rows) > @count_cap

    {min(length(rows), @count_cap), capped?}
  end
end
