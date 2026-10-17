defmodule WandererAppWeb.ScoutTableLiveTest do
  @moduledoc """
  CHEWY PATCH (scout column sort/filter): every column on `/scout` and
  `/scout/planner` sorts and filters, and the two halves of that live in
  different files — the column SPEC (`ScoutIntelColumns`,
  `ScoutPlannerColumns`, which the sort/filter and the `<thead>` both
  read) and the `<td>` list in the template.

  Nothing in the compiler relates those two. A spec one column short of
  its table renders a header offset by one cell from the data under it
  for the rest of that deploy, and every value a reader sorts or filters
  on is then the neighbouring column's. So the first test here walks the
  rendered DOM and compares, per table, the header cells against each
  body row's cells — a structural assertion no unit test over the spec
  lists can make.

  The rest is the behaviour: a sort click reorders rows without a read,
  a filter narrows one table and leaves its neighbours alone, and the
  `✕` puts the page's own order back.
  """

  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WandererAppWeb.Factory

  alias WandererApp.Api.{ScoutSpawnSighting, ScoutStructure, ScoutStructureEvent}

  @jita 30_000_142
  @amarr 30_002_187

  setup do
    Application.put_env(:wanderer_app, :scout_intel_enabled, true)
    Application.put_env(:wanderer_app, :scout_planner_enabled, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :scout_intel_enabled)
      Application.delete_env(:wanderer_app, :scout_planner_enabled)
      Application.delete_env(:wanderer_app, :bootstrap_admin_character)
    end)

    user = create_user()
    character = create_character(%{user_id: user.id, name: "Table Reader"})
    Application.put_env(:wanderer_app, :bootstrap_admin_character, character.name)

    %{conn: build_conn() |> Plug.Test.init_test_session(%{"user_id" => user.id}), user: user}
  end

  # -------------------------------------------------------------------
  # Seeding: one row on every structure board, plus two spawns.
  # -------------------------------------------------------------------

  defp structure(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      Map.merge(
        %{
          solar_system_id: @jita,
          structure_name: "Default Keepstar",
          status: "FullPower",
          presence: :seen,
          first_seen_at: now,
          last_confirmed_at: now,
          last_changed_at: now
        },
        attrs
      )

    {:ok, row} = ScoutStructure.create(attrs, authorize?: false)
    row
  end

  defp spawn_sighting(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, row} =
      ScoutSpawnSighting.create(
        Map.merge(
          %{
            solar_system_id: @jita,
            location_name: "Asteroid Belt I",
            spawn_name: "Dread Guristas Spawn",
            observed_at: now
          },
          attrs
        ),
        authorize?: false
      )

    row
  end

  defp seed_boards do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # One row per board, so every table on the page renders with data:
    # an empty table has no `<td>` row to compare the header against.
    structure(%{
      structure_id: 1_000_000_000_001,
      structure_name: "Alpha Keepstar",
      owner_name: "Alpha Corp",
      status: "Unanchored"
    })

    structure(%{
      structure_id: 1_000_000_000_002,
      structure_name: "Bravo Fortizar",
      owner_name: "Bravo Corp",
      status: "Reinforced",
      timer_expires_at: DateTime.add(now, 3_600, :second)
    })

    structure(%{
      structure_id: 1_000_000_000_003,
      structure_name: "Charlie Raitaru",
      owner_name: "Charlie Corp",
      status: "Anchoring",
      timer_expires_at: DateTime.add(now, 7_200, :second)
    })

    structure(%{
      structure_id: 1_000_000_000_004,
      structure_name: "Delta Astrahus",
      owner_name: "Delta Corp",
      status: "Unanchoring",
      unanchoring_since: DateTime.add(now, -86_400, :second)
    })

    structure(%{
      structure_id: 1_000_000_000_005,
      structure_name: "Echo Azbel",
      owner_name: "Echo Corp",
      status: "Abandoned",
      solar_system_id: @amarr
    })

    structure(%{
      structure_id: 1_000_000_000_006,
      structure_name: "Foxtrot Tatara",
      owner_name: "Foxtrot Corp",
      # `Status.no_fuel_family/0` is exactly `NoFuel` -- "LowPower" is
      # the English for it and lands on no board at all.
      status: "NoFuel"
    })

    structure(%{
      structure_id: 1_000_000_000_007,
      structure_name: "Golf Keepstar",
      owner_name: "Golf Corp",
      status: "Unanchoring",
      unanchoring_since: DateTime.add(now, -172_800, :second),
      unanchor_ended_at: DateTime.add(now, -3_600, :second),
      unanchor_outcome: :stopped
    })

    archived =
      structure(%{
        structure_id: 1_000_000_000_008,
        structure_name: "Hotel Athanor",
        owner_name: "Hotel Corp",
        status: "FullPower"
      })

    # `archived_at` is not a create input -- the page's own `✕` is the
    # `:archive` action, and so is this. No user id: who archived it is
    # not what this file is about.
    {:ok, _archived} = ScoutStructure.archive(archived, nil, authorize?: false)

    spawn_sighting(%{spawn_name: "Dread Guristas Spawn", players_in_local: 3})

    spawn_sighting(%{
      solar_system_id: @amarr,
      location_name: "Asteroid Belt II",
      spawn_name: "Shadow Serpentis Spawn",
      players_in_local: 11,
      observed_at: DateTime.add(now, -600, :second)
    })

    # The structure drill-down reads the derived event log, not the
    # current-state row, so a board with rows is not enough to render
    # it.
    for {kind, before, after_} <- [
          {:appeared, nil, "FullPower"},
          {:changed, "FullPower", "Reinforced"}
        ] do
      {:ok, _event} =
        ScoutStructureEvent.create(
          %{
            structure_id: 1_000_000_000_002,
            solar_system_id: @jita,
            kind: kind,
            status_before: before,
            status_after: after_,
            changed_fields: ["status"],
            observed_at: now
          },
          authorize?: false
        )
    end

    :ok
  end

  # -------------------------------------------------------------------
  # The structural check
  # -------------------------------------------------------------------

  # Every `<table>` on the page, as `{id, header_cells, [row_cells]}`.
  # The header's FIRST row is the labels; the second is the filter
  # controls and carries the same cell count by construction.
  defp tables(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("table")
    |> Enum.map(fn table ->
      id = table |> Floki.attribute("id") |> List.first()
      header = table |> Floki.find("thead tr") |> List.first()
      headers = if header, do: length(Floki.find(header, "th")), else: 0

      rows =
        table
        |> Floki.find("tbody tr")
        |> Enum.map(&Floki.find(&1, "td"))
        # The "nothing here" row is one `colspan` cell by design
        # (`ScoutComponents.empty/1`) and never lines up with a header.
        |> Enum.reject(fn cells ->
          length(cells) == 1 and Floki.attribute(cells, "colspan") != []
        end)
        |> Enum.map(&length/1)

      {id, headers, rows}
    end)
  end

  # `required` names the tables this case EXISTS to check. Without it a
  # case proves only that whatever happened to render lines up —
  # including the case where the interaction under test rendered
  # nothing at all and some other board carried the assertion.
  defp assert_aligned(html, context, required) do
    found = tables(html)

    for {id, headers, rows} <- found, rows != [] do
      for cells <- rows do
        assert headers == cells,
               "#{context}: table #{id} renders #{headers} header cells over a row of " <>
                 "#{cells} — the column spec and the <td> list have drifted"
      end
    end

    for id <- required do
      assert Enum.any?(found, fn {found_id, _headers, rows} -> found_id == id and rows != [] end),
             "#{context}: #{id} rendered no rows, so its columns were never checked"
    end

    assert Enum.any?(found, fn {_id, _headers, rows} -> rows != [] end),
           "#{context}: nothing rendered a table with rows, so nothing was checked"
  end

  describe "every column spec matches the table it heads" do
    test "structures category", %{conn: conn} do
      seed_boards()

      {:ok, _view, html} = live(conn, ~p"/scout/structures")

      assert_aligned(html, "structures", [
        "scout-now-table",
        "scout-unanchored",
        "scout-active-timers",
        "scout-anchoring",
        "scout-unanchoring",
        "scout-sorted-table",
        "scout-abandoned",
        "scout-no-fuel",
        "scout-archived",
        "scout-structures"
      ])
    end

    test "spawns category", %{conn: conn} do
      seed_boards()

      {:ok, _view, html} = live(conn, ~p"/scout/spawns")

      assert_aligned(html, "spawns", ["scout-fresh-spawns", "scout-spawns"])
    end

    test "the two drill-downs, which only exist once opened", %{conn: conn} do
      seed_boards()

      {:ok, view, _html} = live(conn, ~p"/scout/structures")

      html = render_click(view, "show_structure", %{"id" => "1000000000002"})
      assert html =~ "Alpha Keepstar" or html =~ "Bravo Fortizar"
      assert_aligned(html, "structure drill-down", ["scout-structure-history"])

      {:ok, view, _html} = live(conn, ~p"/scout/spawns")

      html =
        render_click(view, "show_spawn", %{
          "system" => to_string(@jita),
          "location" => "Asteroid Belt I",
          "spawn" => "Dread Guristas Spawn"
        })

      assert_aligned(html, "spawn drill-down", ["scout-spawn-history"])
    end

    # The three boards that only exist with `WANDERER_SCOUT_ASSET_SAFETY`
    # on -- and, more to the point, the Unanchoring board's CONDITIONAL
    # Trigger column, which the spec list and the template each decide
    # for themselves. With the flag off (every case above) that column
    # is absent from both and the drift this file exists to catch is
    # unreachable.
    test "the asset-safety boards, and the conditional Trigger column", %{
      conn: conn,
      user: user
    } do
      Application.put_env(:wanderer_app, :scout_asset_safety_enabled, true)
      on_exit(fn -> Application.delete_env(:wanderer_app, :scout_asset_safety_enabled) end)

      seed_boards()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _trigger} =
        WandererApp.Api.ScoutAssetSafety.create(
          %{
            notification_id: 900_001,
            type: "StructureItemsMovedToSafety",
            character_eve_id: 2_112_625_428,
            character_name: "Table Watcher",
            structure_id: 1_000_000_000_004,
            solar_system_id: @jita,
            structure_name: "Delta Astrahus",
            owner_name: "Delta Corp",
            notified_at: now
          },
          authorize?: false
        )

      # A second trigger, dismissed, so the undo board renders too --
      # it is the one board whose rows exist only after a reader acts.
      {:ok, _other} =
        WandererApp.Api.ScoutAssetSafety.create(
          %{
            notification_id: 900_002,
            type: "StructureItemsMovedToSafety",
            character_eve_id: 2_112_625_428,
            character_name: "Table Watcher",
            structure_id: 1_000_000_000_001,
            solar_system_id: @jita,
            structure_name: "Alpha Keepstar",
            owner_name: "Alpha Corp",
            notified_at: now
          },
          authorize?: false
        )

      assert WandererApp.Scout.AssetSafety.dismiss(1_000_000_000_001, user.id) > 0

      {:ok, _view, html} = live(conn, ~p"/scout/structures")

      assert_aligned(html, "asset safety on", [
        "scout-asset-safety-table",
        "scout-asset-safety-dismissed-table",
        "scout-unarmed-table",
        "scout-unanchoring"
      ])

      # The column itself, not just the alignment: "seed it" is
      # `armed_cell/1`'s own word for a hull with no item in it.
      assert html =~ "seed it"
    end

    test "planner, with a route on screen", %{conn: conn} do
      WandererApp.Cache.delete("scout:planner:adjacency")
      put_system(990_410_001, "Tablealpha")
      put_system(990_410_002, "Tablebravo")
      put_jump(990_410_001, 990_410_002)

      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = Enum.find(live_children(view), &(&1.id == "scout-planner-live"))

      render_click(planner, "select_origin", %{"id" => "990410001", "name" => "Tablealpha"})
      html = render_async(planner)

      assert_aligned(html, "planner rank", ["scout-planner-table"])
    end

    test "planner sweep and targets, which render three more tables", %{conn: conn} do
      WandererApp.Cache.delete("scout:planner:adjacency")
      WandererApp.Cache.delete("scout:planner:regions")
      put_system(990_420_001, "Tablesweepone")
      put_system(990_420_002, "Tablesweeptwo")
      put_system(990_420_003, "Tablesweepthree")
      put_jump(990_420_001, 990_420_002)
      put_jump(990_420_002, 990_420_003)

      # A system with a static-map row (so it is IN the security bands)
      # but no jump at all: its finding can never be a stop, which is
      # the only thing that puts a row on the "Left out" table.
      put_system(990_420_009, "Tableorphan")

      # One finding the route CAN take, one it cannot.
      structure(%{
        structure_id: 1_000_000_000_101,
        solar_system_id: 990_420_002,
        structure_name: "Target Astrahus",
        status: "Unanchoring",
        unanchoring_since: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      structure(%{
        structure_id: 1_000_000_000_102,
        solar_system_id: 990_420_009,
        structure_name: "Orphan Astrahus",
        status: "Unanchoring",
        unanchoring_since: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      seed_boards()

      {:ok, view, _html} = live(conn, ~p"/scout/planner")
      planner = Enum.find(live_children(view), &(&1.id == "scout-planner-live"))

      render_click(planner, "switch_mode", %{"mode" => "sweep"})
      render_click(planner, "add_region", %{"scope" => "sweep", "id" => "1"})
      render_async(planner)

      assert_aligned(render_async(planner), "planner sweep", [
        "scout-sweep-table",
        "scout-region-heat-table"
      ])

      render_click(planner, "switch_mode", %{"mode" => "targets"})

      assert_aligned(render_async(planner), "planner targets", [
        "scout-targets-table",
        "scout-targets-excluded-table"
      ])
    end
  end

  # -------------------------------------------------------------------
  # The behaviour
  # -------------------------------------------------------------------

  # The structure names in the order the "Last seen" board renders them.
  defp log_names(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#scout-structures tbody tr td:first-child")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
    |> Enum.map(&(&1 |> String.split("\n") |> List.first() |> String.trim()))
  end

  # The spawn names in the order the flat spawn log renders them. The
  # cell is `subject/1` -- a nested button and badge -- so the name is
  # the first non-blank line of its text, not the cell's first child.
  defp spawn_names(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#scout-spawns tbody tr td:nth-child(2)")
    |> Enum.map(&first_line/1)
  end

  defp first_line(node) do
    node
    |> Floki.text()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  describe "sorting" do
    test "a click orders by that column, a second reverses, a third restores", %{conn: conn} do
      seed_boards()

      {:ok, view, html} = live(conn, ~p"/scout/structures")

      default = log_names(html)
      assert length(default) == 8

      asc = render_click(view, "sort_table", %{"table" => "structures", "col" => "structure"})
      assert log_names(asc) == Enum.sort(default)

      desc = render_click(view, "sort_table", %{"table" => "structures", "col" => "structure"})
      assert log_names(desc) == default |> Enum.sort() |> Enum.reverse()

      restored =
        render_click(view, "sort_table", %{"table" => "structures", "col" => "structure"})

      assert log_names(restored) == default
    end

    test "an unknown table or column is a no-op, not a crash", %{conn: conn} do
      seed_boards()

      {:ok, view, html} = live(conn, ~p"/scout/structures")
      before = log_names(html)

      assert log_names(render_click(view, "sort_table", %{"table" => "nope", "col" => "x"})) ==
               before

      assert log_names(
               render_click(view, "sort_table", %{"table" => "structures", "col" => "nope"})
             ) == before
    end
  end

  describe "filtering" do
    test "narrows one table and leaves its neighbours alone", %{conn: conn} do
      seed_boards()

      {:ok, view, html} = live(conn, ~p"/scout/structures")

      assert html =~ "Alpha Keepstar"
      assert html =~ "Delta Astrahus"

      html =
        render_change(view, "filter_table", %{
          "table" => "structures",
          "col" => "structure",
          "value" => "delta"
        })

      assert log_names(html) == ["Delta Astrahus"]

      # The Unanchored board holds Alpha Keepstar and is a different
      # table: a per-column filter is per TABLE, unlike the toolbar's
      # page-wide search box.
      assert html =~ "Alpha Keepstar"
    end

    test "a status filter reads the word the badge shows", %{conn: conn} do
      seed_boards()

      {:ok, view, _html} = live(conn, ~p"/scout/structures")

      html =
        render_change(view, "filter_table", %{
          "table" => "structures",
          "col" => "status",
          "value" => "NoFuel"
        })

      assert log_names(html) == ["Foxtrot Tatara"]
    end

    test "a number column takes a comparison", %{conn: conn} do
      seed_boards()

      {:ok, view, html} = live(conn, ~p"/scout/spawns")

      assert spawn_names(html) == ["Dread Guristas Spawn", "Shadow Serpentis Spawn"]

      html =
        render_change(view, "filter_table", %{
          "table" => "spawns",
          "col" => "local",
          "value" => ">5"
        })

      assert spawn_names(html) == ["Shadow Serpentis Spawn"]

      # The 24h board above it is its own table and keeps both rows:
      # per-column filters are per TABLE, unlike the toolbar's search.
      assert html =~ "Dread Guristas Spawn"
    end

    test "the ✕ puts the page's own order and every row back", %{conn: conn} do
      seed_boards()

      {:ok, view, html} = live(conn, ~p"/scout/structures")
      default = log_names(html)

      render_click(view, "sort_table", %{"table" => "structures", "col" => "structure"})

      render_change(view, "filter_table", %{
        "table" => "structures",
        "col" => "structure",
        "value" => "delta"
      })

      html = render_click(view, "clear_table", %{"table" => "structures"})

      assert log_names(html) == default
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
        region_name: "Table Region",
        constellation_id: 1,
        constellation_name: "Table Constellation",
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
