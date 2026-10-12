defmodule WandererApp.Api.ScoutPlannerPreset do
  @moduledoc """
  CHEWY PATCH: one named, saved set of `/scout/planner` controls, per user.

  The planner already remembered the LAST state a reader left it in
  (`ScoutPlannerLive`'s `scout_planner_filters` localStorage blob). That is
  one state, on one browser profile, overwritten by the next click. A scout
  who runs "Delve, 3-way split, these three pilots" on Tuesday and
  "unanchoring targets within 20 jumps of Jita" on Wednesday had to rebuild
  the second one every time -- region chips, bands, kind, k, and one pilot
  per split part.

  A preset is the SAME state map the sticky blob holds, written here under a
  name instead. Two deliberate consequences:

    * It is **server-side**, not a second localStorage key. A preset is
      something a reader deliberately named and expects to still exist after
      a browser reset, or from the other machine -- unlike the sticky blob,
      which is "where I left off here". It is a row, not a Cachex entry, for
      the same reason: a cache dies with every deploy.
    * `state` is a plain `:map` (jsonb), never a column per control. The
      planner's control set has changed with every phase of that feature
      (sweep, split, targets, pilot-follow, pinned starts); a schema that
      named them would need a migration per phase, and an older preset would
      then have to be migrated rather than simply re-validated. Instead
      `ScoutPlannerLive.apply_state/2` re-validates EVERY field on load
      exactly as it does for the localStorage blob -- unknown keys are
      ignored, missing keys fall back to the current value, and a stored
      region/system/character that no longer exists vanishes rather than
      scoping a query to nothing.

  `(user_id, name)` is unique and the write path is an upsert, so saving
  under an existing name overwrites it -- which is what "save" means on a
  named preset, and what makes "tweak it and save again" one click rather
  than delete-then-save.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_planner_presets_v1")

    # Every read this resource has is "this user's presets", in name
    # order; the uniqueness index backs the upsert.
    custom_indexes do
      index([:user_id])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:upsert, action: :upsert)

    define(:by_user, action: :by_user, args: [:user_id])

    define(:by_user_and_name,
      action: :by_user_and_name,
      args: [:user_id, :name],
      get?: true
    )
  end

  actions do
    default_accept [:user_id, :name, :state]

    defaults [:create, :read, :destroy]

    # Saving under a name that already exists REPLACES it. `updated_at` is
    # set explicitly: an upsert that only writes `state` would otherwise
    # leave the timestamp at the row's original creation, and the UI shows
    # "saved <ago>" from it.
    create :upsert do
      upsert?(true)
      upsert_identity(:uniq_user_preset)
      upsert_fields([:state, :updated_at])

      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(user_id == ^arg(:user_id))

      prepare build(sort: [name: :asc])
    end

    read :by_user_and_name do
      get? true

      argument :user_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false

      filter expr(user_id == ^arg(:user_id) and name == ^arg(:name))
    end
  end

  attributes do
    uuid_primary_key :id

    # Trimmed and length-capped by `WandererApp.Scout.Presets.save/3`,
    # which is the only supported write path.
    attribute :name, :string do
      allow_nil? false
    end

    # The planner's whole control state, exactly as
    # `ScoutPlannerLive.planner_state/1` serialises it for localStorage.
    attribute :state, :map do
      allow_nil? false
      default %{}
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, WandererApp.Api.User do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :uniq_user_preset, [:user_id, :name]
  end
end
