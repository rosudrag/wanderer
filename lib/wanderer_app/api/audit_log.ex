defmodule WandererApp.Api.AuditLog do
  @moduledoc """
  Append-only — no update or destroy action exists. Every grant/revoke/
  state-change/disable/transfer mutation in the identity system calls
  `WandererApp.Identity.Audit.log!/1` instead of creating a row here
  directly. See docs/chewy/corp-suite-plan.md §2.8.5.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("audit_logs_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)

    define(:by_target_user,
      action: :by_target_user,
      args: [:target_user_id]
    )

    define(:by_actor,
      action: :by_actor,
      args: [:actor_user_id]
    )
  end

  actions do
    default_accept [:actor_user_id, :target_user_id, :action, :details]

    defaults [:create, :read]

    read :by_target_user do
      argument :target_user_id, :uuid, allow_nil?: false
      filter expr(target_user_id == ^arg(:target_user_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :by_actor do
      argument :actor_user_id, :uuid, allow_nil?: false
      filter expr(actor_user_id == ^arg(:actor_user_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  attributes do
    uuid_primary_key :id

    # Open-vocabulary atom — :role_grant, :role_revoke, :state_change,
    # :group_add, :group_remove, :main_character_change,
    # :character_transfer_detected, :account_disabled,
    # :account_reactivated, :gdpr_deletion, ...
    attribute :action, :atom do
      allow_nil? false
    end

    attribute :details, :map do
      default %{}
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    # nil = system-initiated (e.g. a detected ownership transfer has no
    # human actor).
    belongs_to :actor_user, WandererApp.Api.User do
      attribute_writable? true
    end

    belongs_to :target_user, WandererApp.Api.User do
      attribute_writable? true
      allow_nil? false
    end
  end
end
