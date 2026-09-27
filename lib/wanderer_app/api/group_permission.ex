defmodule WandererApp.Api.GroupPermission do
  @moduledoc """
  One row per permission a group carries. `permission` is an open-vocabulary
  atom (`:srp_approve`, `:fleet_fc`, `:recruiter_review`, ...) — a new
  permission is a new row, never a schema migration. See
  docs/chewy/corp-suite-plan.md §2.3.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("group_permissions_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)
    define(:by_group_and_permission, get_by: [:group_id, :permission], action: :read)

    define(:by_group,
      action: :by_group,
      args: [:group_id]
    )
  end

  actions do
    default_accept [:group_id, :permission]

    defaults [:create, :read, :destroy]

    read :by_group do
      argument :group_id, :uuid, allow_nil?: false
      filter expr(group_id == ^arg(:group_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :permission, :atom do
      allow_nil? false
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :group, WandererApp.Api.Group do
      attribute_writable? true
      allow_nil? false
    end
  end

  identities do
    identity :uniq_group_permission, [:group_id, :permission]
  end
end
