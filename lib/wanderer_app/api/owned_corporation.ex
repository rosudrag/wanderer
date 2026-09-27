defmodule WandererApp.Api.OwnedCorporation do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("owned_corporations_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update, action: :update)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)
    define(:by_corporation_id, get_by: [:eve_corporation_id], action: :read)
  end

  actions do
    default_accept [
      :eve_corporation_id,
      :name,
      :ticker,
      :alliance_id,
      :alliance_name,
      :director_character_id,
      :enabled
    ]

    defaults [:create, :read, :destroy]

    update :update do
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :eve_corporation_id, :integer do
      allow_nil? false
    end

    attribute :name, :string do
      allow_nil? false
    end

    attribute :ticker, :string
    attribute :alliance_id, :integer
    attribute :alliance_name, :string

    attribute :enabled, :boolean do
      default false
      allow_nil? true
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    # The character whose director-scoped token feeds every corp-suite
    # poller for this corp — explicitly re-pointable via an admin action,
    # unlike the existing corp-wallet feature's hardcoded env var
    # (WandererApp.Env.corp_wallet_eve_id/0). See
    # docs/chewy/corp-suite-plan.md §2.6.
    belongs_to :director_character, WandererApp.Api.Character do
      attribute_writable? true
    end
  end

  identities do
    identity :uniq_corporation_id, [:eve_corporation_id]
  end
end
