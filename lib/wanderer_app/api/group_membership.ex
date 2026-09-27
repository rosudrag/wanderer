defmodule WandererApp.Api.GroupMembership do
  @moduledoc """
  `source: :manual_grant` is rejected outright when the target `Group` owns
  an `:esi_director_role` `GroupAutoRule` — director membership is always
  ESI-derived, never a manually-editable row. See
  docs/chewy/corp-suite-plan.md §2.3.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("group_memberships_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update, action: :update)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)
    define(:by_group_and_user, get_by: [:group_id, :user_id], action: :read)

    define(:by_group,
      action: :by_group,
      args: [:group_id]
    )

    define(:by_user,
      action: :by_user,
      args: [:user_id]
    )

    define(:active_by_user,
      action: :active_by_user,
      args: [:user_id]
    )
  end

  actions do
    default_accept [:group_id, :user_id, :source, :status, :granted_by_user_id]

    defaults [:create, :read, :destroy]

    update :update do
      require_atomic? false
      accept [:status]
    end

    read :by_group do
      argument :group_id, :uuid, allow_nil?: false
      filter expr(group_id == ^arg(:group_id))
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :active_by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and status == :active)
    end
  end

  validations do
    validate fn changeset, _context ->
      with :manual_grant <- Ash.Changeset.get_attribute(changeset, :source),
           group_id when not is_nil(group_id) <-
             Ash.Changeset.get_attribute(changeset, :group_id),
           {:ok, rules} <- WandererApp.Api.GroupAutoRule.by_group(group_id),
           true <- Enum.any?(rules, &(&1.match_kind == :esi_director_role)) do
        {:error,
         field: :source,
         message:
           "director membership is ESI-derived only; manual grants are not allowed on a " <>
             "group with an :esi_director_role auto-rule"}
      else
        _ -> :ok
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source, :atom do
      constraints one_of: [:auto_rule, :manual_grant, :self_request]
      allow_nil? false
    end

    attribute :status, :atom do
      constraints one_of: [:active, :pending]
      default :active
      allow_nil? false
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :group, WandererApp.Api.Group do
      attribute_writable? true
      allow_nil? false
    end

    belongs_to :user, WandererApp.Api.User do
      attribute_writable? true
      allow_nil? false
    end

    # Audit trail: which director granted a manual/self-requested
    # membership. Unused for :auto_rule-sourced rows.
    belongs_to :granted_by_user, WandererApp.Api.User do
      attribute_writable? true
    end
  end

  identities do
    identity :uniq_group_user, [:group_id, :user_id]
  end
end
