defmodule WandererApp.Api.UserIdentity do
  @moduledoc """
  One row per `WandererApp.Api.User`, holding the alliance `state` and the
  self-designated main-character link — kept as a separate resource rather
  than a new attribute on `WandererApp.Api.User` specifically so
  `lib/wanderer_app/api/user.ex` never needs an edit (and its
  `priv/resource_snapshots` never churns on an upstream merge). See
  docs/chewy/corp-suite-plan.md §2.2.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("user_identities_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update, action: :update)
    define(:destroy, action: :destroy)

    define(:by_id, get_by: [:id], action: :read)
    define(:by_user, get_by: [:user_id], action: :read)

    define(:set_main_character, action: :set_main_character)
    define(:set_state, action: :set_state)
    define(:disable, action: :disable)
    define(:reactivate, action: :reactivate)
  end

  actions do
    default_accept [:user_id, :state, :state_computed_at]

    defaults [:create, :read, :destroy]

    update :update do
      require_atomic? false
    end

    update :set_main_character do
      require_atomic? false
      accept [:main_character_id]
    end

    update :set_state do
      require_atomic? false
      accept [:state, :state_computed_at]
    end

    # `disabled_at` set here short-circuits `StateEngine.state_of/1` and
    # every future recompute to `:guest`, ahead of normal computation.
    # See docs/chewy/corp-suite-plan.md §2.8.3.
    update :disable do
      require_atomic? false
      accept [:disabled_at, :disabled_by_user_id, :disabled_reason]
    end

    # Clears the override only — does NOT restore prior manual
    # `GroupMembership` grants. State recomputes from scratch on next call.
    update :reactivate do
      require_atomic? false

      change set_attribute(:disabled_at, nil)
      change set_attribute(:disabled_by_user_id, nil)
      change set_attribute(:disabled_reason, nil)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, :atom do
      constraints one_of: [:member, :blue, :applicant, :guest]
      default :guest
      allow_nil? false
    end

    attribute :state_computed_at, :utc_datetime

    attribute :disabled_at, :utc_datetime
    attribute :disabled_reason, :string

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, WandererApp.Api.User do
      attribute_writable? true
      allow_nil? false
    end

    # nil until the user self-designates on /corp/identity (a later
    # phase's UI) — nullability is load-bearing, not an oversight: a `nil`
    # main computes to :guest unconditionally, regardless of any linked
    # alt's corp/alliance. See docs/chewy/corp-suite-plan.md §2.2.
    belongs_to :main_character, WandererApp.Api.Character do
      attribute_writable? true
    end

    belongs_to :disabled_by_user, WandererApp.Api.User do
      attribute_writable? true
    end
  end

  identities do
    identity :uniq_user, [:user_id]
  end
end
