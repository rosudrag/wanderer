defmodule WandererAppWeb.ScoutPlannerLiveTest do
  @moduledoc """
  The Planner CATEGORY renders, and `/scout` links to it.

  CHEWY PATCH (scout shell): `/scout/planner` no longer routes to a
  standalone `ScoutPlannerLive` -- `WandererAppWeb.ScoutIntelLive` is the
  only routed view under `live_session :scout` now, and the planner is a
  nested child it mounts with `live_render/3` (contract in
  `ScoutPlannerLive`'s moduledoc). Every interaction below therefore goes
  through `live_children/1` to reach that child, not the top-level `view`
  `live/2` returns -- sending an event to the shell would be a no-op,
  since `ScoutIntelLive` owns none of this page's handlers.

  Both halves shipped broken once and neither was caught by `mix
  compile`: the template guarded an empty state with `@stops == [] and
  @origin_id`, and `@origin_id` is an integer or nil, never a boolean --
  HEEx raised `BadBooleanError` on first render, so the page a reader
  reaches from the Planner tab was a 500 every time. A compile-clean
  LiveView that cannot mount is exactly what this file exists to catch.

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
    {:ok, view, html} = live(conn, ~p"/scout/planner")

    # Proves the nested mount actually happened under the id the
    # contract fixes (`scout_intel_live.html.heex`'s `live_render/3`
    # call) -- a typo'd `id` there would silently give this test a
    # DIFFERENT child, or none.
    planner = planner_child(view)
    assert planner
    assert planner.id == "scout-planner-live"

    assert html =~ "Search for an origin system to begin."
  end

  # Every pilot select on this page renders `@characters` in one order,
  # and the account's own order is an insertion order nobody can
  # predict. Picking the wrong row here writes a route to the wrong
  # pilot, so the list is sorted by name.
  test "the pilot select lists characters alphabetically", %{conn: conn, character: character} do
    for name <- ["zulu Scout", "Alpha Scout", "mike Scout"] do
      insert(:character, %{user_id: character.user_id, name: name})
    end

    # The pilot select only exists once there is a route to push, so the
    # origin has to be picked first -- same flow as the test below.
    WandererApp.Cache.delete("scout:planner:adjacency")
    put_system(990_310_001, "Pilotsortalpha")
    put_system(990_310_002, "Pilotsortbravo")
    put_jump(990_310_001, 990_310_002)

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    render_click(planner, "select_origin", %{"id" => "990310001", "name" => "Pilotsortalpha"})
    html = render_async(planner)

    names = ["Alpha Scout", "mike Scout", "Refresh Reader", "zulu Scout"]
    positions = Enum.map(names, &:binary.match(html, &1))

    refute Enum.any?(positions, &(&1 == :nomatch)), "every pilot must render in the select"
    assert positions == Enum.sort(positions), "pilots render out of alphabetical order"
  end

  # The whole reason the planner is a nested child rather than a routed
  # page: switching category is a `push_patch` on the SHELL, so the child
  # is never torn down. A sweep costs seconds to compute, and remounting
  # the planner every time a reader glances at the log would throw it
  # away -- which is exactly what `<.link navigate>` to a separate
  # LiveView used to do.
  test "the planner child survives a trip to another category", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)
    pid = planner.pid

    # State a remount would lose: the mode switch is child state, held
    # nowhere else.
    assert render_click(planner, "switch_mode", %{"mode" => "sweep"}) =~ "scout-sweep-no-scope"

    # Away and back, both as patches on the shell. The pane the shell
    # owns goes `hidden` -- it is still in the DOM, which is the whole
    # trick, so it had better not be VISIBLE under the structures boards.
    structures = render_patch(view, ~p"/scout/structures")
    assert structures =~ ~s(id="scout-planner-pane")
    assert structures =~ ~s(class="hidden")
    same = planner_child(view)
    assert same, "the planner child was unmounted by a category switch"
    assert same.pid == pid, "the planner child was remounted by a category switch"

    render_patch(view, ~p"/scout/planner")

    # Still in sweep mode, with no recompute: the child never re-mounted,
    # so the mode it was left in is the mode it comes back in.
    assert render(planner_child(view)) =~ "scout-sweep-no-scope"
  end

  # SHIPPED BROKEN in 1.103.4-chewy.82, reported as "why does it look so
  # bad?": `WandererAppWeb.live_view/1` gives EVERY LiveView the root
  # page shell's container classes, so the nested child arrived wrapped
  # in `relative h-screen flex overflow-hidden bg-white` -- a white,
  # viewport-tall flex row dropped inside the shell's `<main>`, which
  # squeezed the planner into a column on a white slab and read as
  # missing CSS.
  test "the planner child's container carries none of the root shell's classes", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/scout/planner")

    container = Regex.run(~r/<div id="scout-planner-live"[^>]*>/, html)

    assert container, "the planner child did not render"
    [container] = container

    refute container =~ "h-screen"
    refute container =~ "bg-white"
    refute container =~ "flex"
  end

  # The controls that make a route happen only exist once there IS a
  # route: picking the pilot and pushing it are meaningless with no plan,
  # and the page shipped once with neither control at all.
  test "choosing an origin reveals the pilot picker and the Set route button", %{conn: conn} do
    WandererApp.Cache.delete("scout:planner:adjacency")
    put_system(990_300_001, "Refreshalpha")
    put_system(990_300_002, "Refreshbravo")
    put_jump(990_300_001, 990_300_002)

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    render_click(planner, "select_origin", %{"id" => "990300001", "name" => "Refreshalpha"})
    html = render_async(planner)

    assert html =~ "Set route"
    assert html =~ "Refresh Reader"
    assert html =~ "990300002"
  end

  # The control used to be `max="40"` and the planner clamped to match,
  # so a route could never reach anything further out however many stops
  # were asked for. EVE caps no route; `0` is this page's "no limit".
  test "max jumps 0 ranks past the old 40-jump ceiling", %{conn: conn} do
    WandererApp.Cache.delete("scout:planner:adjacency")

    # A 1-jump chain so the far end sits beyond a deliberately tiny
    # budget: the assertion is about the budget, not about distance.
    put_system(990_310_001, "Budgetalpha")
    put_system(990_310_002, "Budgetbravo")
    put_system(990_310_003, "Budgetcharlie")
    put_jump(990_310_001, 990_310_002)
    put_jump(990_310_002, 990_310_003)

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    render_click(planner, "select_origin", %{"id" => "990310001", "name" => "Budgetalpha"})
    render_async(planner)

    render_change(planner, "update_max_jumps", %{"max_jumps" => "1"})
    capped = render_async(planner)

    assert capped =~ "990310002"
    refute capped =~ "990310003"

    render_change(planner, "update_max_jumps", %{"max_jumps" => "0"})
    unlimited = render_async(planner)

    assert unlimited =~ "990310003"
  end

  test "each scout page links to the other", %{conn: conn} do
    {:ok, _view, intel_html} = live(conn, ~p"/scout")
    assert intel_html =~ ~s(href="/scout/planner")

    {:ok, _view, planner_html} = live(conn, ~p"/scout/planner")
    assert planner_html =~ ~s(href="/scout/structures")
  end

  # CHEWY PATCH (scout shell): the flag redirect itself is
  # `ScoutIntelLive.handle_params/3`'s call now (it owns the URL, so it
  # is the only thing that CAN push_patch away from `/scout/planner`) --
  # this file only has to prove the planner body never reaches the page
  # when the flag is off, not re-assert the exact mechanics of how the
  # shell gets there.
  test "with the planner flag off the planner never mounts, the shell redirects", %{conn: conn} do
    Application.put_env(:wanderer_app, :scout_planner_enabled, false)

    # `live/2` does not follow a redirect raised during the INITIAL
    # connect (mount/handle_params) -- it is the shell's own
    # `handle_params/3` doing this, not this file's concern to re-prove
    # beyond "the planner body is never what landed".
    assert {:error, {:live_redirect, %{to: "/scout/structures"}}} =
             live(conn, ~p"/scout/planner")
  end

  # CHEWY PATCH (scout shell): `ScoutIntelLive` already checks both
  # gates before ever rendering the `live_render/3` that mounts this
  # child -- these two call `ScoutPlannerLive.mount/3` directly, the
  # same call the shell's heex makes, to prove the child refuses on its
  # OWN account and would not have trusted a parent that forgot to ask.
  # No router entry exists for this LiveView any more, so this is the
  # only way to mount it without going through the shell at all.
  describe "the child does not trust its parent for authorization" do
    test "a user without scout access gets a denial notice, not the planner" do
      other_user = insert(:user)

      assert {:ok, socket} =
               WandererAppWeb.ScoutPlannerLive.mount(
                 %{},
                 %{"user_id" => other_user.id},
                 %Phoenix.LiveView.Socket{}
               )

      refute socket.assigns.access?
      assert socket.assigns.denial =~ "do not have access"
    end

    test "the planner flag is re-read here even though the shell already read it", %{
      character: character
    } do
      Application.put_env(:wanderer_app, :scout_planner_enabled, false)

      assert {:ok, socket} =
               WandererAppWeb.ScoutPlannerLive.mount(
                 %{},
                 %{"user_id" => character.user_id},
                 %Phoenix.LiveView.Socket{}
               )

      refute socket.assigns.access?
      assert socket.assigns.denial =~ "not enabled"
    end
  end

  # The scope control is a NAME search over `WandererApp.Scout.Regions`,
  # not the `ids, comma-separated` box it replaced: an operator who does
  # not know Domain is 10000043 could not scope anything at all.
  test "a region is searched by name and added as a chip", %{conn: conn} do
    reset_region_cache()
    put_system(990_400_001, "Pickeralpha")

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    html = render_change(planner, "search_regions", %{"scope" => "rank", "q" => "refresh"})
    assert html =~ "Refresh Region"

    html = render_click(planner, "add_region", %{"scope" => "rank", "id" => "1"})
    assert html =~ "scout-planner-regions-chip-1"
  end

  test "an unknown region id is refused", %{conn: conn} do
    reset_region_cache()
    put_system(990_400_002, "Pickerbravo")

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    html = render_click(planner, "add_region", %{"scope" => "rank", "id" => "424242"})
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
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      html = render_click(planner, "switch_mode", %{"mode" => "sweep"})

      assert html =~ "scout-sweep-no-scope"
      assert html =~ "Pick a scope above"
      refute html =~ ~s(<tr>\n      <td colspan="1")
    end

    # CHEWY PATCH (stable sweeps), reported 2026-10-06: "i am getting
    # completely different 3 way split in delve than we had before ... I
    # need consistent routes". A sweep's membership is normally
    # time-dependent -- a system scouted this morning is dropped as
    # `:fresh` -- so the stop set, the split and its start systems drift
    # between runs over the same region. Stable mode (default) takes the
    # scope exactly as the region and the bands define it.
    test "stable mode keeps a freshly-scouted system as a stop; unticking it drops the system",
         %{conn: conn} do
      {:ok, _row} =
        WandererApp.Api.ScoutSystemCoverage.create(
          %{
            solar_system_id: 990_500_003,
            kind: :sigs,
            observed_at: DateTime.utc_now(),
            source: "test"
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      stable = sweep_html(planner)

      assert stable =~ "Sweeplive3",
             "stable mode must sweep the whole scope, freshness included"

      render_click(planner, "toggle_sweep_stable", %{})
      drifting = sweep_html(planner)

      refute drifting =~ "Sweeplive3",
             "with stable off, a system inside its kind's TTL is not due and must drop out"
    end

    test "switching to sweep mode and setting a scope renders start suggestions", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      html = sweep_html(planner)

      assert html =~ "Start points"
      assert html =~ "Sweeplive1" or html =~ "Sweeplive6"
    end

    test "k=3 renders three per-part pilot pickers and an Assign all button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      sweep_html(planner)

      render_change(planner, "update_sweep_k", %{"k" => "3"})
      html = sweep_html(planner)

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

    # CHEWY PATCH (pinned split starts), asked for 2026-10-07: "could u
    # make the route planner for split also be able to take custom
    # starting position? I would like to keep my chars in same place".
    # The whole feature is invisible unless the pinned system actually
    # becomes that part's first stop, so that is what this asserts --
    # not that a chip rendered.
    test "pinning a part's start routes that part from the pinned system", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      sweep_html(planner)

      render_change(planner, "update_sweep_k", %{"k" => "2"})
      html = sweep_html(planner)

      assert html =~ "scout-sweep-start-slot-0"
      assert html =~ "scout-sweep-start-slot-1"

      # The picker is the rank mode's system search, scoped to a slot.
      matches = render_change(planner, "search_part_start", %{"slot" => "0", "q" => "Sweeplive4"})
      assert matches =~ "Sweeplive4"

      render_click(planner, "select_part_start", %{
        "slot" => "0",
        "id" => "990500004",
        "name" => "Sweeplive4"
      })

      html = sweep_html(planner)
      assert html =~ "pinned"

      parts = :sys.get_state(planner.pid).socket.assigns.sweep_parts
      pinned = Enum.find(parts, & &1.pinned?)

      assert pinned.index == 0
      assert pinned.start == 990_500_004
      assert hd(pinned.order) == 990_500_004
      refute Enum.any?(parts, &(&1.index != 0 and &1.pinned?))

      # Unpinning puts the part back on a seeded start.
      render_click(planner, "clear_part_start", %{"slot" => "0"})
      sweep_html(planner)

      refute :sys.get_state(planner.pid).socket.assigns.sweep_parts |> Enum.any?(& &1.pinned?)
    end

    # CHEWY PATCH (searchable start picker), asked for 2026-10-07: "i
    # need a searchable dropdown to pick starting location". The three
    # suggested buttons are the three CHEAPEST starts, never "where my
    # character is", and a start outside the scope used to be dropped on
    # the floor by `pick_main_route/5` -- the page said it was set and
    # the route opened somewhere else entirely.
    test "a searched start outside the scope is flown from, not listed as a stop", %{conn: conn} do
      # Off-scope: reachable from the chain but in another region, so it
      # is never a sweep candidate.
      put_system(990_500_099, "Sweepliveparked", 2, "Parked Region", 7, "0.9")
      put_jump(990_500_099, 990_500_001)
      reset_region_cache()

      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      sweep_html(planner)

      matches =
        render_change(planner, "search_part_start", %{"slot" => "main", "q" => "Sweepliveparked"})

      assert matches =~ "Sweepliveparked"

      render_click(planner, "select_part_start", %{
        "slot" => "main",
        "id" => "990500099",
        "name" => "Sweepliveparked"
      })

      html = sweep_html(planner)
      assert html =~ "scout-sweep-start-custom"
      assert html =~ "from Sweepliveparked"

      result = :sys.get_state(planner.pid).socket.assigns.sweep_result

      assert result.start == 990_500_099
      stop_ids = Enum.map(result.stops, & &1.solar_system_id)

      refute 990_500_099 in stop_ids
      assert hd(stop_ids) == 990_500_001, "the route must open at the nearest stop to the start"
      assert result.systems == 6
    end
  end

  # CHEWY PATCH (pilot start), asked for 2026-10-09: "need new toggle in
  # scout planner route to be able to take the selected pilot starting
  # position". Every start on this page was a NAME search -- read the
  # system off the game client, type it back in, once per pilot. These
  # assert the START MOVED, not that a checkbox rendered, and that a
  # refusal is said out loud: a start that silently did not move is the
  # exact failure the searchable picker was added to fix.
  describe "starting where the pilot is" do
    setup %{character: character} do
      WandererApp.Cache.delete("scout:planner:adjacency")

      {:ok, _pid} = FakeWaypointEsi.start_link()
      Application.put_env(:wanderer_app, :esi_module, FakeWaypointEsi)

      {:ok, character} =
        WandererApp.Api.Character.update(character, %{
          access_token: "test-access-token",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
        })

      Cachex.del(:character_cache, character.id)

      for {id, name} <- [
            {990_800_001, "Pilotstart1"},
            {990_800_002, "Pilotstart2"},
            {990_800_003, "Pilotstart3"},
            {990_800_004, "Pilotstart4"}
          ] do
        put_system(id, name)
      end

      for {a, b} <- [
            {990_800_001, 990_800_002},
            {990_800_002, 990_800_003},
            {990_800_003, 990_800_004}
          ] do
        put_jump(a, b)
      end

      # Where the pilot is parked: another region, so it is never a
      # sweep candidate and can only appear as the START.
      put_system(990_800_099, "Pilotparked", 2, "Parked Region", 7, "0.9")
      put_jump(990_800_099, 990_800_001)

      reset_region_cache()

      on_exit(fn -> Application.delete_env(:wanderer_app, :esi_module) end)

      :ok
    end

    test "the sweep opens where ESI says the pilot is", %{conn: conn} do
      FakeWaypointEsi.script(location: 990_800_099)

      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      sweep_html(planner)

      render_click(planner, "toggle_pilot_start", %{})
      html = sweep_html(planner)

      assert html =~ "starting in Pilotparked"

      result = :sys.get_state(planner.pid).socket.assigns.sweep_result

      assert result.start == 990_800_099
      refute 990_800_099 in Enum.map(result.stops, & &1.solar_system_id)
    end

    test "every split part is pinned to its own pilot", %{conn: conn, character: character} do
      FakeWaypointEsi.script(location: 990_800_099)

      # The second pilot needs a token of its own: a character this app
      # cannot authenticate as is REPORTED, not silently skipped, which
      # is the next test's job and would mask this one's.
      second = insert(:character, %{user_id: character.user_id, name: "Second Scout"})

      {:ok, second} =
        WandererApp.Api.Character.update(second, %{
          access_token: "test-access-token",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
        })

      Cachex.del(:character_cache, second.id)

      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      sweep_html(planner)

      render_change(planner, "update_sweep_k", %{"k" => "2"})
      sweep_html(planner)

      render_click(planner, "toggle_pilot_start", %{})
      html = sweep_html(planner)

      assert html =~ "2 parts pinned to their pilots"

      starts = :sys.get_state(planner.pid).socket.assigns.sweep_starts

      assert map_size(starts) == 2
      assert Enum.all?(starts, fn {_index, start} -> start.id == 990_800_099 end)
    end

    test "a refused ESI read is reported and moves nothing", %{conn: conn} do
      # Not scripted: the fake answers 403, and this character has no
      # tracked location to fall back on either.
      FakeWaypointEsi.script([])

      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      sweep_html(planner)

      render_click(planner, "toggle_pilot_start", %{})
      html = sweep_html(planner)

      assert html =~ "could not be located"
      assert html =~ "403"
      assert is_nil(:sys.get_state(planner.pid).socket.assigns.sweep_start)
    end

    # The rank mode's origin is the one control nothing ranks without,
    # and it was always typed.
    test "the rank origin follows the pilot, and a manual pick stops it", %{conn: conn} do
      FakeWaypointEsi.script(location: 990_800_099)

      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "toggle_pilot_start", %{})
      html = render_async(planner)

      assert html =~ "starting in Pilotparked"
      assert :sys.get_state(planner.pid).socket.assigns.origin_id == 990_800_099

      # Two sources for one value with neither winning is how a route
      # opens somewhere the page did not say, so a hand-picked origin
      # turns following off.
      render_click(planner, "select_origin", %{"id" => "990800002", "name" => "Pilotstart2"})
      render_async(planner)

      assigns = :sys.get_state(planner.pid).socket.assigns

      assert assigns.origin_id == 990_800_002
      refute assigns.pilot_start?
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
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "2"})
      html = sweep_html(planner)

      assert html =~ "Bandhs1"
      assert html =~ "Bandls2"

      planner |> element("#scout-sweep-space-hs") |> render_click()
      filtered = sweep_html(planner)

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
      rank_html = render_click(planner, "switch_mode", %{"mode" => "rank"})
      assert rank_html =~ ~r/id="scout-planner-space-hs"[^>]*aria-pressed="true"/
    end

    test "the region heat table counts only the ticked bands", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      html = sweep_html(planner)

      assert html =~ "Band Region"
      assert heat_systems(html, 2) == 4

      planner |> element("#scout-sweep-space-hs") |> render_click()
      filtered = sweep_html(planner)

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

  # CHEWY PATCH (target routing): the third mode. Same contract as the
  # two above -- it renders, its controls change the ANSWER and not just
  # the chip state, and the strike-off list is visible enough to explain
  # the route it produced.
  describe "targets mode" do
    setup do
      WandererApp.Cache.delete("scout:planner:adjacency")

      for {id, name} <- [
            {990_700_001, "Targetalpha"},
            {990_700_002, "Targetbravo"},
            {990_700_003, "Targetcharlie"}
          ] do
        put_system(id, name, 3, "Target Region", 7, "0.8")
      end

      put_jump(990_700_001, 990_700_002)
      put_jump(990_700_002, 990_700_003)

      since = DateTime.add(DateTime.utc_now(), -1, :day)
      put_structure(990_700_101, 990_700_001, "Unanchoring", since)
      put_structure(990_700_102, 990_700_002, "Unanchoring", since)
      put_structure(990_700_103, 990_700_003, "NoFuel", nil)

      reset_region_cache()

      :ok
    end

    test "lists the systems a finding names, and ignoring one takes it off the route", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "targets"})
      html = render_async(planner)

      assert html =~ "Target route"
      assert html =~ "Targetalpha"
      assert html =~ "Targetbravo"
      # A NoFuel structure is not an unanchoring target.
      refute html =~ "Targetcharlie"

      planner |> element("#scout-target-990700001-ignore") |> render_click()
      ignored = render_async(planner)

      refute ignored =~ ~r/id="scout-target-990700001"/
      assert ignored =~ "scout-targets-ignored-990700001"
      assert ignored =~ "Targetbravo"
    end

    test "ticking the dead family adds its systems", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "targets"})
      render_async(planner)

      planner |> element("#scout-targets-family-dead") |> render_click()
      html = render_async(planner)

      assert html =~ "Targetcharlie"
    end
  end

  defp put_structure(structure_id, solar_system_id, status, unanchoring_since) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _row} =
      WandererApp.Api.ScoutStructure
      |> Ash.Changeset.for_create(:create, %{
        structure_id: structure_id,
        solar_system_id: solar_system_id,
        structure_name: "FIX #{structure_id}",
        group_name: "Citadel",
        status: status,
        presence: :seen,
        unanchoring_since: unanchoring_since,
        first_seen_at: DateTime.add(now, -3, :day),
        last_confirmed_at: DateTime.add(now, -1, :hour)
      })
      |> Ash.create(authorize?: false)
  end

  defp push_plan(conn) do
    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    render_click(planner, "select_origin", %{"id" => "990600001", "name" => "Outcomealpha"})
    render_async(planner)

    render_click(planner, "set_route", %{})
  end

  # A sweep's own task starts the split task from `handle_async/3`, so
  # one `render_async/1` can return between the two; the second waits for
  # whatever the first one started.
  defp sweep_html(planner) do
    render_async(planner)
    render_async(planner)
  end

  # The layout's own `live_render/3` (`ServerStatusLive`,
  # `components/layouts/live.html.heex`) mounts on every page under
  # `/scout`, so `live_children/1` here is never a one-element list --
  # picking by id is what keeps this file from silently asserting
  # against the wrong child the moment a second nested LiveView joins
  # the layout.
  defp planner_child(view) do
    Enum.find(live_children(view), &(&1.id == "scout-planner-live"))
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
