defmodule WandererApp.Api.GroupMapSyncedMember do
  @moduledoc """
  Shadow/ownership row: records that a specific
  `WandererApp.Api.AccessListMember` row was created by
  `WandererApp.Identity.MapAclSync` for a specific
  `WandererApp.Api.GroupMapAccessGrant`, so sync can tell "a row I created"
  from "a row an admin hand-added" and only ever touch its own rows on
  removal. See docs/chewy/corp-suite-plan.md §2.5, §9 Phase 1.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("group_map_synced_members_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)

    define(:by_access_list_member,
      get_by: [:access_list_member_id],
      action: :read
    )

    define(:by_grant,
      action: :by_grant,
      args: [:group_map_access_grant_id]
    )
  end

  actions do
    default_accept [:group_map_access_grant_id, :access_list_member_id]

    defaults [:create, :read, :destroy]

    read :by_grant do
      argument :group_map_access_grant_id, :uuid, allow_nil?: false
      filter expr(group_map_access_grant_id == ^arg(:group_map_access_grant_id))
    end
  end

  attributes do
    uuid_primary_key :id

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :group_map_access_grant, WandererApp.Api.GroupMapAccessGrant do
      attribute_writable? true
      allow_nil? false
    end

    belongs_to :access_list_member, WandererApp.Api.AccessListMember do
      attribute_writable? true
      allow_nil? false
    end
  end

  postgres do
    references do
      reference :group_map_access_grant, on_delete: :delete
      reference :access_list_member, on_delete: :delete
    end
  end

  identities do
    identity :uniq_access_list_member, [:access_list_member_id]
  end
end
