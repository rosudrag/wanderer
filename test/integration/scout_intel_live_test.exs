defmodule WandererAppWeb.ScoutIntelLiveTest do
  @moduledoc """
  Covers the `/scout` page's reads, which are the part of it that can
  compile clean and still be wrong: a `DISTINCT ON` expressed as an Ash
  `distinct` + `distinct_sort`, an ILIKE `fragment` filter with optional
  (nil-means-no-filter) arguments, and a schemaless Ecto `GROUP BY` in
  `WandererApp.Scout.Stats`. None of those are checked by the compiler —
  `mix compile` has shipped a broken Ash query in this repo before.

  What is asserted is behaviour a reader would notice:

    * the "Last seen" table shows the NEWEST row per structure, not every
      row — the log is append-only, so the opposite is the default;
    * search and the click-to-filter system chip actually narrow it;
    * spawn hotspots count repeat spawns in the same place;
    * the CSV export carries the filters and refuses a user without
      `:scout_intel_view`.

  See `docs/chewy/scout-intel.md` ("The page").
  """

  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WandererAppWeb.Factory

  alias WandererApp.Api.{ScoutSpawnSighting, ScoutStructureSighting}
  alias WandererApp.Identity.ScoutAccess

  @jita 30_000_142
  @amarr 30_002_187

  # Dedicated ids for the space-filter tests: they are the only ones that
  # need a map_solar_system_v2 row, and a shared id would let one test's
  # static row decide another's result.
  @hs_sys 30_050_001
  @ns_sys 30_050_002
  @wh_sys 31_050_003
  @unmapped_sys 30_050_004

  setup do
    Application.put_env(:wanderer_app, :scout_intel_enabled, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :scout_intel_enabled)
      Application.delete_env(:wanderer_app, :bootstrap_admin_character)
    end)

    user = create_user()
    character = create_character(%{user_id: user.id, name: "Scout Reader"})
    Application.put_env(:wanderer_app, :bootstrap_admin_character, character.name)

    conn = build_conn() |> Plug.Test.init_test_session(%{"user_id" => user.id})

    %{conn: conn, user: user}
  end

  defp structure(attrs) do
    {:ok, row} =
      ScoutStructureSighting.upsert(
        Map.merge(
          %{
            observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            event: :seen,
            solar_system_id: @jita,
            structure_id: 1_000_000_000_001,
            structure_name: "Default Keepstar",
            status: "FullPower"
          },
          attrs
        ),
        authorize?: false
      )

    row
  end

  defp spawn_sighting(attrs) do
    {:ok, row} =
      ScoutSpawnSighting.upsert(
        Map.merge(
          %{
            observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            solar_system_id: @jita,
            location_name: "Belt I - 1",
            spawn_name: "Dark Blood Phantom"
          },
          attrs
        ),
        authorize?: false
      )

    row
  end

  defp ago(minutes),
    do: DateTime.utc_now() |> DateTime.add(-minutes, :minute) |> DateTime.truncate(:second)

  describe "structures tab" do
    test "shows only the newest observation of each structure", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_777,
        structure_name: "Sosala Fortizar",
        status: "ArmorReinforced",
        observed_at: ago(600)
      })

      structure(%{
        structure_id: 1_000_000_000_777,
        structure_name: "Sosala Fortizar",
        status: "FullPower",
        observed_at: ago(5)
      })

      {:ok, _view, html} = live(conn, ~p"/scout")

      assert html =~ "Sosala Fortizar"
      assert html =~ "FullPower"
      refute html =~ "ArmorReinforced"
    end

    test "lists a running timer and omits one that has run out", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_010,
        structure_name: "Running Keepstar",
        observed_at: ago(60),
        timer_expires_at:
          DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)
      })

      structure(%{
        structure_id: 1_000_000_000_011,
        structure_name: "Expired Astrahus",
        observed_at: ago(600),
        timer_expires_at: ago(120)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      timers = view |> element("#scout-active-timers") |> render()

      assert timers =~ "Running Keepstar"
      refute timers =~ "Expired Astrahus"
    end

    test "the tick drops a timer that ran out while the page sat open", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_012,
        structure_name: "Expiring Astrahus",
        observed_at: ago(60),
        timer_expires_at:
          DateTime.utc_now() |> DateTime.add(2, :second) |> DateTime.truncate(:second)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")
      assert view |> element("#scout-active-timers") |> render() =~ "Expiring Astrahus"

      Process.sleep(2_100)
      send(view.pid, :tick)

      # No reload, no query: the tick alone retires it.
      refute view |> element("#scout-active-timers") |> render() =~ "Expiring Astrahus"
    end

    test "search narrows the tables", %{conn: conn} do
      structure(%{structure_id: 1_000_000_000_020, structure_name: "Haven Keepstar"})
      structure(%{structure_id: 1_000_000_000_021, structure_name: "Hostile Astrahus"})

      {:ok, view, html} = live(conn, ~p"/scout")
      assert html =~ "Haven Keepstar"
      assert html =~ "Hostile Astrahus"

      rendered = view |> form("form[phx-change=\"search\"]", %{q: "haven"}) |> render_change()

      assert rendered =~ "Haven Keepstar"
      refute rendered =~ "Hostile Astrahus"
    end

    test "clicking a system filters to it and the chip clears it", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_030,
        structure_name: "Jita Keepstar",
        solar_system_id: @jita
      })

      structure(%{
        structure_id: 1_000_000_000_031,
        structure_name: "Amarr Keepstar",
        solar_system_id: @amarr
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      filtered = render_click(view, "filter_system", %{"id" => to_string(@amarr)})

      assert filtered =~ "Amarr Keepstar"
      refute filtered =~ "Jita Keepstar"

      cleared = view |> element("#scout-system-filter") |> render_click()

      assert cleared =~ "Amarr Keepstar"
      assert cleared =~ "Jita Keepstar"
    end

    test "a structure's history opens with every observation of it", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_040,
        structure_name: "History Keepstar",
        status: "ArmorReinforced",
        event: :change,
        observed_at: ago(300)
      })

      structure(%{
        structure_id: 1_000_000_000_040,
        structure_name: "History Keepstar",
        status: "FullPower",
        observed_at: ago(10)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      detail = render_click(view, "show_structure", %{"id" => "1000000000040"})

      assert detail =~ "scout-structure-detail"
      # Both observations, not just the latest the table above shows.
      assert detail =~ "ArmorReinforced"
      assert detail =~ "FullPower"
    end

    test "an empty log says nothing was ever reported", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/scout")

      assert html =~ "No structure has ever been reported"
    end

    test "a structure ingested while the page is open appears without a reload", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/scout")
      refute html =~ "Pushed Keepstar"

      {:ok, %{stored: 1}} =
        WandererApp.Scout.Ingest.ingest_structures(
          [
            %{
              "utc_timestamp" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S"),
              "system_id" => to_string(@jita),
              "structure_id" => "1000000000099",
              "type_name" => "Pushed Keepstar",
              "status" => "FullPower"
            }
          ],
          nil
        )

      # The broadcast is what refreshes the page; without it this is the
      # same HTML as before.
      assert render(view) =~ "Pushed Keepstar"
    end
  end

  describe "the anchoring and unanchoring tables" do
    test "the anchoring table shows only ANCHORING-family statuses", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_060,
        structure_name: "Still Deploying Astrahus",
        status: "Onlining",
        observed_at: ago(5)
      })

      structure(%{
        structure_id: 1_000_000_000_061,
        structure_name: "Steady Fortizar",
        status: "FullPower",
        observed_at: ago(5)
      })

      structure(%{
        structure_id: 1_000_000_000_062,
        structure_name: "Pulling Out Keepstar",
        status: "Unanchoring",
        observed_at: ago(5)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      anchoring = view |> element("#scout-anchoring") |> render()

      assert anchoring =~ "Still Deploying Astrahus"
      refute anchoring =~ "Steady Fortizar"
      refute anchoring =~ "Pulling Out Keepstar"
    end

    test "the anchoring table folds to the latest row per structure", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_063,
        structure_name: "Slow Boat Fortizar",
        status: "Fitting",
        observed_at: ago(600)
      })

      structure(%{
        structure_id: 1_000_000_000_063,
        structure_name: "Slow Boat Fortizar",
        status: "Onlining",
        observed_at: ago(5)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      anchoring = view |> element("#scout-anchoring") |> render()

      assert anchoring =~ "Onlining"
      refute anchoring =~ "Fitting"
    end

    test "the unanchoring table shows only Unanchoring, latest row per structure",
         %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_064,
        structure_name: "Steady Keepstar",
        status: "FullPower",
        observed_at: ago(5)
      })

      structure(%{
        structure_id: 1_000_000_000_065,
        structure_name: "Coming Out Astrahus",
        status: "ArmorReinforced",
        observed_at: ago(600)
      })

      structure(%{
        structure_id: 1_000_000_000_065,
        structure_name: "Coming Out Astrahus",
        status: "Unanchoring",
        observed_at: ago(5)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      unanchoring = view |> element("#scout-unanchoring") |> render()

      assert unanchoring =~ "Coming Out Astrahus"
      refute unanchoring =~ "Steady Keepstar"
      # The fold: the ArmorReinforced row is history, not the latest.
      assert unanchoring =~ "Unanchoring"
    end

    test "both tables render an empty state when nothing matches", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_066,
        structure_name: "Nothing Special",
        status: "FullPower"
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      assert view |> element("#scout-anchoring") |> render() =~ "Nothing anchoring right now."
      assert view |> element("#scout-unanchoring") |> render() =~
               "Nothing unanchoring right now."
    end
  end

  describe "spawns tab" do
    test "hotspots group repeat spawns in the same place", %{conn: conn} do
      spawn_sighting(%{observed_at: ago(90), isk_value: Decimal.new("100000000")})
      spawn_sighting(%{observed_at: ago(45), isk_value: Decimal.new("100000000")})

      spawn_sighting(%{
        observed_at: ago(30),
        solar_system_id: @amarr,
        location_name: "Belt IV - 2",
        spawn_name: "True Sansha Mutant"
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      html = render_click(view, "select_tab", %{"tab" => "spawns"})
      hotspots = view |> element("#scout-hotspots") |> render()

      assert html =~ "Dark Blood Phantom"
      assert hotspots =~ "2×"
      assert hotspots =~ "True Sansha Mutant"
      assert hotspots =~ "1×"
    end

    test "the window excludes older rows", %{conn: conn} do
      spawn_sighting(%{spawn_name: "Fresh Spawn", observed_at: ago(60)})
      spawn_sighting(%{spawn_name: "Ancient Spawn", observed_at: ago(60 * 24 * 40)})

      {:ok, view, _html} = live(conn, ~p"/scout")

      default_window = render_click(view, "select_tab", %{"tab" => "spawns"})
      assert default_window =~ "Fresh Spawn"
      refute default_window =~ "Ancient Spawn"

      widened = render_change(view, "select_window", %{"days" => "90"})
      assert widened =~ "Ancient Spawn"
    end

    test "the fresh list folds to the newest sighting of each spawn", %{conn: conn} do
      spawn_sighting(%{observed_at: ago(90), isk_value: Decimal.new("50000000")})
      spawn_sighting(%{observed_at: ago(45), isk_value: Decimal.new("777000000")})

      spawn_sighting(%{
        observed_at: ago(45),
        spawn_name: "True Sansha Mutant",
        isk_value: Decimal.new("999000000")
      })

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "select_tab", %{"tab" => "spawns"})

      fresh = view |> element("#scout-fresh-spawns") |> render()

      # One row for the repeated spawn, carrying the newer sighting's value...
      assert fresh =~ "777.0M"
      refute fresh =~ "50.0M"

      # ...and a separate row for a different spawn in the same belt.
      assert fresh =~ "True Sansha Mutant"
      assert fresh =~ "999.0M"
    end

    test "the fresh list is bounded by three hours, not by the window selector", %{conn: conn} do
      spawn_sighting(%{spawn_name: "Just Landed", observed_at: ago(60)})
      spawn_sighting(%{spawn_name: "Hours Ago", observed_at: ago(301)})

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "select_tab", %{"tab" => "spawns"})

      fresh = view |> element("#scout-fresh-spawns") |> render()
      log = view |> element("#scout-spawns") |> render()

      assert fresh =~ "Just Landed"
      refute fresh =~ "Hours Ago"

      # Still in the (default 7-day) window-bounded log below it.
      assert log =~ "Hours Ago"
    end

    test "the tick ages a fresh spawn out with no query", %{conn: conn} do
      # Mirrors the structures tab's expiring-timer test, scaled to the
      # fresh list's 3-hour horizon instead of a timer's expiry: insert
      # 1s inside the horizon, let 1.1s of real time pass, and the tick
      # (no query) drops it exactly like an expired timer does.
      edge = DateTime.utc_now() |> DateTime.add(-10_799, :second) |> DateTime.truncate(:second)
      spawn_sighting(%{spawn_name: "Expiring Pop", observed_at: edge})

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "select_tab", %{"tab" => "spawns"})
      assert view |> element("#scout-fresh-spawns") |> render() =~ "Expiring Pop"

      Process.sleep(1_100)
      send(view.pid, :tick)

      # No reload, no query: the tick alone retires it.
      refute view |> element("#scout-fresh-spawns") |> render() =~ "Expiring Pop"
    end

    test "a spawn's history opens with every sighting at that location, and no other spawn's",
         %{conn: conn} do
      spawn_sighting(%{observed_at: ago(300), isk_value: Decimal.new("10000000")})
      spawn_sighting(%{observed_at: ago(10), isk_value: Decimal.new("20000000")})

      spawn_sighting(%{
        observed_at: ago(10),
        spawn_name: "True Sansha Mutant",
        isk_value: Decimal.new("30000000")
      })

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "select_tab", %{"tab" => "spawns"})

      render_click(view, "show_spawn", %{
        "system" => to_string(@jita),
        "location" => "Belt I - 1",
        "spawn" => "Dark Blood Phantom"
      })

      # Scoped to the modal: the other spawn is legitimately on the page
      # behind it, in the fresh list and the log.
      detail = view |> element("#scout-spawn-detail") |> render()

      # Both sightings of this spawn at this location, not just the latest.
      assert detail =~ "10.0M"
      assert detail =~ "20.0M"
      # Not the other spawn logged in the same belt.
      refute detail =~ "30.0M"
    end

    test "hotspots carry the category and the earliest sighting, not just the latest",
         %{conn: conn} do
      first_seen = ago(600)
      last_seen = ago(30)

      spawn_sighting(%{observed_at: first_seen, spawn_category: "faction"})
      spawn_sighting(%{observed_at: last_seen, spawn_category: "faction"})

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "select_tab", %{"tab" => "spawns"})

      hotspots = view |> element("#scout-hotspots") |> render()

      assert hotspots =~ "faction"
      assert hotspots =~ Calendar.strftime(first_seen, "%Y-%m-%d %H:%M")
      assert hotspots =~ Calendar.strftime(last_seen, "%Y-%m-%d %H:%M")
    end
  end

  describe "the space filter" do
    # The classification comes from map_solar_system_v2.system_class, not
    # from the row's stored truesec -- see WandererApp.Scout.Space -- so
    # every one of these needs the static row to exist.
    setup do
      create_solar_system(%{solar_system_id: @hs_sys, system_class: 7, security: "0.9"})
      create_solar_system(%{solar_system_id: @ns_sys, system_class: 9, security: "-0.3"})
      create_solar_system(%{solar_system_id: @wh_sys, system_class: 3, security: "-0.99"})
      :ok
    end

    test "unticking High drops highsec from the timer table and the fold", %{conn: conn} do
      running = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

      structure(%{
        structure_id: 1_000_000_000_100,
        structure_name: "Highsec Fortizar",
        solar_system_id: @hs_sys,
        timer_expires_at: running
      })

      structure(%{
        structure_id: 1_000_000_000_101,
        structure_name: "Nullsec Keepstar",
        solar_system_id: @ns_sys,
        timer_expires_at: running
      })

      structure(%{
        structure_id: 1_000_000_000_102,
        structure_name: "Hole Astrahus",
        solar_system_id: @wh_sys
      })

      {:ok, view, html} = live(conn, ~p"/scout")
      assert html =~ "Highsec Fortizar"

      filtered = view |> element("#scout-space-hs") |> render_click()

      refute filtered =~ "Highsec Fortizar"
      assert filtered =~ "Nullsec Keepstar"
      assert filtered =~ "Hole Astrahus"

      # Including the timer table, which ignores the window but not this.
      timers = view |> element("#scout-active-timers") |> render()
      refute timers =~ "Highsec Fortizar"
      assert timers =~ "Nullsec Keepstar"

      restored = view |> element("#scout-space-reset") |> render_click()
      assert restored =~ "Highsec Fortizar"
    end

    test "it narrows the spawn log, the fresh list and the hotspots together", %{conn: conn} do
      spawn_sighting(%{
        solar_system_id: @hs_sys,
        spawn_name: "Highsec Hauler",
        observed_at: ago(30)
      })

      spawn_sighting(%{
        solar_system_id: @wh_sys,
        spawn_name: "Hole Drifter",
        observed_at: ago(30)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "select_tab", %{"tab" => "spawns"})

      render_click(view, "toggle_space", %{"type" => "hs"})

      for id <- ~w(#scout-spawns #scout-fresh-spawns #scout-hotspots) do
        rendered = view |> element(id) |> render()
        refute rendered =~ "Highsec Hauler"
        assert rendered =~ "Hole Drifter"
      end
    end

    test "a system missing from the static map lives in Other, and only there", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_110,
        structure_name: "Nowhere Astrahus",
        solar_system_id: @unmapped_sys
      })

      {:ok, view, html} = live(conn, ~p"/scout")
      # Default selection is every bucket, so nothing is filtered at all.
      assert html =~ "Nowhere Astrahus"

      # Still visible with only Other selected...
      for key <- ~w(hs ls ns wh pochven) do
        render_click(view, "toggle_space", %{"type" => key})
      end

      assert render(view) =~ "Nowhere Astrahus"

      # ...and gone the moment Other itself is unticked.
      refute render_click(view, "toggle_space", %{"type" => "other"}) =~ "Nowhere Astrahus"
    end

    test "the CSV export applies the same selection", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_120,
        structure_name: "Highsec Export",
        solar_system_id: @hs_sys
      })

      structure(%{
        structure_id: 1_000_000_000_121,
        structure_name: "Nullsec Export",
        solar_system_id: @ns_sys
      })

      body =
        conn
        |> get(~p"/scout/export.csv", %{"tab" => "structures", "space" => "ns,wh"})
        |> response(200)

      assert body =~ "Nullsec Export"
      refute body =~ "Highsec Export"
    end
  end

  describe "CSV export" do
    test "carries the filters and every stored column", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_050,
        structure_name: "Exported Keepstar",
        owner_name: "Some Corp",
        shield_pct: 42
      })

      structure(%{
        structure_id: 1_000_000_000_051,
        structure_name: "Excluded Astrahus",
        solar_system_id: @amarr
      })

      body =
        conn
        |> get(~p"/scout/export.csv", %{"tab" => "structures", "system_id" => to_string(@jita)})
        |> response(200)

      assert body =~ "shield_pct"
      assert body =~ "Exported Keepstar"
      assert body =~ "42"
      refute body =~ "Excluded Astrahus"
    end

    test "is refused without the permission", %{conn: _conn} do
      Application.delete_env(:wanderer_app, :bootstrap_admin_character)

      other = create_user()
      create_character(%{user_id: other.id, name: "No Access"})

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"user_id" => other.id})
        |> get(~p"/scout/export.csv")

      assert response(conn, 403)
    end
  end

  describe "the permission gate" do
    test "a user without :scout_intel_view is redirected off the page", %{conn: _conn} do
      Application.delete_env(:wanderer_app, :bootstrap_admin_character)

      other = create_user()
      create_character(%{user_id: other.id, name: "Not A Scout"})
      refute ScoutAccess.can_view?(other.id)

      conn = build_conn() |> Plug.Test.init_test_session(%{"user_id" => other.id})

      assert {:error, {:live_redirect, %{to: "/maps"}}} = live(conn, ~p"/scout")
    end
  end
end
