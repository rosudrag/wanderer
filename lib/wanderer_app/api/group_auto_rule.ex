defmodule WandererApp.Api.GroupAutoRule do
  @moduledoc """
  A group can carry multiple auto-rules (OR'd) — e.g. "Directors" = one
  `:esi_director_role` rule, "All Members" = one `:state` rule matching
  `:member`. `:director` is never a manually-grantable
  `GroupMembership.source` on a group that owns one of these rules — see
  `WandererApp.Api.GroupMembership`'s validation. Evaluated by
  `WandererApp.Identity.StateEngine` on every recompute.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("group_auto_rules_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)

    define(:by_group,
      action: :by_group,
      args: [:group_id]
    )
  end

  actions do
    default_accept [:group_id, :match_kind, :match_value]

    defaults [:create, :read, :destroy]

    read :by_group do
      argument :group_id, :uuid, allow_nil?: false
      filter expr(group_id == ^arg(:group_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :match_kind, :atom do
      constraints one_of: [:state, :corporation_id, :alliance_id, :title, :esi_director_role]
      allow_nil? false
    end

    # The state atom, the corp/alliance ID, or the in-game title as a
    # string. Unused (nil) for :esi_director_role.
    attribute :match_value, :string

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :group, WandererApp.Api.Group do
      attribute_writable? true
      allow_nil? false
    end
  end
end
