defmodule WandererAppWeb.ScoutPlannerPresetsTest do
  @moduledoc """
  CHEWY PATCH (planner presets): a named control set round-trips through
  the database, INCLUDING the pilots.

  The point of the feature is that loading a preset reproduces the plan a
  scout ran last time, so "reproduces" is what is asserted: configure a
  page, save, mount a FRESH one (defaults, no localStorage -- the hook
  never fires in a test), load, and check the controls moved. A preset
  that restored everything but the pilot is a route pushed to the wrong
  character, which is why that field is asserted by name rather than
  trusted to the serialiser.

  Everything stored is re-validated on load, same as the localStorage
  blob (`apply_state/2` serves both): a preset naming a character this
  user no longer has must not survive into `character_eve_id`, since that
  id decides whose autopilot gets rewritten.

  The sweep fixtures mirror `ScoutPlannerLiveTest`'s: a straight
  6-system chain in one region, which is the smallest graph
  `Split.split/3` can actually carve into three parts.
  """

  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WandererAppWeb.Factory

  alias WandererApp.Scout.Presets

  setup do
    Application.put_env(:wanderer_app, :scout_intel_enabled, true)
    Application.put_env(:wanderer_app, :scout_planner_enabled, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :scout_intel_enabled)
      Application.delete_env(:wanderer_app, :scout_planner_enabled)
      Application.delete_env(:wanderer_app, :bootstrap_admin_character)
    end)

    user = insert(:user)
    character = insert(:character, %{user_id: user.id, name: "Preset Reader"})
    second = insert(:character, %{user_id: user.id, name: "Zeta Preset Alt"})
    Application.put_env(:wanderer_app, :bootstrap_admin_character, character.name)

    %{
      conn: build_conn() |> Plug.Test.init_test_session(%{"user_id" => user.id}),
      user: user,
      character: character,
      second: second
    }
  end

  describe "saving and loading" do
    setup do
      WandererApp.Cache.delete("scout:planner:adjacency")

      for {id, name} <- [
            {990_700_001, "Presetone"},
            {990_700_002, "Presettwo"},
            {990_700_003, "Presetthree"},
            {990_700_004, "Presetfour"},
            {990_700_005, "Presetfive"},
            {990_700_006, "Presetsix"}
          ] do
        put_system(id, name)
      end

      for {a, b} <- [
            {990_700_001, 990_700_002},
            {990_700_002, 990_700_003},
            {990_700_003, 990_700_004},
            {990_700_004, 990_700_005},
            {990_700_005, 990_700_006}
          ] do
        put_jump(a, b)
      end

      WandererApp.Cache.delete("scout:planner:regions")

      :ok
    end

    test "a preset restores the mode, the split and every pilot choice", %{
      conn: conn,
      user: user,
      second: second
    } do
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      sweep_html(planner)

      render_change(planner, "update_sweep_k", %{"k" => "3"})
      sweep_html(planner)

      render_change(planner, "select_character", %{"character_eve_id" => second.eve_id})

      render_change(planner, "select_part_character", %{
        "part" => "2",
        "character_eve_id" => second.eve_id
      })

      render_change(planner, "update_preset_name", %{"name" => "  Delve   evening  "})

      assert render_submit(planner, "save_preset", %{"name" => "  Delve   evening  "}) =~
               "Saved “Delve evening”"

      [preset] = Presets.list(user.id)
      assert preset.name == "Delve evening"
      assert preset.state["mode"] == "sweep"
      assert preset.state["sweep_k"] == 3
      assert preset.state["sweep_regions"] == [1]
      assert preset.state["character_eve_id"] == second.eve_id
      # `default_pilots/3` fills every part with a round-robin pick, so
      # the stored map has all three slots; the one that was CHOSEN is
      # what has to survive.
      assert preset.state["sweep_pilots"]["2"] == second.eve_id

      # A FRESH page: rank mode, k=1, no scope. Anything below came from
      # the load.
      {:ok, fresh_view, _html} = live(conn, ~p"/scout/planner")
      fresh = planner_child(fresh_view)

      assert render(fresh) =~ "scout-planner-max-jumps"
      refute render(fresh) =~ "scout-sweep-part-2-character"

      render_click(fresh, "load_preset", %{"id" => preset.id})
      html = sweep_html(fresh)

      assert html =~ "Loaded “Delve evening”"
      # Sweep mode, with its scope, re-swept and re-split without a
      # second click: the rank mode's controls are gone and three part
      # pickers are on the page.
      refute html =~ "scout-planner-max-jumps"
      assert html =~ "Presetone"
      assert html =~ "scout-sweep-part-0-character"
      assert html =~ "scout-sweep-part-2-character"

      assigns = :sys.get_state(fresh.pid).socket.assigns
      assert assigns.character_eve_id == second.eve_id
      assert assigns.sweep_pilots[2] == second.eve_id
    end

    test "the rank mode's own controls round-trip", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = planner_child(view)

      render_change(planner, "update_max_jumps", %{"max_jumps" => "7"})
      render_click(planner, "select_origin", %{"id" => "990700001", "name" => "Presetone"})
      render_async(planner)
      render_click(planner, "toggle_space", %{"type" => "ls"})
      render_async(planner)

      render_submit(planner, "save_preset", %{"name" => "Rank run"})
      [preset] = Presets.list(user.id)

      {:ok, fresh_view, _html} = live(conn, ~p"/scout/planner")
      fresh = planner_child(fresh_view)

      assert render(fresh) =~ ~s(value="25")

      render_click(fresh, "load_preset", %{"id" => preset.id})
      html = render_async(fresh)

      assert html =~ ~s(value="7")
      assert html =~ "Presetone"

      assigns = :sys.get_state(fresh.pid).socket.assigns
      assert assigns.origin_id == 990_700_001
      assert assigns.max_jumps == 7
      assert assigns.security == [:hs, :ns]
    end
  end

  test "a preset naming a character the user no longer has falls back", %{
    conn: conn,
    user: user,
    character: character
  } do
    {:ok, preset} =
      Presets.save(user.id, "Stale pilots", %{
        "mode" => "sweep",
        "sweep_k" => 2,
        "character_eve_id" => "999000111",
        "sweep_pilots" => %{"0" => "999000111", "1" => character.eve_id}
      })

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    render_click(planner, "load_preset", %{"id" => preset.id})
    assert render_async(planner) =~ "Loaded “Stale pilots”"

    assigns = :sys.get_state(planner.pid).socket.assigns

    # The foreign id never reaches an assign that decides whose autopilot
    # is written; the user's own character does.
    assert assigns.character_eve_id == character.eve_id
    assert assigns.sweep_pilots == %{1 => character.eve_id}
  end

  test "a split slot beyond the restored k is dropped", %{conn: conn, user: user} do
    {:ok, preset} =
      Presets.save(user.id, "Too many slots", %{
        "mode" => "sweep",
        "sweep_k" => 2,
        "sweep_starts" => %{"5" => %{"id" => 30_000_142, "name" => "Jita"}}
      })

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    render_click(planner, "load_preset", %{"id" => preset.id})
    render_async(planner)

    assert :sys.get_state(planner.pid).socket.assigns.sweep_starts == %{}
  end

  test "presets are per user: another user's id is refused, not loaded", %{conn: conn} do
    other_user = insert(:user)
    {:ok, theirs} = Presets.save(other_user.id, "Theirs", %{"mode" => "sweep"})

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    html = render_click(planner, "load_preset", %{"id" => theirs.id})

    assert html =~ "That preset no longer exists."
    refute html =~ "Theirs"
  end

  test "saving under an existing name replaces it rather than duplicating", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    render_submit(planner, "save_preset", %{"name" => "Nightly"})

    render_click(planner, "switch_mode", %{"mode" => "targets"})
    render_submit(planner, "save_preset", %{"name" => "Nightly"})

    assert [%{name: "Nightly", state: %{"mode" => "targets"}}] = Presets.list(user.id)
  end

  test "a blank name is refused and nothing is stored", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    assert render_submit(planner, "save_preset", %{"name" => "   "}) =~ "Name the preset first."
    assert Presets.list(user.id) == []
  end

  test "deleting a preset removes its chip", %{conn: conn, user: user} do
    {:ok, preset} = Presets.save(user.id, "Throwaway", %{"mode" => "rank"})

    {:ok, view, _html} = live(conn, ~p"/scout/planner")
    planner = planner_child(view)

    assert render(planner) =~ "Throwaway"

    html = render_click(planner, "delete_preset", %{"id" => preset.id})

    assert html =~ "Deleted “Throwaway”"
    refute html =~ ">Throwaway<"
    assert Presets.list(user.id) == []
  end

  test "the per-user cap refuses a new preset but still allows overwriting", %{user: user} do
    for n <- 1..Presets.max_presets() do
      {:ok, _preset} = Presets.save(user.id, "Preset #{n}", %{"mode" => "rank"})
    end

    assert {:error, {:too_many, 50}} = Presets.save(user.id, "One too many", %{"mode" => "rank"})
    assert {:ok, _overwritten} = Presets.save(user.id, "Preset 1", %{"mode" => "sweep"})
  end

  defp planner_child(view) do
    Enum.find(live_children(view), &(&1.id == "scout-planner-live"))
  end

  # A sweep's own task starts the split task from `handle_async/3`, so
  # one `render_async/1` can return between the two.
  defp sweep_html(planner) do
    render_async(planner)
    render_async(planner)
  end

  defp put_system(solar_system_id, name) do
    {:ok, _system} =
      WandererApp.Api.MapSolarSystem
      |> Ash.Changeset.for_create(:create, %{
        solar_system_id: solar_system_id,
        solar_system_name: name,
        solar_system_name_lc: String.downcase(name),
        region_id: 1,
        region_name: "Preset Region",
        constellation_id: 1,
        constellation_name: "Preset Constellation",
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
