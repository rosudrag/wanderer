defmodule WandererApp.Api.GroupMapAccessGrant do
  @moduledoc """
  A `Group` -> `AccessList` -> `role` mapping. `WandererApp.Identity.MapAclSync`
  materializes/retracts `WandererApp.Api.AccessListMember` rows from these
  through its existing, unmodified `:create`/`:update_role`/`:destroy`
  actions — this resource and `WandererApp.Api.GroupMapSyncedMember` are the
  only new tables Phase 1 adds. See docs/chewy/corp-suite-plan.md §2.5,
  §9 Phase 1.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("group_map_access_grants_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update_role, action: :update_role)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)

    define(:by_group,
      action: :by_group,
      args: [:group_id]
    )
  end

  actions do
    default_accept [:group_id, :access_list_id, :role]

    defaults [:read]

    update :update_role do
      accept [:role]
      require_atomic? false
      change WandererApp.Identity.Changes.SyncMapAccessGrant
    end

    create :create do
      accept [:group_id, :access_list_id, :role]
      primary? true
      change WandererApp.Identity.Changes.SyncMapAccessGrant
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change WandererApp.Identity.Changes.SyncMapAccessGrant
    end

    read :by_group do
      argument :group_id, :uuid, allow_nil?: false
      filter expr(group_id == ^arg(:group_id))
    end
  end

  attributes do
    uuid_primary_key :id

    # Mirrors WandererApp.Api.AccessListMember.role exactly
    # (lib/wanderer_app/api/access_list_member.ex:135-150) so sync never
    # needs to translate between two role vocabularies.
    attribute :role, :atom do
      default "viewer"
      allow_nil? true

      constraints(
        one_of: [
          :admin,
          :manager,
          :member,
          :viewer,
          :blocked
        ]
      )
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :group, WandererApp.Api.Group do
      attribute_writable? true
      allow_nil? false
    end

    belongs_to :access_list, WandererApp.Api.AccessList do
      attribute_writable? true
      allow_nil? false
    end
  end

  postgres do
    references do
      reference :group, on_delete: :delete
      reference :access_list, on_delete: :delete
    end
  end

  identities do
    identity :uniq_group_access_list, [:group_id, :access_list_id]
  end
end
