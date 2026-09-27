defmodule WandererApp.Sync.Retention do
  @moduledoc """
  Retention is framework-level, not a per-feature afterthought: every
  registered feed's `retention_days/0` + `purge_stale/1` callbacks are
  compile-time enforced by `WandererApp.Sync.Feed` -- there is no code
  path to ship a new sync feed without declaring a retention policy. One
  daily Quantum job (appended to `config/runtime.exs`'s existing job
  list, gated on `WANDERER_SYNC_FRAMEWORK`) calls `purge_all/0`, which
  walks `WandererApp.Sync.Registry` and calls each feed's own purge for
  every scope its resolver currently returns. See
  docs/chewy/corp-suite-plan.md §3.5.
  """

  require Logger

  alias WandererApp.Sync.Registry

  def purge_all do
    Registry.feeds()
    |> Enum.each(fn {feed_module, scope_resolver} ->
      purge_feed(feed_module, scope_resolver)
    end)
  end

  defp purge_feed(feed_module, scope_resolver) do
    case feed_module.retention_days() do
      :infinity ->
        :ok

      _days ->
        scope_resolver.()
        |> Enum.each(fn {scope, _scope_key} -> purge_scope(feed_module, scope) end)
    end
  end

  defp purge_scope(feed_module, scope) do
    :ok = feed_module.purge_stale(scope)
  rescue
    error ->
      Logger.error(
        "[Sync.Retention] #{inspect(feed_module)} scope=#{inspect(scope)} purge_stale/1 raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end
end
