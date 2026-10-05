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

    %{conn: build_conn() |> Plug.Test.init_test_session(%{"user_id" => user.id})}
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

  defp put_system(solar_system_id, name) do
    {:ok, _system} =
      WandererApp.Api.MapSolarSystem
      |> Ash.Changeset.for_create(:create, %{
        solar_system_id: solar_system_id,
        solar_system_name: name,
        solar_system_name_lc: String.downcase(name),
        region_id: 1,
        region_name: "Refresh Region",
        constellation_id: 1,
        constellation_name: "Refresh Constellation",
        system_class: 7,
        security: "0.9"
      })
      |> Ash.create(authorize?: false)
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
