defmodule WandererApp.Api.CorpRosterSnapshot do
  @moduledoc """
  A **live current-state table** -- one row per `character_id`, upserted
  on every poll, never appended daily. `WandererApp.Sync.Feeds.
  CorpRosterFeed` is the only writer. Includes every in-game member,
  including characters who have never logged into this app (no
  `WandererApp.Api.Character` row) -- the explicit gap a
  per-app-login-only roster would leave open. See
  docs/chewy/corp-suite-plan.md §9 Phase 3, `docs/chewy/seat-parity.md`
  §8.4 (retention: query live, don't store history).
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("corp_roster_snapshots_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update, action: :update)
    define(:destroy, action: :destroy)

    define(:by_character_id, get_by: [:character_id], action: :read)

    define(:by_corporation,
      action: :by_corporation,
      args: [:corporation_id]
    )

    define(:active_by_corporation,
      action: :active_by_corporation,
      args: [:corporation_id]
    )
  end

  actions do
    default_accept [
      :character_id,
      :name,
      :corporation_id,
      :start_date,
      :logon_at,
      :logoff_at,
      :location_id,
      :location_name,
      :ship_type_id,
      :ship_type_name,
      :base_id,
      :status,
      :departed_at,
      :last_seen_in_roster_at
    ]

    defaults [:create, :read, :destroy]

    update :update do
      require_atomic? false
    end

    read :by_corporation do
      argument :corporation_id, :integer, allow_nil?: false
      filter expr(corporation_id == ^arg(:corporation_id))
    end

    read :active_by_corporation do
      argument :corporation_id, :integer, allow_nil?: false
      filter expr(corporation_id == ^arg(:corporation_id) and status == :active)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :character_id, :string do
      allow_nil? false
    end

    # Nil until resolved via WandererApp.CachedInfo.get_character_name/1
    # -- distinguishes "not resolved yet" from "resolution failed",
    # neither of which should block the roster row from existing.
    attribute :name, :string

    attribute :corporation_id, :integer do
      allow_nil? false
    end

    attribute :start_date, :utc_datetime
    attribute :logon_at, :utc_datetime
    attribute :logoff_at, :utc_datetime
    attribute :location_id, :integer
    attribute :location_name, :string
    attribute :ship_type_id, :integer
    attribute :ship_type_name, :string
    attribute :base_id, :integer

    attribute :status, :atom do
      constraints one_of: [:active, :departed]
      default :active
      allow_nil? false
    end

    attribute :departed_at, :utc_datetime

    attribute :last_seen_in_roster_at, :utc_datetime do
      allow_nil? false
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :uniq_character_id, [:character_id]
  end
end
