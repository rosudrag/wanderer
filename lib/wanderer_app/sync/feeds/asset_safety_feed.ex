defmodule WandererApp.Sync.Feeds.AssetSafetyFeed do
  @moduledoc """
  CHEWY PATCH: polls `GET /characters/{id}/notifications/` for every
  character that has consented to `esi-characters.read_notifications.v1`
  and turns `StructureItemsMovedToSafety` into `/scout`'s loot trigger.

  See `WandererApp.Scout.AssetSafety` for the mechanic, the parse and
  the reads, and `docs/chewy/scout-intel.md` for how it is rendered.

  ## One scope per character, not one per corp

  Unlike `WandererApp.Sync.Feeds.CorpRosterFeed`, whose single director
  token answers for a whole corp, this notification is delivered to the
  individual pilot who owned the item — there is no corp-wide read of
  it. So the scope IS a character, and the scheduler's per-scope
  `WandererApp.Api.SyncRun` row gives each one its own ETag, its own
  backoff and its own `:stalled` verdict, which is exactly the
  granularity a revoked consent needs.

  `scopes/0` filters on the stored `scopes` string rather than polling
  everyone and letting ESI sort it out: EVE SSO only ever grants what
  was requested, so every character who logged in before this feature
  existed holds a valid token that 403s on this one endpoint. Polling
  them would spend ESI's error budget, every cadence, forever.

  ## Cadence: 60s, and the floor is CCP's, not ours

  The endpoint is ESI-cached for **600s**, so the freshest answer that
  can exist is already up to ten minutes old. Our poll interval adds to
  that, and only to that: at a 600s cadence the worst case was 600s of
  CCP cache plus 600s of waiting for our own tick — **twenty minutes**
  between a hull coming out of the ground and this app knowing.

  At 60s the worst case is ~11 minutes and the average halves, because
  we catch the cache rollover within a minute of it happening. Going
  below 60s buys almost nothing: the remaining latency is CCP's cache,
  which no polling rate can shorten.

  The extra requests are nearly free and deliberately so. Every poll
  threads the ETag, so nine out of ten are `304 Not Modified` — which
  returns no body and, per `docs/chewy/seat-parity.md` §6.1, does NOT
  count against ESI's error limit. One request per consented character
  per minute is well inside courtesy limits, and
  `WandererApp.Esi.RateLimitGate` still stops the scheduler dead if ESI
  ever answers 420/429.

  This is the one feed worth spending requests on: it is the only
  signal in the app that reports a loose hull at the instant it comes
  loose, and a hull is loot only until somebody else finds it.

  ## Retention

  90 days. A trigger is history after `AssetSafety.horizon_days/0`, but
  the row costs nothing and the drill-down question ("when did that
  Fortizar come out?") is asked weeks later.
  """

  @behaviour WandererApp.Sync.Feed

  require Logger

  alias WandererApp.Api.{Character, ScoutAssetSafety}
  alias WandererApp.Esi
  alias WandererApp.Scout.AssetSafety

  # 60s, not the endpoint's 600s cache: see the moduledoc. The extra
  # polls are 304s, which carry no body and no error-limit cost.
  @cadence_seconds 60
  @retention_days 90

  @doc """
  `WandererApp.Sync.Registry`'s scope resolver: the characters whose
  stored token actually carries the notifications scope.

  Re-read on every tick, so consenting a character starts polling it
  within one tick with no restart, and deleting one stops it.
  """
  @spec scopes() :: [{Character.t(), String.t()}]
  def scopes do
    AssetSafety.watching_characters()
    |> Enum.map(&{&1, to_string(&1.eve_id)})
  end

  @impl true
  def cadence_seconds(_character), do: @cadence_seconds

  @impl true
  def token_holder(%Character{id: id}) do
    # Re-read rather than trusting the struct the resolver captured: a
    # tick may be minutes old by the time it dispatches, and
    # `api_client.ex`'s refresh path rewrites `access_token` on the row.
    case Character.by_id(id, authorize?: false) do
      {:ok, character} -> {:character, character}
      _not_found -> {:error, :character_gone}
    end
  end

  def token_holder(_scope), do: {:error, :not_a_character}

  @impl true
  def fetch(%Character{} = scope, etag) do
    case token_holder(scope) do
      {:character, character} ->
        Esi.get_character_notifications(character.eve_id,
          access_token: character.access_token,
          character_id: character.id,
          etag: etag
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def upsert(%Character{} = scope, notifications) when is_list(notifications) do
    character =
      case token_holder(scope) do
        {:character, character} -> character
        _gone -> scope
      end

    case AssetSafety.store(notifications, character) do
      0 ->
        :ok

      stored ->
        Logger.info(
          "[Scout.AssetSafety] #{stored} new asset-safety trigger(s) from #{character.name}"
        )

        # The sidebar badge counts these, and any open /scout is showing
        # the board. Same two moves every other scout ingest path makes.
        WandererApp.Scout.Alerts.invalidate()

        Phoenix.PubSub.broadcast(
          WandererApp.PubSub,
          "scout_intel",
          {:scout_intel_ingested, :structures}
        )

        :ok
    end
  end

  # ESI answered with something that is not a notification list. Nothing
  # to store, and the scheduler already recorded the fetch.
  def upsert(_scope, _data), do: :ok

  @impl true
  def retention_days, do: @retention_days

  @impl true
  def purge_stale(%Character{eve_id: eve_id}) do
    before =
      DateTime.utc_now() |> DateTime.add(-@retention_days, :day) |> DateTime.truncate(:second)

    with {:ok, eve_id} <- integer(eve_id),
         {:ok, rows} <- ScoutAssetSafety.stale(eve_id, before, authorize?: false) do
      Enum.each(rows, &ScoutAssetSafety.destroy(&1, authorize?: false))
    end

    :ok
  end

  def purge_stale(_scope), do: :ok

  defp integer(value) when is_integer(value), do: {:ok, value}

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> {:ok, number}
      :error -> :error
    end
  end

  defp integer(_value), do: :error
end
