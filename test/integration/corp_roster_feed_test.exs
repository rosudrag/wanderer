defmodule WandererApp.Sync.Feeds.CorpRosterFeedTest do
  @moduledoc """
  Proves `WandererApp.Sync.Feeds.CorpRosterFeed`'s four contract
  properties against a fake membertracking payload -- never a live ESI
  call. `upsert/2` is exercised directly for the idempotence and
  departure properties (both are pure functions of the payload,
  scheduler-independent); the `:not_modified` property is exercised
  through `WandererApp.Sync.Scheduler.sync_now!/3` with the real feed
  module wrapped by a fetch-stub that returns canned fixtures instead of
  calling ESI, so the real `Scheduler` <-> real `upsert/2` integration is
  what's under test, not a hand-rolled substitute for it.

  **Design choice, stated explicitly:** a member absent from a later
  payload is marked `status: :departed` (`departed_at` set), never
  deleted. This preserves `start_date`/join history and makes "who left
  and when" answerable from the same table later, at the cost of the
  table growing unboundedly with departures -- an accepted tradeoff
  since `retention_days/0` is `:infinity` for this feed (a roster is
  identity data, not a time-series log; see
  docs/chewy/corp-suite-plan.md §9 Phase 3 / `seat-parity.md` §8.4).

  See docs/chewy/corp-suite-plan.md §9 Phase 3.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{CorpRosterSnapshot, OwnedCorporation}
  alias WandererApp.Sync.Feeds.CorpRosterFeed
  alias WandererApp.Sync.Scheduler

  @corp_id 91_555_000

  setup do
    Application.put_env(:wanderer_app, :corp_roster_enabled, true)
    {:ok, _pid} = FakeEsi.start_link()
    Application.put_env(:wanderer_app, :esi_module, FakeEsi)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :corp_roster_enabled)
      Application.delete_env(:wanderer_app, :sync_feeds)
      Application.delete_env(:wanderer_app, :esi_module)
    end)

    {:ok, corp} =
      OwnedCorporation.create(%{
        eve_corporation_id: @corp_id,
        name: "Roster Feed Test Corp",
        enabled: true
      })

    %{corp: corp}
  end

  defp member_row(character_id, opts \\ []) do
    %{
      "character_id" => character_id,
      "start_date" => "2024-01-01T00:00:00Z",
      "logon_date" => Keyword.get(opts, :logon_date, "2026-09-20T12:00:00Z"),
      "logoff_date" => "2026-09-20T18:00:00Z",
      "location_id" => 60_003_760,
      "ship_type_id" => 670,
      "base_id" => 60_003_760
    }
  end

  test "one CorpRosterSnapshot row per character_id; re-running the same payload does not duplicate",
       %{corp: corp} do
    rows = [member_row(2_100_000_001), member_row(2_100_000_002)]

    :ok = CorpRosterFeed.upsert(corp, rows)

    {:ok, after_first} = CorpRosterSnapshot.by_corporation(@corp_id, authorize?: false)
    assert length(after_first) == 2

    :ok = CorpRosterFeed.upsert(corp, rows)

    {:ok, after_second} = CorpRosterSnapshot.by_corporation(@corp_id, authorize?: false)
    assert length(after_second) == 2

    assert Enum.map(after_first, & &1.id) |> Enum.sort() ==
             Enum.map(after_second, & &1.id) |> Enum.sort()
  end

  test "a character absent from a later payload is marked :departed, not deleted", %{corp: corp} do
    :ok = CorpRosterFeed.upsert(corp, [member_row(2_100_000_011), member_row(2_100_000_012)])

    {:ok, active_before} = CorpRosterSnapshot.active_by_corporation(@corp_id, authorize?: false)
    assert length(active_before) == 2

    :ok = CorpRosterFeed.upsert(corp, [member_row(2_100_000_011)])

    {:ok, all_rows} = CorpRosterSnapshot.by_corporation(@corp_id, authorize?: false)
    assert length(all_rows) == 2, "the departed member's row must still exist, not be deleted"

    departed = Enum.find(all_rows, &(&1.character_id == "2100000012"))
    assert departed.status == :departed
    refute is_nil(departed.departed_at)

    still_active = Enum.find(all_rows, &(&1.character_id == "2100000011"))
    assert still_active.status == :active
  end

  test ":not_modified leaves every existing row untouched and never calls upsert/2", %{
    corp: corp
  } do
    :ok = CorpRosterFeed.upsert(corp, [member_row(2_100_000_021)])
    {:ok, [before_row]} = CorpRosterSnapshot.by_corporation(@corp_id, authorize?: false)

    {:ok, _pid} = FakeCorpRosterFetch.start_link()
    FakeCorpRosterFetch.set_response(:not_modified)

    run = Scheduler.sync_now!(FakeCorpRosterFetch, corp, to_string(@corp_id))

    assert run.status == :ok
    refute is_nil(run.last_checked_at)
    assert is_nil(run.last_success_at)

    {:ok, [after_row]} = CorpRosterSnapshot.by_corporation(@corp_id, authorize?: false)
    assert after_row.id == before_row.id
    assert after_row.updated_at == before_row.updated_at
  end

  test "WANDERER_CORP_ROSTER off: the feed is not registered and a poll writes nothing", %{
    corp: corp
  } do
    {:ok, _} =
      OwnedCorporation.update(corp, %{director_character_id: nil}, authorize?: false)

    Application.put_env(:wanderer_app, :corp_roster_enabled, false)
    Application.delete_env(:wanderer_app, :sync_feeds)

    refute Enum.any?(WandererApp.Sync.Registry.feeds(), fn {mod, _resolver} ->
             mod == CorpRosterFeed
           end)

    :ok = Scheduler.run_tick()

    assert {:ok, []} = CorpRosterSnapshot.by_corporation(@corp_id, authorize?: false)
  end

  test "resolve_names/1 issues exactly one batch resolution call for an N-member payload, not N",
       %{corp: corp} do
    rows = Enum.map(1..10, &member_row(2_100_002_000 + &1))

    :ok = CorpRosterFeed.upsert(corp, rows)

    assert FakeEsi.call_count() == 1

    {:ok, saved} = CorpRosterSnapshot.by_corporation(@corp_id, authorize?: false)
    assert length(saved) == 10
    assert Enum.all?(saved, &(&1.name != nil))
  end

  test "a corp with enabled: false is not scheduled even with a director token configured", %{
    corp: corp
  } do
    {:ok, director} =
      WandererApp.Api.Character.create(
        %{eve_id: "2100003000", name: "Test Director Character"},
        authorize?: false
      )

    {:ok, corp} =
      OwnedCorporation.update(corp, %{director_character_id: director.id, enabled: true},
        authorize?: false
      )

    assert Enum.any?(CorpRosterFeed.scopes(), fn {scoped_corp, _key} ->
             scoped_corp.id == corp.id
           end),
           "sanity check: with enabled: true and a director set, the corp IS scheduled"

    {:ok, corp} = OwnedCorporation.update(corp, %{enabled: false}, authorize?: false)

    refute Enum.any?(CorpRosterFeed.scopes(), fn {scoped_corp, _key} ->
             scoped_corp.id == corp.id
           end)
  end
end

defmodule FakeCorpRosterFetch do
  @moduledoc """
  Delegates every callback to the real `WandererApp.Sync.Feeds.
  CorpRosterFeed` except `fetch/2`, which returns a canned fixture
  instead of calling ESI -- lets
  `test/integration/corp_roster_feed_test.exs` drive the real
  `WandererApp.Sync.Scheduler` <-> real `CorpRosterFeed.upsert/2`
  integration for the `:not_modified` property without a live ESI call.
  """

  @behaviour WandererApp.Sync.Feed

  alias WandererApp.Sync.Feeds.CorpRosterFeed

  @impl true
  defdelegate cadence_seconds(scope), to: CorpRosterFeed
  @impl true
  defdelegate token_holder(scope), to: CorpRosterFeed
  @impl true
  defdelegate upsert(scope, data), to: CorpRosterFeed
  @impl true
  defdelegate retention_days(), to: CorpRosterFeed
  @impl true
  defdelegate purge_stale(scope), to: CorpRosterFeed

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> :not_modified end, name: __MODULE__)
  def set_response(response), do: Agent.update(__MODULE__, fn _ -> response end)

  @impl true
  def fetch(_scope, _etag) do
    unless Process.whereis(__MODULE__), do: start_link()
    Agent.get(__MODULE__, & &1)
  end
end

defmodule FakeEsi do
  @moduledoc """
  Counting stub for `WandererApp.Esi.resolve_universe_names/1` --
  injected via the `:esi_module` application env
  (`WandererApp.CachedInfo.get_character_names/2`'s test-injection
  seam, the same idiom `WandererApp.Sync.Registry.feeds/0` already
  uses) so `test/integration/corp_roster_feed_test.exs` can assert "one
  call for N IDs" against a real call count instead of timing, and so
  every test in that file resolving names never touches live ESI.
  """

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
  def call_count, do: Agent.get(__MODULE__, & &1)

  def resolve_universe_names(ids) when is_list(ids) do
    Agent.update(__MODULE__, &(&1 + 1))

    results =
      Enum.map(ids, fn id ->
        %{"id" => id, "category" => "character", "name" => "Character #{id}"}
      end)

    {:ok, results}
  end
end
