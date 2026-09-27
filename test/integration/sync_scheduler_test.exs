defmodule WandererApp.Sync.SchedulerTest do
  @moduledoc """
  Proves `WandererApp.Sync.Scheduler`'s contract with a fake in-test feed
  module rather than a real ESI call -- every later ESI-backed phase
  depends on these four properties holding:

    * a freshly-registered scope is due and gets `fetch/2` called on the
      first tick, producing a `WandererApp.Api.SyncRun` heartbeat row;
    * `:not_modified` bumps `last_checked_at` without ever calling
      `upsert/2`;
    * an error increments `consecutive_failures` and pushes `next_run_at`
      into the future (exponential backoff);
    * 5 consecutive failures flips `status` to `:stalled` -- the signal
      that makes a silently-403ing feed visible.

  See docs/chewy/corp-suite-plan.md §3.3, §9 Phase 2.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.SyncRun
  alias WandererApp.Sync.Scheduler

  defmodule FakeFeedState do
    @moduledoc false
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{fetch_count: 0, upsert_count: 0, mode: :ok} end, name: __MODULE__)
    end

    def set_mode(mode), do: Agent.update(__MODULE__, &Map.put(&1, :mode, mode))

    def bump_fetch,
      do: Agent.update(__MODULE__, &Map.update!(&1, :fetch_count, fn n -> n + 1 end))

    def bump_upsert,
      do: Agent.update(__MODULE__, &Map.update!(&1, :upsert_count, fn n -> n + 1 end))

    def get, do: Agent.get(__MODULE__, & &1)
  end

  defmodule FakeFeed do
    @moduledoc false
    @behaviour WandererApp.Sync.Feed

    @impl true
    def cadence_seconds(_scope), do: 5

    @impl true
    def token_holder(_scope), do: {:character, nil}

    @impl true
    def fetch(_scope, _etag) do
      FakeFeedState.bump_fetch()

      case FakeFeedState.get().mode do
        :ok -> {:ok, %{}, "etag-1"}
        :not_modified -> :not_modified
        :error -> {:error, :boom}
      end
    end

    @impl true
    def upsert(_scope, _data) do
      FakeFeedState.bump_upsert()
      :ok
    end

    @impl true
    def retention_days, do: :infinity

    @impl true
    def purge_stale(_scope), do: :ok
  end

  setup do
    {:ok, _pid} = FakeFeedState.start_link()

    on_exit(fn -> Application.delete_env(:wanderer_app, :sync_feeds) end)

    :ok
  end

  test "due-scheduling: a fresh scope is fetched on the first tick and gets a heartbeat row" do
    Application.put_env(:wanderer_app, :sync_feeds, [
      {FakeFeed, fn -> [{:scope_a, "scope_a"}] end}
    ])

    :ok = Scheduler.run_tick()

    assert FakeFeedState.get().fetch_count == 1

    assert {:ok, run} =
             SyncRun.by_feed_and_scope(inspect(FakeFeed), "scope_a", authorize?: false)

    assert run.status == :ok
    assert run.consecutive_failures == 0
    refute is_nil(run.last_success_at)
    assert run.etag == "etag-1"
  end

  test "a due scope already at its cadence-advanced next_run_at is not re-fetched on the next tick" do
    Application.put_env(:wanderer_app, :sync_feeds, [
      {FakeFeed, fn -> [{:scope_a2, "scope_a2"}] end}
    ])

    :ok = Scheduler.run_tick()
    assert FakeFeedState.get().fetch_count == 1

    :ok = Scheduler.run_tick()
    assert FakeFeedState.get().fetch_count == 1
  end

  test ":not_modified bumps last_checked_at without ever calling upsert/2" do
    FakeFeedState.set_mode(:not_modified)

    run = Scheduler.sync_now!(FakeFeed, :scope_b, "scope_b")

    assert FakeFeedState.get().upsert_count == 0
    refute is_nil(run.last_checked_at)
    assert is_nil(run.last_success_at)
    assert run.status == :ok
    assert run.consecutive_failures == 0
  end

  test "an error increments consecutive_failures and pushes next_run_at into the future" do
    FakeFeedState.set_mode(:error)
    before_dispatch = DateTime.utc_now()

    run = Scheduler.sync_now!(FakeFeed, :scope_c, "scope_c")

    assert run.consecutive_failures == 1
    assert run.status == :ok
    assert run.last_error =~ "boom"
    refute is_nil(run.next_run_at)
    assert DateTime.compare(run.next_run_at, before_dispatch) == :gt
  end

  test "5 consecutive failures flips status to :stalled" do
    FakeFeedState.set_mode(:error)

    run =
      Enum.reduce(1..5, nil, fn _i, _acc ->
        Scheduler.sync_now!(FakeFeed, :scope_d, "scope_d")
      end)

    assert run.consecutive_failures == 5
    assert run.status == :stalled
    assert FakeFeedState.get().fetch_count == 5
  end

  test "a success after failures resets consecutive_failures to 0 and status to :ok" do
    FakeFeedState.set_mode(:error)
    run = Scheduler.sync_now!(FakeFeed, :scope_e, "scope_e")
    assert run.consecutive_failures == 1

    FakeFeedState.set_mode(:ok)
    run = Scheduler.sync_now!(FakeFeed, :scope_e, "scope_e")

    assert run.consecutive_failures == 0
    assert run.status == :ok
    refute is_nil(run.last_success_at)
  end
end
