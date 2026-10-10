defmodule WandererApp.Scout.Seeding do
  @moduledoc """
  CHEWY PATCH: which unanchoring structures are **armed** — i.e. which
  ones have one of our items in them, so that
  `WandererApp.Scout.AssetSafety`'s trigger will actually fire when the
  decommission completes.

  ## Why this exists

  The asset-safety notification is the best signal on `/scout`, and it
  is entirely conditional on a deliberate act: somebody has to drop an
  item into the hull first. A structure nobody seeded never reports, and
  it never reports *silently* — the Unanchoring board looks exactly the
  same whether the trigger is armed or not. That is a watchlist lying by
  omission, and it is the one failure a reader cannot discover by
  looking harder.

  So the page answers the question directly: every unanchoring row says
  armed or not, and there is a board of the ones that are not.

  ## It is read from ESI, not remembered

  `GET /characters/{id}/assets/` reports an item's `location_id`, and an
  item inside an Upwell structure carries that structure's id. So
  "armed" is a join (`location_id == structure_id`) against
  `WandererApp.Api.ScoutAssetLocation`, refreshed hourly by
  `WandererApp.Sync.Feeds.AssetLocationsFeed`. Nothing is marked by
  hand: a checkbox would be wrong within a day of somebody hauling the
  item back out, and nobody would ever notice.

  ## What it can get wrong, and in which direction

  A hull seeded by a character this app does not track (or one that has
  not consented) reads as **not armed**. That is the safe direction: the
  cost is dropping a second item, and the alternative error — claiming a
  hull is armed when nothing will ever report it — is the exact failure
  this module exists to remove. `armed_by/1` names the character, so a
  reader can tell a real arming from a stale one.
  """

  require Ash.Query

  alias WandererApp.Api.{Character, ScoutAssetLocation}

  # Below 10^12 are NPC stations (6x...) and solar systems (3x...), which
  # can never be an unanchoring Upwell structure.
  @min_location_id 1_000_000_000_000

  @scope "esi-assets.read_assets.v1"

  @doc "The lowest `location_id` worth storing. See @moduledoc."
  @spec min_location_id() :: pos_integer()
  def min_location_id, do: @min_location_id

  @doc "The ESI scope the assets feed needs."
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc """
  `%{structure_id => [character_name]}` for the given structure ids.

  Bounded by the ids the caller is rendering — never a full scan of
  everyone's hangars — because the only consumer is a board that already
  holds its rows.
  """
  @spec armed_by([integer()]) :: %{integer() => [String.t()]}
  def armed_by([]), do: %{}

  def armed_by(structure_ids) when is_list(structure_ids) do
    case ScoutAssetLocation.by_locations(Enum.uniq(structure_ids), authorize?: false) do
      {:ok, rows} ->
        rows
        |> Enum.group_by(& &1.location_id, &(&1.character_name || "a tracked character"))
        |> Map.new(fn {location_id, names} -> {location_id, Enum.uniq(names)} end)

      {:error, _reason} ->
        %{}
    end
  end

  @doc """
  Splits structure rows into `{armed, unarmed}`, in the order given.

  One query for the whole board, not one per row.
  """
  @spec split([map()]) :: {[map()], [map()]}
  def split(rows) do
    armed = armed_by(Enum.map(rows, & &1.structure_id))

    Enum.split_with(rows, &Map.has_key?(armed, &1.structure_id))
  end

  @doc """
  Every character whose stored token carries the assets scope.

  Same filter discipline (and the same AshCloak trap) as
  `WandererApp.Scout.AssetSafety.watching_characters/0`: `access_token`
  is encrypted at rest, so a SQL predicate on it matches nothing and
  takes the whole read down with it.
  """
  @spec asset_characters() :: [Character.t()]
  def asset_characters do
    scope = @scope

    Character
    |> Ash.Query.filter(deleted == false and contains(scopes, ^scope))
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, characters} -> characters
      {:error, _reason} -> []
    end
  end

  @doc """
  Replaces one character's stored location set with `location_ids`.

  Latest-wins and absences are DELETED — see the resource's moduledoc:
  an "armed" that survives the item being hauled back out is worse than
  no answer at all.

  Returns how many locations are now stored.
  """
  @spec replace(map(), [integer()]) :: non_neg_integer()
  def replace(character, location_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    eve_id = eve_id(character)

    wanted =
      location_ids
      |> Enum.filter(&(is_integer(&1) and &1 >= @min_location_id))
      |> MapSet.new()

    existing =
      case ScoutAssetLocation.by_character(eve_id, authorize?: false) do
        {:ok, rows} -> rows
        _error -> []
      end

    Enum.each(existing, fn row ->
      if MapSet.member?(wanted, row.location_id) do
        ScoutAssetLocation.update(row, %{last_seen_at: now, character_name: character.name},
          authorize?: false
        )
      else
        ScoutAssetLocation.destroy(row, authorize?: false)
      end
    end)

    known = MapSet.new(existing, & &1.location_id)

    wanted
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.each(fn location_id ->
      ScoutAssetLocation.create(
        %{
          character_eve_id: eve_id,
          character_name: character.name,
          location_id: location_id,
          last_seen_at: now
        },
        authorize?: false
      )
    end)

    MapSet.size(wanted)
  end

  defp eve_id(%{eve_id: eve_id}) when is_integer(eve_id), do: eve_id

  defp eve_id(%{eve_id: eve_id}) when is_binary(eve_id) do
    case Integer.parse(eve_id) do
      {number, _rest} -> number
      :error -> 0
    end
  end
end
