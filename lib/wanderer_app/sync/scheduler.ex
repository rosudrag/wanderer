defmodule WandererApp.Sync.Scheduler do
  @moduledoc """
  One supervised GenServer, ticking every 30s, dispatching every
  registered-feed x due-scope pair as a supervised `Task` — the "one
  supervised thing, many registered workers" shape already proven at
  scale by `WandererApp.Character.TrackerPool`/`TrackerManager`, instead
  of one bespoke poller GenServer per feature. See
  docs/chewy/corp-suite-plan.md §3.2/§3.3.

  Per dispatch: check the global rate-limit gate
  (`WandererApp.Esi.RateLimitGate`), call `fetch/2` with the scope's
  last-known ETag, then update the scope's `WandererApp.Api.SyncRun`
  heartbeat row:

    * `:not_modified` -> bump `last_checked_at` only, no `upsert/2` call,
      no write load.
    * `{:ok, data, etag}` -> call `upsert/2`, then record
      `last_success_at`/new `etag`/`consecutive_failures: 0`/`status: :ok`/
      `next_run_at` advanced by `cadence_seconds/1`.
    * `{:error, reason}` -> increment `consecutive_failures`, apply
      capped exponential backoff to `next_run_at`, and flip `status` to
      `:stalled` once `consecutive_failures` reaches 5 -- the signal that
      makes a silently-403ing feed visible instead of invisible.
  """

  use GenServer

  require Logger

  alias WandererApp.Api.SyncRun
  alias WandererApp.Esi.RateLimitGate
  alias WandererApp.Sync.Registry

  @tick_interval_ms :timer.seconds(30)
  @max_backoff_seconds 3600
  @stall_threshold 5

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_tick(0)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    run_tick()
    schedule_tick(@tick_interval_ms)
    {:noreply, state}
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  @doc """
  Runs one full scheduling pass synchronously: every registered feed's
  scope resolver is called fresh, due (or never-run) scopes are
  dispatched as supervised tasks, and this function returns only once
  every dispatched task has finished (or timed out). Called by the
  GenServer's own 30s timer, and directly by tests that need a
  deterministic pass instead of waiting on that interval.
  """
  def run_tick do
    {:ok, sup} = Task.Supervisor.start_link()

    work_items =
      Registry.feeds()
      |> Enum.flat_map(fn {feed_module, scope_resolver} ->
        scope_resolver.() |> Enum.map(&{feed_module, &1})
      end)

    try do
      Task.Supervisor.async_stream_nolink(
        sup,
        work_items,
        fn {feed_module, {scope, scope_key}} ->
          maybe_dispatch(feed_module, scope, scope_key)
        end,
        max_concurrency: 5,
        timeout: :timer.seconds(30),
        on_timeout: :kill_task
      )
      |> Enum.each(fn
        {:ok, _result} -> :ok
        {:exit, reason} -> Logger.error("[Sync.Scheduler] task crashed: #{inspect(reason)}")
      end)
    after
      Supervisor.stop(sup)
    end

    :ok
  end

  defp maybe_dispatch(feed_module, scope, scope_key) do
    feed_name = feed_name(feed_module)
    sync_run = fetch_or_create_run!(feed_name, scope_key)

    cond do
      sync_run.status == :disabled -> :skipped
      not due?(sync_run) -> :skipped
      RateLimitGate.blocked?() -> :skipped
      true -> dispatch!(feed_module, scope, sync_run)
    end
  end

  @doc """
  Runs `feed_module`'s fetch/upsert cycle for one scope immediately,
  bypassing the due/rate-limit checks `run_tick/0` applies -- the same
  dispatch primitive a future "force sync now" admin action would call,
  and what a deterministic test uses to exercise dispatch outcomes
  (`:not_modified`, error/backoff, stall) without waiting on real
  cadence/backoff wall-clock time.
  """
  def sync_now!(feed_module, scope, scope_key) do
    feed_name = feed_name(feed_module)
    sync_run = fetch_or_create_run!(feed_name, scope_key)
    dispatch!(feed_module, scope, sync_run)
  end

  defp dispatch!(feed_module, scope, sync_run) do
    case feed_module.fetch(scope, sync_run.etag) do
      :not_modified ->
        update_run!(sync_run, %{last_checked_at: now()})

      {:ok, data, etag} ->
        :ok = feed_module.upsert(scope, data)
        cadence = feed_module.cadence_seconds(scope)

        update_run!(sync_run, %{
          last_checked_at: now(),
          last_success_at: now(),
          etag: etag,
          consecutive_failures: 0,
          status: :ok,
          next_run_at: DateTime.add(now(), cadence, :second),
          last_error: nil,
          last_error_at: nil
        })

      {:error, reason} ->
        failures = sync_run.consecutive_failures + 1
        cadence = feed_module.cadence_seconds(scope)
        backoff = backoff_seconds(cadence, failures)
        status = if failures >= @stall_threshold, do: :stalled, else: :ok

        update_run!(sync_run, %{
          last_checked_at: now(),
          consecutive_failures: failures,
          last_error: inspect(reason),
          last_error_at: now(),
          next_run_at: DateTime.add(now(), backoff, :second),
          status: status
        })
    end
  rescue
    error ->
      Logger.error(
        "[Sync.Scheduler] #{inspect(feed_module)} scope=#{inspect(scope)} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end

  defp due?(%{next_run_at: nil}), do: true
  defp due?(%{next_run_at: next_run_at}), do: DateTime.compare(next_run_at, now()) != :gt

  defp backoff_seconds(cadence, failures) do
    (cadence * :math.pow(2, failures - 1))
    |> trunc()
    |> min(@max_backoff_seconds)
  end

  defp fetch_or_create_run!(feed_name, scope_key) do
    case SyncRun.by_feed_and_scope(feed_name, scope_key, authorize?: false) do
      {:ok, run} ->
        run

      {:error, _not_found} ->
        {:ok, run} =
          SyncRun.create(%{feed_name: feed_name, scope_key: scope_key, status: :ok},
            authorize?: false
          )

        run
    end
  end

  defp update_run!(sync_run, attrs) do
    {:ok, updated} = SyncRun.update(sync_run, attrs, authorize?: false)
    updated
  end

  defp feed_name(feed_module), do: inspect(feed_module)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
