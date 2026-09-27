defmodule WandererApp.Sync.Registry do
  @moduledoc """
  Chewy-owned, append-only list of registered `WandererApp.Sync.Feed`
  modules. Every later phase that adds a sync feed adds **one line** to
  `default_feeds/0` here — zero edits to `application.ex` or
  `WandererApp.Sync.Scheduler`. See docs/chewy/corp-suite-plan.md §3.3.

  Phase 2 shipped this file with an empty `default_feeds/0` on purpose
  — `WandererApp.Sync.Scheduler` had to be correct with zero registered
  feeds (a no-op, per the Phase 2 acceptance criteria), which the empty
  list proved by construction rather than by a special case in the
  scheduler. Phase 3 adds the first real entry,
  `WandererApp.Sync.Feeds.CorpRosterFeed` — still gated on its own
  `WANDERER_CORP_ROSTER` flag, so `WANDERER_SYNC_FRAMEWORK` alone being
  on does not register it.

  Each entry is `{feed_module, scope_resolver}`, where `scope_resolver`
  is a zero-arg function returning `[{scope :: term(), scope_key ::
  String.t()}]` — the scopes currently due for that feed, each paired
  with the string key `WandererApp.Api.SyncRun` stores it under. Calling
  the resolver fresh every tick (rather than caching it) means scope
  membership changes (a corp added/removed from `owned_corporations_v1`,
  say) are picked up automatically, no restart required.
  """

  @doc """
  Returns the registered feeds. Overridable via the `:sync_feeds`
  application env for tests exercising `WandererApp.Sync.Scheduler`
  against a fake feed without editing this module — production code
  never sets that key, so it always falls through to `default_feeds/0`
  below.
  """
  def feeds do
    Application.get_env(:wanderer_app, :sync_feeds, default_feeds())
  end

  # Each phase's line here is gated on that phase's own flag -- "every
  # downstream feature also checks its own flag" (docs/chewy/
  # corp-suite-plan.md §9 Phase 0), evaluated at call time since
  # WandererApp.Env reads runtime config that isn't available at
  # @feeds-as-a-module-attribute compile time.
  defp default_feeds do
    [
      corp_roster_feed()
    ]
    |> List.flatten()
  end

  defp corp_roster_feed do
    if WandererApp.Env.corp_roster_enabled?() do
      [{WandererApp.Sync.Feeds.CorpRosterFeed, &WandererApp.Sync.Feeds.CorpRosterFeed.scopes/0}]
    else
      []
    end
  end
end
