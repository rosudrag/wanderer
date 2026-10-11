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
        :ok ->
          {:ok, %{}, "etag-1"}

        :not_modified ->
          :not_modified

        :error ->
          {:error, :boom}

        # What `api_client.ex` returns on a 420/429 -- a THREE-tuple,
        # headers included. Shape copied from a live ESI 429 on
        # `/characters/{id}/notifications/`, 2026-10-11.
        :rate_limited ->
          {:error, :error_limited,
           %{
             "retry-after" => ["34"],
             "x-ratelimit-group" => ["char-notification"],
             "x-ratelimit-limit" => ["15/15m"],
             "x-ratelimit-remaining" => ["0"]
           }}

        :unexpected ->
          {:ok, %{}}
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
    # CHEWY PATCH: and it reschedules. Leaving `next_run_at` in the
    # past made `due?/1` true on every 30s tick, so a feed whose
    # endpoint is ESI-cached (600s) was re-dispatched twenty times per
    # intended poll, invisibly.
    assert DateTime.compare(run.next_run_at, DateTime.utc_now()) == :gt
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

  # CHEWY PATCH regression, 2026-10-11: a rate-limited fetch used to
  # raise CaseClauseError out of `dispatch!/3`, which logged and left
  # the heartbeat row untouched -- so `next_run_at` stayed in the past
  # and the scope was re-dispatched every 30s, keeping it rate-limited.
  # AssetSafetyFeed sat in that loop for five hours and never read the
  # notification it exists for.
  test "a 429 backs off instead of raising, and never leaves next_run_at in the past" do
    FakeFeedState.set_mode(:rate_limited)
    before_dispatch = DateTime.utc_now()

    run = Scheduler.sync_now!(FakeFeed, :scope_rl, "scope_rl")

    assert run.consecutive_failures == 1
    assert run.last_error =~ "rate limited"
    assert run.last_error =~ "char-notification"
    assert run.last_error =~ "15/15m"
    # retry-after 34s, floored at the feed's 5s cadence.
    assert DateTime.diff(run.next_run_at, before_dispatch) >= 34
  end

  test "an unrecognised fetch result is an error, not a crash loop" do
    FakeFeedState.set_mode(:unexpected)

    run = Scheduler.sync_now!(FakeFeed, :scope_weird, "scope_weird")

    assert run.consecutive_failures == 1
    assert run.last_error =~ "unexpected fetch result"
    assert FakeFeedState.get().upsert_count == 0
    assert DateTime.compare(run.next_run_at, DateTime.utc_now()) == :gt
  end
end
