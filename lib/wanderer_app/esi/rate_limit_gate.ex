defmodule WandererApp.Esi.RateLimitGate do
  @moduledoc """
  Subscribes to the ESI client's existing
  `[:wanderer_app, :esi, :rate_limited]` telemetry event (emitted at
  `lib/wanderer_app/esi/api_client.ex:362-393,395-423` on every 420/429
  response, unconditionally, regardless of whether this feature flag is
  on) via `:telemetry.attach/4`. Zero edit to `api_client.ex` for
  backoff specifically — the signal already exists and is already
  public. State lives in the existing `:esi_auth_cache` Cachex worker
  under a namespaced key, not a new Cachex child.

  `WandererApp.Sync.Scheduler` checks `blocked?/0` before dispatching
  each due scope; `attach!/0` is only ever called from
  `WandererApp.Application`'s `maybe_start_sync_scheduler/1` when
  `WANDERER_SYNC_FRAMEWORK` is on, so the handler is never attached (and
  this module has zero effect on the rest of the app, including the
  telemetry event's other consumers, if any) when the flag is off. See
  docs/chewy/corp-suite-plan.md §3.4.
  """

  require Logger

  @handler_id "wanderer-sync-rate-limit-gate"
  @cache_key "sync:rate_limit:blocked_until_ms"
  @cache :esi_auth_cache

  @doc "Idempotent -- safe to call more than once (e.g. across test cases in the same BEAM)."
  def attach! do
    case :telemetry.attach(
           @handler_id,
           [:wanderer_app, :esi, :rate_limited],
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  def detach!, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event([:wanderer_app, :esi, :rate_limited], measurements, _metadata, _config) do
    reset_ms = measurements |> Map.get(:reset_duration, 0) |> max(0)
    blocked_until_ms = System.system_time(:millisecond) + reset_ms
    ttl = :timer.seconds(max(div(reset_ms, 1000) + 1, 1))

    Cachex.put(@cache, @cache_key, blocked_until_ms, ttl: ttl)
  end

  @doc "True while the most recent rate-limited response's reset window hasn't elapsed yet."
  def blocked? do
    case Cachex.get(@cache, @cache_key) do
      {:ok, blocked_until_ms} when is_integer(blocked_until_ms) ->
        System.system_time(:millisecond) < blocked_until_ms

      _not_blocked ->
        false
    end
  end
end
