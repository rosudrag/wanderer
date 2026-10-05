defmodule WandererAppWeb.ScoutRefreshLiveTest do
  @moduledoc """
  The `/scout/refresh` page RENDERS, and `/scout` links to it.

  Both halves shipped broken and neither was caught by `mix compile`:
  the template guarded an empty state with `@stops == [] and @origin_id`,
  and `@origin_id` is an integer or nil, never a boolean -- HEEx raised
  `BadBooleanError` on first render, so the page a reader reaches from
  the Refresh tab was a 500 every time. A compile-clean LiveView that
  cannot mount is exactly what this file exists to catch.

  Both pages are asserted together because they are each other's only
  navigation: the sidebar holds ONE scout icon (`AGENTS.md`), so a
  missing tab on either side strands the other.

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

  test "the queue page mounts with no origin chosen", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/scout/refresh")

    assert html =~ "Scout Refresh Queue"
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

    {:ok, live, _html} = live(conn, ~p"/scout/refresh")

    html = render_click(live, "select_origin", %{"id" => "990300001", "name" => "Refreshalpha"})

    assert html =~ "Set route"
    assert html =~ "Refresh Reader"
    assert html =~ "990300002"
  end

  test "each scout page links to the other", %{conn: conn} do
    {:ok, _live, intel_html} = live(conn, ~p"/scout")
    assert intel_html =~ ~s(href="/scout/refresh")

    {:ok, _live, refresh_html} = live(conn, ~p"/scout/refresh")
    assert refresh_html =~ ~s(href="/scout")
  end

  test "with the planner flag off the page is not reachable", %{conn: conn} do
    Application.put_env(:wanderer_app, :scout_planner_enabled, false)

    assert {:error, {:live_redirect, %{to: "/scout"}}} = live(conn, ~p"/scout/refresh")

    {:ok, _live, intel_html} = live(conn, ~p"/scout")
    refute intel_html =~ ~s(href="/scout/refresh")
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

      :ok
    end

    test "switching to sweep mode and setting a scope renders start suggestions", %{
      conn: conn
    } do
      {:ok, live, _html} = live(conn, ~p"/scout/refresh")

      render_click(live, "switch_mode", %{"mode" => "sweep"})
      html = render_change(live, "update_sweep_regions", %{"regions" => "1"})

      assert html =~ "Start points"
      assert html =~ "Sweeplive1" or html =~ "Sweeplive6"
    end

    test "k=3 renders three per-part pilot pickers and an Assign all button", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/scout/refresh")

      render_click(live, "switch_mode", %{"mode" => "sweep"})
      render_change(live, "update_sweep_regions", %{"regions" => "1"})
      html = render_change(live, "update_sweep_k", %{"k" => "3"})

      assert html =~ "scout-sweep-part-0-character"
      assert html =~ "scout-sweep-part-1-character"
      assert html =~ "scout-sweep-part-2-character"
      assert html =~ "Assign all"
    end
  end

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
