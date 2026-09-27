defmodule WandererApp.Sync.Feed do
  @moduledoc """
  Behaviour every ESI sync feed implements — one shared scheduler
  (`WandererApp.Sync.Scheduler`), cadence timer, ETag cache, 420-backoff,
  and heartbeat instead of a bespoke GenServer per feature. See
  docs/chewy/corp-suite-plan.md §3.

  `scope :: term()` is whatever a feed needs to identify one unit of work
  — a corporation ID, a character struct, a map ID. `WandererApp.Sync.
  Registry`'s `scope_resolver` for a feed decides what scopes exist and
  pairs each with a `WandererApp.Api.SyncRun`-storable string key; this
  behaviour only ever receives the scope term itself, never the string
  key.
  """

  @doc "Seconds between polls of one scope. May vary by scope (e.g. a director-token feed polled more often than a member one)."
  @callback cadence_seconds(scope :: term()) :: pos_integer()

  @doc "Which token this scope's fetch/2 call authenticates with."
  @callback token_holder(scope :: term()) ::
              {:character, WandererApp.Api.Character.t()} | {:corp_director, term()}

  @doc """
  Fetches one scope's data, threading the last-known ETag (nil on first
  ever fetch, or after `purge_stale/1` clears it) through the request's
  `If-None-Match` header via `api_client.ex`'s `do_get/4` `:etag` opt.
  """
  @callback fetch(scope :: term(), etag :: String.t() | nil) ::
              {:ok, data :: term(), etag :: String.t()} | :not_modified | {:error, term()}

  @doc "Persists freshly-fetched data. Never called on :not_modified."
  @callback upsert(scope :: term(), data :: term()) :: :ok

  @doc "How long fetched data is kept once no longer refreshed. `:infinity` means purge_stale/1 is a no-op."
  @callback retention_days() :: pos_integer() | :infinity

  @doc "Purges data older than retention_days/0 for one scope. Called daily by WandererApp.Sync.Retention.purge_all/0."
  @callback purge_stale(scope :: term()) :: :ok
end
