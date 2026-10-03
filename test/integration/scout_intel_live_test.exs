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
            state_label: "Shield"
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
        state_label: "Reinforced",
        observed_at: ago(600)
      })

      structure(%{
        structure_id: 1_000_000_000_777,
        structure_name: "Sosala Fortizar",
        state_label: "Anchored",
        observed_at: ago(5)
      })

      {:ok, _view, html} = live(conn, ~p"/scout")

      assert html =~ "Sosala Fortizar"
      assert html =~ "Anchored"
      refute html =~ "Reinforced"
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
        state_label: "Reinforced",
        event: :change,
        observed_at: ago(300)
      })

      structure(%{
        structure_id: 1_000_000_000_040,
        structure_name: "History Keepstar",
        state_label: "Shield",
        observed_at: ago(10)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      detail = render_click(view, "show_structure", %{"id" => "1000000000040"})

      assert detail =~ "scout-structure-detail"
      # Both observations, not just the latest the table above shows.
      assert detail =~ "Reinforced"
      assert detail =~ "Shield"
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
              "state_label" => "Shield"
            }
          ],
          nil
        )

      # The broadcast is what refreshes the page; without it this is the
      # same HTML as before.
      assert render(view) =~ "Pushed Keepstar"
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
