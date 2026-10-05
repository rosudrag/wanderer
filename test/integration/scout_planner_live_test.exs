defmodule WandererAppWeb.ScoutPlannerLiveTest do
  @moduledoc """
  The `/scout/planner` page RENDERS, and `/scout` links to it.

  Both halves shipped broken and neither was caught by `mix compile`:
  the template guarded an empty state with `@stops == [] and @origin_id`,
  and `@origin_id` is an integer or nil, never a boolean -- HEEx raised
  `BadBooleanError` on first render, so the page a reader reaches from
  the Planner tab was a 500 every time. A compile-clean LiveView that
  cannot mount is exactly what this file exists to catch.

  Both pages are asserted together because they are each other's only
  navigation: the sidebar holds ONE scout icon (`AGENTS.md`), so a
  missing tab on either side strands the other.

  Every read on this page runs in a task now (`start_async/3`), so a
  result is asserted after `render_async/1`, not off the event's own
  return value.

  See `docs/design/wanderer-scout-planner.md` section 8.
  """

  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WandererAppWeb.Factory

  setup do
    Application.put_env(:wanderer_app, :scout_intel_enabled, true)
    Application.put_env(:wanderer_app, :scout_planner_enabled, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :scout_intel_enabled)
      Application.delete_env(:wanderer_app, :scout_planner_enabled)
      Application.delete_env(:wanderer_app, :bootstrap_admin_character)
    end)

    user = insert(:user)
    character = insert(:character, %{user_id: user.id, name: "Refresh Reader"})
    Application.put_env(:wanderer_app, :bootstrap_admin_character, character.name)

    %{
      conn: build_conn() |> Plug.Test.init_test_session(%{"user_id" => user.id}),
      character: character
    }
  end

  test "the planner page mounts with no origin chosen", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/scout/planner")

    assert html =~ "Scout Planner"
    assert html =~ "Search for an origin system to begin."
  end

  # The controls that make a route happen only exist once there IS a
  # route: picking the pilot and pushing it are meaningless with no plan,
  # and the page shipped once with neither control at all.
  test "choosing an origin reveals the pilot picker and the Set route button", %{conn: conn} do
    WandererApp.Cache.delete("scout:planner:adjacency")
    put_system(990_300_001, "Refreshalpha")
    put_system(990_300_002, "Refreshbravo")
    put_jump(990_300_001, 990_300_002)

    {:ok, live, _html} = live(conn, ~p"/scout/planner")

    render_click(live, "select_origin", %{"id" => "990300001", "name" => "Refreshalpha"})
    html = render_async(live)

    assert html =~ "Set route"
    assert html =~ "Refresh Reader"
    assert html =~ "990300002"
  end

  test "each scout page links to the other", %{conn: conn} do
    {:ok, _live, intel_html} = live(conn, ~p"/scout")
    assert intel_html =~ ~s(href="/scout/planner")

    {:ok, _live, planner_html} = live(conn, ~p"/scout/planner")
    assert planner_html =~ ~s(href="/scout")
  end

  test "with the planner flag off the page is not reachable", %{conn: conn} do
    Application.put_env(:wanderer_app, :scout_planner_enabled, false)

    assert {:error, {:live_redirect, %{to: "/scout"}}} = live(conn, ~p"/scout/planner")

    {:ok, _live, intel_html} = live(conn, ~p"/scout")
    refute intel_html =~ ~s(href="/scout/planner")
  end

  # The scope control is a NAME search over `WandererApp.Scout.Regions`,
  # not the `ids, comma-separated` box it replaced: an operator who does
  # not know Domain is 10000043 could not scope anything at all.
  test "a region is searched by name and added as a chip", %{conn: conn} do
    reset_region_cache()
    put_system(990_400_001, "Pickeralpha")

    {:ok, live, _html} = live(conn, ~p"/scout/planner")

    html = render_change(live, "search_regions", %{"scope" => "rank", "q" => "refresh"})
    assert html =~ "Refresh Region"

    html = render_click(live, "add_region", %{"scope" => "rank", "id" => "1"})
    assert html =~ "scout-planner-regions-chip-1"
  end

  test "an unknown region id is refused", %{conn: conn} do
    reset_region_cache()
    put_system(990_400_002, "Pickerbravo")

    {:ok, live, _html} = live(conn, ~p"/scout/planner")

    html = render_click(live, "add_region", %{"scope" => "rank", "id" => "424242"})
    refute html =~ "scout-planner-regions-chip-424242"
  end

  # CHEWY PATCH (scout sweep): the SAME page's second mode -- design doc
  # `docs/design/wanderer-scout-region-sweeps.md` sections 3-5. A
  # straight 6-system chain, one region, so `Split.split/3` has enough
  # nodes to actually produce 3 parts.
  describe "sweep mode" do
    setup do
      WandererApp.Cache.delete("scout:planner:adjacency")

      for {id, name} <- [
            {990_500_001, "Sweeplive1"},
            {990_500_002, "Sweeplive2"},
            {990_500_003, "Sweeplive3"},
            {990_500_004, "Sweeplive4"},
            {990_500_005, "Sweeplive5"},
            {990_500_006, "Sweeplive6"}
          ] do
        put_system(id, name)
      end

      for {a, b} <- [
            {990_500_001, 990_500_002},
            {990_500_002, 990_500_003},
            {990_500_003, 990_500_004},
            {990_500_004, 990_500_005},
            {990_500_005, 990_500_006}
          ] do
        put_jump(a, b)
      end

      reset_region_cache()

      :ok
    end

    # `empty/1` renders a `<tr>`. This message used to be one, dropped
    # straight into a `<div>`, so the browser discarded it and sweep mode
    # opened as a blank page with no instruction on it at all.
    test "sweep mode with no scope says what to do", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/scout/planner")

      html = render_click(live, "switch_mode", %{"mode" => "sweep"})

      assert html =~ "scout-sweep-no-scope"
      assert html =~ "Pick a scope above"
      refute html =~ ~s(<tr>\n      <td colspan="1")
    end

    test "switching to sweep mode and setting a scope renders start suggestions", %{
      conn: conn
    } do
      {:ok, live, _html} = live(conn, ~p"/scout/planner")

      render_click(live, "switch_mode", %{"mode" => "sweep"})
      render_click(live, "add_region", %{"scope" => "sweep", "id" => "1"})
      html = sweep_html(live)

      assert html =~ "Start points"
      assert html =~ "Sweeplive1" or html =~ "Sweeplive6"
    end

    test "k=3 renders three per-part pilot pickers and an Assign all button", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/scout/planner")

      render_click(live, "switch_mode", %{"mode" => "sweep"})
      render_click(live, "add_region", %{"scope" => "sweep", "id" => "1"})
      sweep_html(live)

      render_change(live, "update_sweep_k", %{"k" => "3"})
      html = sweep_html(live)

      assert html =~ "scout-sweep-part-0-character"
      assert html =~ "scout-sweep-part-1-character"
      assert html =~ "scout-sweep-part-2-character"
      assert html =~ "Assign all"

      # The split panel sits above the sweep table now, and the control
      # itself reports the result -- without that, a changed `k` on a
      # 189-row sweep looks like it did nothing at all.
      assert html =~ "parts, longest"
      assert String.contains?(html, "scout-sweep-split-panel")

      assert :binary.match(html, "scout-sweep-split-panel") <
               :binary.match(html, "scout-sweep-table-panel")
    end
  end

  # CHEWY PATCH (scout planner security focus): "I would like to scout
  # Metropolis, specifically the lowsec systems". `Sweep.sweep/1` has
  # taken a `security:` band list since it shipped, and the sweep
  # toolbar rendered chips for it -- but `space_chip/1` hardcoded
  # `phx-click="toggle_space"`, the RANK mode's event, so every click in
  # sweep mode mutated the rank filter, the chip never even changed
  # colour, and `handle_event("toggle_sweep_space", ...)` was
  # unreachable code. The whole feature was one attribute away from
  # working and looked like it did nothing.
  describe "sweep security bands" do
    setup do
      WandererApp.Cache.delete("scout:planner:adjacency")

      # Alternating chain: odd = highsec, even = lowsec, so a band
      # filter has to drop interleaved systems rather than a suffix.
      for {id, name, class, sec} <- [
            {990_600_001, "Bandhs1", 7, "0.9"},
            {990_600_002, "Bandls2", 8, "0.3"},
            {990_600_003, "Bandhs3", 7, "0.8"},
            {990_600_004, "Bandls4", 8, "0.2"}
          ] do
        put_system(id, name, 2, "Band Region", class, sec)
      end

      for {a, b} <- [
            {990_600_001, 990_600_002},
            {990_600_002, 990_600_003},
            {990_600_003, 990_600_004}
          ] do
        put_jump(a, b)
      end

      reset_region_cache()

      :ok
    end

    test "unticking High in sweep mode drops highsec stops and keeps the rest", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/scout/planner")

      render_click(live, "switch_mode", %{"mode" => "sweep"})
      render_click(live, "add_region", %{"scope" => "sweep", "id" => "2"})
      html = sweep_html(live)

      assert html =~ "Bandhs1"
      assert html =~ "Bandls2"

      live |> element("#scout-sweep-space-hs") |> render_click()
      filtered = sweep_html(live)

      refute filtered =~ "Bandhs1"
      refute filtered =~ "Bandhs3"
      assert filtered =~ "Bandls2"
      assert filtered =~ "Bandls4"

      # The route still runs over the full graph: the two dropped
      # highsec systems sit BETWEEN the two kept lowsec ones, so the
      # jump count has to account for driving through them.
      assert filtered =~ "Total jumps"

      # And the toolbar says which space the numbers are about, beside
      # the chips rather than below a 189-row table.
      assert filtered =~ "scout-sweep-security-note"

      # The precise signature of the bug: the sweep chip must not have
      # written the RANK mode's filter, which is what one shared
      # `phx-click="toggle_space"` did.
      rank_html = render_click(live, "switch_mode", %{"mode" => "rank"})
      assert rank_html =~ ~r/id="scout-planner-space-hs"[^>]*aria-pressed="true"/
    end

    test "the region heat table counts only the ticked bands", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/scout/planner")

      render_click(live, "switch_mode", %{"mode" => "sweep"})
      html = sweep_html(live)

      assert html =~ "Band Region"
      assert heat_systems(html, 2) == 4

      live |> element("#scout-sweep-space-hs") |> render_click()
      filtered = sweep_html(live)

      assert heat_systems(filtered, 2) == 2
    end
  end

  # CHEWY PATCH: what `Set route` is allowed to claim. The push reported
  # success unconditionally -- `WandererApp.Character.set_autopilot_waypoint/3`
  # discards ESI's answer -- so "Route set on X: N waypoints" appeared
  # for a refused token and for a pilot who was not logged in, which is
  # exactly how "I set a route for Molden Heath and never got it in
  # game" looked from this page. The outcome now renders BESIDE the
  # button and stays there, so these assertions read the page, not a
  # toast.
  describe "what Set route reports" do
    setup %{character: character} do
      {:ok, _pid} = FakeWaypointEsi.start_link()
      Application.put_env(:wanderer_app, :esi_module, FakeWaypointEsi)

      {:ok, character} =
        WandererApp.Api.Character.update(character, %{
          access_token: "test-access-token",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
        })

      Cachex.del(:character_cache, character.id)
      WandererApp.Cache.delete("scout:planner:adjacency")

      put_system(990_600_001, "Outcomealpha")
      put_system(990_600_002, "Outcomebravo")
      put_jump(990_600_001, 990_600_002)

      on_exit(fn -> Application.delete_env(:wanderer_app, :esi_module) end)

      :ok
    end

    test "an ESI refusal is named on the page, not reported as a route", %{conn: conn} do
      FakeWaypointEsi.script(online: true, waypoints: {:error, :forbidden})

      html = push_plan(conn)

      assert html =~ "ESI refused the first"
      assert html =~ "403"
      refute html =~ "Route set on"
    end

    test "a pilot whose client is not running is reported as such", %{conn: conn} do
      FakeWaypointEsi.script(online: false, waypoints: {:ok, ""})

      html = push_plan(conn)

      assert html =~ "not logged in"
      refute html =~ "Route set on"
    end

    test "a route EVE accepted says so, with the count", %{conn: conn} do
      FakeWaypointEsi.script(online: true, waypoints: {:ok, ""})

      html = push_plan(conn)

      assert html =~ "Route set on"
      assert html =~ "waypoint"
    end
  end

  defp push_plan(conn) do
    {:ok, live, _html} = live(conn, ~p"/scout/planner")

    render_click(live, "select_origin", %{"id" => "990600001", "name" => "Outcomealpha"})
    render_async(live)

    render_click(live, "set_route", %{})
  end

  # A sweep's own task starts the split task from `handle_async/3`, so
  # one `render_async/1` can return between the two; the second waits for
  # whatever the first one started.
  defp sweep_html(live) do
    render_async(live)
    render_async(live)
  end

  # `Regions.all/0` is cached for a day, and these tests insert the rows
  # it reads -- a cache populated by an earlier test would hide them.
  defp reset_region_cache, do: WandererApp.Cache.delete("scout:planner:regions")

  defp put_system(solar_system_id, name),
    do: put_system(solar_system_id, name, 1, "Refresh Region", 7, "0.9")

  defp put_system(solar_system_id, name, region_id, region_name, system_class, security) do
    {:ok, _system} =
      WandererApp.Api.MapSolarSystem
      |> Ash.Changeset.for_create(:create, %{
        solar_system_id: solar_system_id,
        solar_system_name: name,
        solar_system_name_lc: String.downcase(name),
        region_id: region_id,
        region_name: region_name,
        constellation_id: 1,
        constellation_name: "Refresh Constellation",
        system_class: system_class,
        security: security
      })
      |> Ash.create(authorize?: false)
  end

  # The `Systems` cell of one region-heat row -- the first
  # `tabular-nums` cell after that row's id.
  defp heat_systems(html, region_id) do
    [_match, count] =
      Regex.run(
        ~r/id="scout-heat-#{region_id}".*?<td class="text-right tabular-nums">\s*(\d+)/s,
        html
      )

    String.to_integer(count)
  end

  defp put_jump(from_id, to_id) do
    for {from, to} <- [{from_id, to_id}, {to_id, from_id}] do
      {:ok, _jump} =
        WandererApp.Api.MapSolarSystemJumps
        |> Ash.Changeset.for_create(:create, %{
          from_solar_system_id: from,
          to_solar_system_id: to
        })
        |> Ash.create(authorize?: false)
    end
  end
end
