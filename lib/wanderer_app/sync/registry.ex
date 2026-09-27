defmodule WandererApp.Sync.Registry do
  @moduledoc """
  Chewy-owned, append-only list of registered `WandererApp.Sync.Feed`
  modules. Every later phase that adds a sync feed adds **one line** to
  `@feeds` here — zero edits to `application.ex` or
  `WandererApp.Sync.Scheduler`. See docs/chewy/corp-suite-plan.md §3.3.

  Phase 2 ships this file with an empty list on purpose — no feed exists
  yet (the first is Phase 3's corp roster feed). `WandererApp.Sync.
  Scheduler` must be correct with zero registered feeds (a no-op, per
  the Phase 2 acceptance criteria), which this empty list proves by
  construction rather than by a special case in the scheduler.

  Each entry is `{feed_module, scope_resolver}`, where `scope_resolver`
  is a zero-arg function returning `[{scope :: term(), scope_key ::
  String.t()}]` — the scopes currently due for that feed, each paired
  with the string key `WandererApp.Api.SyncRun` stores it under. Calling
  the resolver fresh every tick (rather than caching it) means scope
  membership changes (a corp added/removed from `owned_corporations_v1`,
  say) are picked up automatically, no restart required.
  """

  @feeds []

  @doc """
  Returns the registered feeds. Overridable via the `:sync_feeds`
  application env for tests exercising `WandererApp.Sync.Scheduler`
  against a fake feed without editing this module — production code
  never sets that key, so it always falls through to the compiled
  `@feeds` list above.
  """
  def feeds do
    Application.get_env(:wanderer_app, :sync_feeds, @feeds)
  end
end
