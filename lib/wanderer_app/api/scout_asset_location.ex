defmodule WandererApp.Api.ScoutAssetLocation do
  @moduledoc """
  CHEWY PATCH: one row per `(character_eve_id, location_id)` — "this
  character has at least one item sitting in that thing".

  The only question it answers is **"is this unanchoring hull armed?"**:
  the asset-safety trigger
  (`WandererApp.Scout.AssetSafety`) only ever fires for a structure we
  put something into, so an unanchoring structure nobody has seeded will
  simply never report, silently, which is the worst possible failure for
  a watchlist. `WandererApp.Scout.Seeding` joins this table against the
  Unanchoring board by `location_id == structure_id` and the page shows
  which hulls still need an item.

  ## It stores an id, not an inventory

  No type, no quantity, no value, and the `location_flag` is dropped
  too. This is a membership set, and storing anyone's actual hangar
  contents would be a privacy cost with no reader.

  Only ids at or above `WandererApp.Scout.Seeding.min_location_id/0`
  (10^12) are kept: below that are NPC stations and solar systems, which
  can never be an unanchoring Upwell structure. Above it the set also
  contains ships and containers, which is harmless — a lookup is always
  keyed on a `structure_id` the sweep feed reported, and EVE item ids are
  globally unique, so a non-structure id can never collide with one.

  ## Latest-wins, and absences are deleted

  `last_seen_at` is stamped on every poll; rows a poll did NOT see are
  destroyed by `WandererApp.Sync.Feeds.AssetLocationsFeed`. Keeping them
  would be worse than useless here: "armed" would stay true forever
  after the item was hauled back out, and the board would stop asking
  for the one thing it exists to ask for.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_asset_locations_v1")

    custom_indexes do
      index([:location_id])
      index([:character_eve_id])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update, action: :update)
    define(:destroy, action: :destroy)

    define(:by_character, action: :by_character, args: [:character_eve_id])
    define(:by_locations, action: :by_locations, args: [:location_ids])
  end

  actions do
    default_accept [:character_eve_id, :character_name, :location_id, :last_seen_at]

    defaults [:create, :read, :destroy]

    update :update do
      require_atomic? false
    end

    read :by_character do
      argument :character_eve_id, :integer, allow_nil?: false
      filter expr(character_eve_id == ^arg(:character_eve_id))
    end

    # The page's own join: "of these structure ids, which are armed, and
    # by whom". Bounded by the board it is called for, never a full scan.
    read :by_locations do
      argument :location_ids, {:array, :integer}, allow_nil?: false
      filter expr(location_id in ^arg(:location_ids))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :character_eve_id, :integer do
      allow_nil? false
    end

    attribute :character_name, :string

    attribute :location_id, :integer do
      allow_nil? false
    end

    attribute :last_seen_at, :utc_datetime do
      allow_nil? false
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :uniq_character_location, [:character_eve_id, :location_id]
  end
end
