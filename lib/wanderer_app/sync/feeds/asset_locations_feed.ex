defmodule WandererApp.Sync.Feeds.AssetLocationsFeed do
  @moduledoc """
  CHEWY PATCH: walks `GET /characters/{id}/assets/` for every character
  that consented to `esi-assets.read_assets.v1` and keeps the set of
  `location_id`s they have something sitting in.

  That set is what tells `/scout` whether an unanchoring hull is ARMED —
  whether `WandererApp.Scout.AssetSafety`'s trigger will fire at all
  when it finishes. See `WandererApp.Scout.Seeding`.

  ## Paging is the whole implementation

  ESI serves 1000 assets per page and says nothing useful in the body
  about how many pages there are, so this walks until a page comes back
  short, capped at `@max_pages`. The cap is a real limit and is logged,
  not hidden: a character whose assets run past it may have a structure
  missed, which reads on the page as "not armed". That is the safe
  direction — the cost is dropping a second item — and the opposite
  error (claiming armed when nothing will report) is the one this
  feature exists to remove.

  Only the `location_id` is kept. No type, no quantity, no flag; see
  `WandererApp.Api.ScoutAssetLocation`.

  ## Cadence

  3600s, the endpoint's own ESI cache. The ETag is threaded on page 1
  only: an untouched hangar then costs one conditional request instead
  of a full walk, and any change at all re-walks from the top.
  """

  @behaviour WandererApp.Sync.Feed

  require Logger

  alias WandererApp.Api.Character
  alias WandererApp.Esi
  alias WandererApp.Scout.Seeding

  @cadence_seconds 3600
  @page_size 1000
  @max_pages 20

  # An asset's parent chain: item in a container in a ship in a
  # structure is four deep. 32 is far past anything EVE allows and
  # exists only so a cycle cannot hang a sync task.
  @max_depth 32

  @doc """
  `WandererApp.Sync.Registry`'s scope resolver: one scope per character
  holding the assets scope. Re-read every tick, so consent starts and
  deletion stops polling with no restart.
  """
  @spec scopes() :: [{Character.t(), String.t()}]
  def scopes do
    Seeding.asset_characters()
    |> Enum.map(&{&1, "assets:" <> to_string(&1.eve_id)})
  end

  @impl true
  def cadence_seconds(_character), do: @cadence_seconds

  @impl true
  def token_holder(%Character{id: id}) do
    case Character.by_id(id, authorize?: false) do
      {:ok, character} -> {:character, character}
      _not_found -> {:error, :character_gone}
    end
  end

  def token_holder(_scope), do: {:error, :not_a_character}

  @impl true
  def fetch(%Character{} = scope, etag) do
    case token_holder(scope) do
      {:character, character} ->
        case page(character, 1, etag) do
          {:ok, rows, page_etag} ->
            {:ok, rows ++ rest(character, 2, rows), page_etag}

          other ->
            other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def upsert(%Character{} = scope, rows) when is_list(rows) do
    character =
      case token_holder(scope) do
        {:character, character} -> character
        _gone -> scope
      end

    stored = rows |> root_locations() |> then(&Seeding.replace(character, &1))

    Logger.debug("[Scout.Seeding] #{character.name}: #{stored} armed location(s)")

    :ok
  end

  def upsert(_scope, _data), do: :ok

  @doc """
  Every id this character's assets ultimately SIT IN.

  Assets are a TREE, which the first cut of this missed: only an item
  dropped loose in a structure's hangar reports that structure as its
  `location_id`. Put it in a container, or leave it in a ship parked
  there, and the `location_id` is that container's or ship's `item_id`
  — and the structure never appears in the list at all, so a hull that
  IS seeded reads as `seed it` on the page.

  Measured 2026-10-10 on live data: 228 stored locations matched 4 of
  27 unanchoring structures.

  So walk each asset up through its parents until the id it sits in is
  not itself one of this character's items; that root is a structure, a
  station or a solar system. Everything an item is nested inside goes to
  asset safety with it, so the root is exactly the right answer.

  The walk is capped: ESI has never returned a cycle, but a cycle here
  would be an infinite loop inside a sync task.
  """
  @spec root_locations([map()]) :: [integer()]
  def root_locations(rows) do
    parents =
      rows
      |> Enum.reduce(%{}, fn row, acc ->
        case {integer(row["item_id"]), integer(row["location_id"])} do
          {{:ok, item_id}, {:ok, location_id}} -> Map.put(acc, item_id, location_id)
          _incomplete -> acc
        end
      end)

    parents
    |> Map.values()
    |> Enum.map(&root(&1, parents, @max_depth))
    |> Enum.uniq()
  end

  defp root(id, _parents, 0), do: id

  defp root(id, parents, depth) do
    case Map.fetch(parents, id) do
      {:ok, parent} -> root(parent, parents, depth - 1)
      :error -> id
    end
  end

  @impl true
  def retention_days, do: :infinity

  # Nothing to purge on a schedule: every poll already deletes the rows
  # it did not see, which is the only staleness this table can have.
  @impl true
  def purge_stale(_scope), do: :ok

  # Every value on this wire may arrive as a string; the ids are 64-bit,
  # so a float coercion would quietly lose the low digits.
  defp integer(value) when is_integer(value), do: {:ok, value}

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _not_an_id -> :error
    end
  end

  defp integer(_value), do: :error

  # -- paging ---------------------------------------------------------------

  defp rest(_character, _page, previous) when length(previous) < @page_size, do: []

  defp rest(character, page, _previous) when page > @max_pages do
    Logger.warning(
      "[Scout.Seeding] #{character.name}: stopped at #{@max_pages} asset pages; " <>
        "a structure past that reads as not armed"
    )

    []
  end

  defp rest(character, page, _previous) do
    case page(character, page, nil) do
      {:ok, rows, _etag} -> rows ++ rest(character, page + 1, rows)
      _error_or_not_modified -> []
    end
  end

  defp page(character, page, etag) do
    Esi.get_character_assets(character.eve_id,
      access_token: character.access_token,
      character_id: character.id,
      params: [page: page],
      etag: etag
    )
    |> case do
      {:ok, rows, page_etag} when is_list(rows) -> {:ok, rows, page_etag}
      {:ok, rows} when is_list(rows) -> {:ok, rows, nil}
      :not_modified -> :not_modified
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end
end
