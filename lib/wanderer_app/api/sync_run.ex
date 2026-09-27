defmodule WandererApp.Api.SyncRun do
  @moduledoc """
  One row per `(feed_name, scope_key)` pair — the heartbeat/audit table
  `WandererApp.Sync.Scheduler` maintains. `status: :stalled` after 5
  consecutive failures is the signal that makes a silently-403ing feed
  visible instead of invisible. See docs/chewy/corp-suite-plan.md §3.3.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("sync_runs_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:update, action: :update)
    define(:destroy, action: :destroy)

    define(:by_feed_and_scope, get_by: [:feed_name, :scope_key], action: :read)
  end

  actions do
    default_accept [
      :feed_name,
      :scope_key,
      :status,
      :etag,
      :last_checked_at,
      :last_success_at,
      :last_error,
      :last_error_at,
      :consecutive_failures,
      :next_run_at
    ]

    defaults [:create, :read, :destroy]

    update :update do
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :feed_name, :string do
      allow_nil? false
    end

    attribute :scope_key, :string do
      allow_nil? false
    end

    attribute :status, :atom do
      constraints one_of: [:ok, :stalled, :disabled]
      default :ok
      allow_nil? false
    end

    attribute :etag, :string
    attribute :last_checked_at, :utc_datetime
    attribute :last_success_at, :utc_datetime
    attribute :last_error, :string
    attribute :last_error_at, :utc_datetime

    attribute :consecutive_failures, :integer do
      default 0
      allow_nil? false
    end

    attribute :next_run_at, :utc_datetime

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :uniq_feed_scope, [:feed_name, :scope_key]
  end
end
