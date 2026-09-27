defmodule WandererApp.Api.StandingGrant do
  @moduledoc """
  Manual `:blue` allow-list row, keyed by any combination of character/
  corp/alliance EVE ID. No ESI standings sync in Phase 0 — an admin adds
  rows by hand. Carries no `GroupPermission` by construction, so the
  main-character-only rule that guards `:member` state (see
  `WandererApp.Identity.StateEngine`) is deliberately not enforced here.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("standing_grants_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)

    define(:matching,
      action: :matching,
      args: [:character_id, :corporation_id, :alliance_id]
    )
  end

  actions do
    default_accept [:eve_character_id, :eve_corporation_id, :eve_alliance_id, :state]

    defaults [:create, :read, :destroy]

    read :matching do
      argument :character_id, :integer, allow_nil?: true
      argument :corporation_id, :integer, allow_nil?: true
      argument :alliance_id, :integer, allow_nil?: true

      filter expr(
               (not is_nil(^arg(:character_id)) and eve_character_id == ^arg(:character_id)) or
                 (not is_nil(^arg(:corporation_id)) and
                    eve_corporation_id == ^arg(:corporation_id)) or
                 (not is_nil(^arg(:alliance_id)) and eve_alliance_id == ^arg(:alliance_id))
             )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :eve_character_id, :integer
    attribute :eve_corporation_id, :integer
    attribute :eve_alliance_id, :integer

    attribute :state, :atom do
      constraints one_of: [:blue]
      default :blue
      allow_nil? false
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
