defmodule WandererApp.Api.Group do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("groups_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update, action: :update)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)
  end

  actions do
    default_accept [:name, :description, :kind]

    defaults [:create, :read, :destroy]

    update :update do
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :description, :string

    # UI hint only — actual behavior is driven by whether GroupAutoRule
    # rows exist for this group, not by this atom.
    attribute :kind, :atom do
      constraints one_of: [:auto, :manual, :hybrid]
      default :manual
      allow_nil? false
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :memberships, WandererApp.Api.GroupMembership
    has_many :auto_rules, WandererApp.Api.GroupAutoRule
    has_many :permissions, WandererApp.Api.GroupPermission
  end
end
