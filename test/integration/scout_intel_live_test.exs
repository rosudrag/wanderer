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
    * the spawns tab's 24-hour list folds to the newest sighting per spawn;
    * the CSV export carries the filters and refuses a user without
      `:scout_intel_view`.

  See `docs/chewy/scout-intel.md` ("The page").
  """

  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WandererAppWeb.Factory

  alias WandererApp.Api.{ScoutSpawnSighting, ScoutStructure, ScoutStructureEvent}
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

  # CURRENT STATE, not a sighting tape. `/scout`'s boards read
  # `scout_structures_v1`, which holds one row per `structure_id`, so a
  # test that reports the same structure twice is moving one row rather
  # than appending a second. `observed_at` is accepted here because that
  # is how a report is described, and maps onto `last_confirmed_at`.
  #
  # Latest-wins, exactly like `WandererApp.Scout.Snapshot`'s own `stale?`
  # guard: an older report never drags a row backwards, so a test may
  # seed in any order and still mean what it reads like.
  defp structure(attrs) do
    attrs =
      Map.merge(
        %{
          solar_system_id: @jita,
          structure_id: 1_000_000_000_001,
          structure_name: "Default Keepstar",
          status: "FullPower",
          presence: :seen
        },
        attrs
      )

    observed_at =
      Map.get(attrs, :observed_at) || DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.drop([:observed_at, :event])
      |> Map.put(:last_confirmed_at, observed_at)

    case ScoutStructure.by_structure_id(attrs.structure_id, authorize?: false) do
      {:ok, existing} ->
        if DateTime.compare(observed_at, existing.last_confirmed_at) == :lt do
          existing
        else
          {:ok, row} =
            ScoutStructure.update(existing, attrs, authorize?: false)

          row
        end

      _ ->
        {:ok, row} =
          ScoutStructure.create(Map.put(attrs, :first_seen_at, observed_at), authorize?: false)

        row
    end
  end

  # One entry in the derived event log the drill-down renders.
  defp structure_event(attrs) do
    {:ok, row} =
      ScoutStructureEvent.create(
        Map.merge(
          %{
            structure_id: 1_000_000_000_001,
            solar_system_id: @jita,
            kind: :changed,
            observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
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

  defp view_timers(conn) do
    {:ok, view, _html} = live(conn, ~p"/scout")
    view |> element("#scout-active-timers") |> render()
  end

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

    test "one structure with many sightings is one timer row", %{conn: conn} do
      # The log is append-only, so a structure the client re-reports while
      # its timer runs has a row per pass. The timer table folds them.
      expires = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

      for minutes <- [300, 180, 60] do
        structure(%{
          structure_id: 1_000_000_000_015,
          structure_name: "Polled Keepstar",
          status: "ArmorReinforced",
          event: if(minutes == 300, do: :change, else: :seen),
          observed_at: ago(minutes),
          timer_expires_at: expires
        })
      end

      timers = view_timers(conn)

      assert length(Regex.scan(~r/Polled Keepstar/, timers)) == 1
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

    test "a structure's history opens with everything that happened to it", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_040,
        structure_name: "History Keepstar",
        status: "FullPower",
        observed_at: ago(10)
      })

      structure_event(%{
        structure_id: 1_000_000_000_040,
        kind: :changed,
        status_before: "NoFuel",
        status_after: "ArmorReinforced",
        changed_fields: ["status"],
        observed_at: ago(300)
      })

      structure_event(%{
        structure_id: 1_000_000_000_040,
        kind: :cleared,
        status_before: "ArmorReinforced",
        status_after: "FullPower",
        observed_at: ago(10)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      detail = render_click(view, "show_structure", %{"id" => "1000000000040"})

      assert detail =~ "scout-structure-detail"
      # The whole tape, not just the state the table above shows.
      assert detail =~ "ArmorReinforced"
      assert detail =~ "FullPower"
      assert detail =~ "cleared"
      # The header comes from current state, which an event row has not got.
      assert detail =~ "History Keepstar"
    end

    test "an empty log says nothing was ever reported", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/scout")

      assert html =~ "No structure has ever been reported"
    end

    # The header's "structures Nh ago" is the dead-client indicator, and
    # it read the retired `scout_structure_sightings_v1` tape while the
    # presence feed writes only `scout_structures_v1` — so a live client
    # posting snapshots every minute rendered as "never". The assertion
    # is on the clock the feed actually moves.
    test "the header's freshness follows the presence feed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/scout")
      assert html =~ "never"

      structure(%{
        structure_id: 1_000_000_000_400,
        structure_name: "Fresh Keepstar",
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert WandererApp.Scout.Stats.last_observed_at().structures

      {:ok, _view, html} = live(conn, ~p"/scout")
      refute html =~ "structures <span class=\"text-gray-300\">never</span>"
    end

    test "a structure ingested while the page is open appears without a reload", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/scout")
      refute html =~ "Pushed Keepstar"

      {:ok, %{appeared: 1}} =
        WandererApp.Scout.Snapshot.ingest(nil, %{
          "solar_system_id" => to_string(@jita),
          "observed_at" => to_string(DateTime.to_unix(DateTime.utc_now())),
          "observer_x" => "0",
          "observer_y" => "0",
          "observer_z" => "0",
          "horizon_m" => "500000",
          "structures" => [
            %{
              "structure_id" => "1000000000099",
              "type_name" => "Pushed Keepstar",
              "status" => "NoFuel",
              "pos_x" => "1000",
              "pos_y" => "0",
              "pos_z" => "0"
            }
          ]
        })

      # The broadcast is what refreshes the page; without it this is the
      # same HTML as before.
      assert render(view) =~ "Pushed Keepstar"
    end
  end

  # Asked for 2026-10-06. `Abandoned` (asset safety off, everything
  # inside drops) and `NoFuel` (low power, owner not paying attention)
  # shared one board through `Status.dead_family/0`; they are different
  # errands, so they are now two boards fed by two read actions.
  describe "the abandoned and no-fuel tables" do
    test "each board carries only its own status", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_070,
        structure_name: "Dropped Azbel",
        status: "Abandoned",
        observed_at: ago(5)
      })

      structure(%{
        structure_id: 1_000_000_000_071,
        structure_name: "Dry Raitaru",
        status: "NoFuel",
        observed_at: ago(5)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      abandoned = view |> element("#scout-abandoned") |> render()
      no_fuel = view |> element("#scout-no-fuel") |> render()

      assert abandoned =~ "Dropped Azbel"
      refute abandoned =~ "Dry Raitaru"

      assert no_fuel =~ "Dry Raitaru"
      refute no_fuel =~ "Dropped Azbel"
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

    test "the anchoring table renders the clock the feed reports", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_070,
        structure_name: "Half Built Astrahus",
        status: "Anchoring",
        timer_seconds: 7_200,
        timer_expires_at:
          DateTime.utc_now() |> DateTime.add(2, :hour) |> DateTime.truncate(:second)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      anchoring = view |> element("#scout-anchoring") |> render()

      assert anchoring =~ "Anchors in"
      assert anchoring =~ ~r/(1h 59m|2h 0m)/
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

    test "the unanchoring board shows the predicted 7-day bound, not a wire timer",
         %{conn: conn} do
      # A decommission reports no countdown: timer_expires_at stays nil
      # and the deadline is derived from when we first saw it unanchoring.
      structure(%{
        structure_id: 1_000_000_000_067,
        structure_name: "Two Days In Astrahus",
        group_name: "Citadel",
        status: "Unanchoring",
        unanchoring_since:
          DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:second)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      unanchoring = view |> element("#scout-unanchoring") |> render()

      # 7 days from two days ago: five days left, bounded, never exact.
      assert unanchoring =~ ~r/≤\s*(5d 0h|4d 2\dh)/
    end

    test "an orbital gets no prediction: it unanchors in minutes, not days",
         %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_068,
        structure_name: "Jita IV - Moon 4 Customs Office",
        group_name: "Orbital Infrastructure",
        status: "Unanchoring",
        unanchoring_since:
          DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:second)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      unanchoring = view |> element("#scout-unanchoring") |> render()

      assert unanchoring =~ "Jita IV - Moon 4 Customs Office"
      refute unanchoring =~ "≤"
      assert unanchoring =~ "Orbital: unanchors in minutes"
    end

    test "the Where column names the celestial and prints no distance", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_069,
        structure_name: "Moon Three Astrahus",
        status: "Unanchoring",
        nearest_celestial: "Jita IV - Moon 4",
        nearest_celestial_m: 12_480,
        unanchoring_since:
          DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      unanchoring = view |> element("#scout-unanchoring") |> render()

      assert unanchoring =~ "Jita IV - Moon 4"
      # 12 480 m rendered as "12.5 km" before: a reader acts on the body,
      # never on the offset from it.
      refute unanchoring =~ "km"
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

  describe "the unanchored alert" do
    test "a structure sitting unanchored raises the banner on both tabs", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_200,
        structure_name: "Free Keepstar",
        status: "Unanchored",
        observed_at: ago(30)
      })

      {:ok, view, html} = live(conn, ~p"/scout")
      assert html =~ "scout-unanchored-alert"
      assert view |> element("#scout-unanchored") |> render() =~ "Free Keepstar"

      # The whole point: a reader on the spawns tab still sees it.
      assert render_patch(view, ~p"/scout/spawns") =~ "scout-unanchored-alert"
    end

    test "the banner survives the window selector and the search box", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_201,
        structure_name: "Free Astrahus",
        status: "Unanchored",
        observed_at: ago(60 * 24 * 3)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      # Three days old, inside the alert's own 7-day horizon but outside a
      # 24-hour window.
      narrowed = render_change(view, "select_window", %{"days" => "1"})
      assert narrowed =~ "scout-unanchored-alert"

      # An alert a search box can hide is not an alert.
      searched =
        view
        |> form("form[phx-change=\"search\"]", %{q: "nothing matches this"})
        |> render_change()

      assert searched =~ "scout-unanchored-alert"
    end

    test "the space filter still narrows it", %{conn: conn} do
      create_solar_system(%{solar_system_id: @hs_sys, system_class: 7, security: "0.9"})

      structure(%{
        structure_id: 1_000_000_000_202,
        structure_name: "Highsec Unanchored",
        status: "Unanchored",
        solar_system_id: @hs_sys,
        observed_at: ago(30)
      })

      {:ok, view, html} = live(conn, ~p"/scout")
      assert html =~ "scout-unanchored-alert"

      refute view |> element("#scout-space-hs") |> render_click() =~ "scout-unanchored-alert"
    end

    test "an unanchored structure is not also listed as anchoring", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_203,
        structure_name: "Free Fortizar",
        status: "Unanchored",
        observed_at: ago(10)
      })

      structure(%{
        structure_id: 1_000_000_000_204,
        structure_name: "Half Built Astrahus",
        status: "Onlining",
        observed_at: ago(10)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      anchoring = view |> element("#scout-anchoring") |> render()
      assert anchoring =~ "Half Built Astrahus"
      refute anchoring =~ "Free Fortizar"
    end

    test "no unanchored structure means no banner at all", %{conn: conn} do
      structure(%{structure_id: 1_000_000_000_205, status: "FullPower"})

      {:ok, _view, html} = live(conn, ~p"/scout")

      refute html =~ "scout-unanchored-alert"
    end
  end

  # The only write on this page. The rule worth pinning is not "the row
  # disappears" -- it is WHICH clock un-hides it again: a sweep
  # re-confirming the same hull every few minutes must not resurrect a
  # finding a human already judged, and a real state change must.
  describe "archiving a structure" do
    test "takes it off the boards and the banner, but not out of the log", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_300,
        structure_name: "Archive Me Astrahus",
        status: "Unanchored"
      })

      {:ok, view, html} = live(conn, ~p"/scout")
      assert html =~ "scout-unanchored-alert"
      assert view |> element("#scout-unanchored") |> render() =~ "Archive Me Astrahus"

      archived = render_click(view, "archive_structure", %{"id" => "1000000000300"})

      refute archived =~ "scout-unanchored-alert"
      refute view |> element("#scout-unanchored") |> render() =~ "Archive Me Astrahus"

      # Not a delete: it moves to the board that undoes it, and the
      # ingest log still knows about it.
      assert view |> element("#scout-archived") |> render() =~ "Archive Me Astrahus"
      assert view |> element("#scout-structures") |> render() =~ "Archive Me Astrahus"
    end

    test "being re-confirmed unchanged does not bring it back", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_301,
        structure_name: "Still Not There",
        status: "Unanchored",
        observed_at: ago(30)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "archive_structure", %{"id" => "1000000000301"})

      # The sweep sees it again and moves `last_confirmed_at` only --
      # exactly what `WandererApp.Scout.Snapshot`'s `unchanged` branch
      # writes.
      structure(%{
        structure_id: 1_000_000_000_301,
        structure_name: "Still Not There",
        status: "Unanchored",
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      refute render_click(view, "refresh", %{}) =~ "scout-unanchored-alert"
      refute view |> element("#scout-unanchored") |> render() =~ "Still Not There"
    end

    test "an actual state change brings it back", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_302,
        structure_name: "Changed Astrahus",
        status: "Unanchored",
        observed_at: ago(30)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "archive_structure", %{"id" => "1000000000302"})
      refute view |> element("#scout-unanchored") |> render() =~ "Changed Astrahus"

      # `last_changed_at` is only ever moved by a `:changed` diff. A
      # second LATER than the archive, not the same one: the predicate
      # is `last_changed_at > archived_at`, so a change recorded in the
      # same second as the click loses the tie to the human — which is
      # the behaviour wanted, and a tie is a test artifact anyway (real
      # sweeps are minutes apart).
      later = DateTime.utc_now() |> DateTime.add(5, :second) |> DateTime.truncate(:second)

      structure(%{
        structure_id: 1_000_000_000_302,
        structure_name: "Changed Astrahus",
        status: "Unanchored",
        last_changed_at: later,
        observed_at: later
      })

      assert render_click(view, "refresh", %{}) =~ "scout-unanchored-alert"
      assert view |> element("#scout-unanchored") |> render() =~ "Changed Astrahus"
    end

    test "restore puts it back immediately", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_303,
        structure_name: "Undo Astrahus",
        status: "Unanchored"
      })

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "archive_structure", %{"id" => "1000000000303"})
      refute view |> element("#scout-unanchored") |> render() =~ "Undo Astrahus"

      restored = render_click(view, "restore_structure", %{"id" => "1000000000303"})

      assert restored =~ "scout-unanchored-alert"
      assert view |> element("#scout-unanchored") |> render() =~ "Undo Astrahus"
    end
  end

  describe "sticky filters" do
    test "a saved window, search and space selection are restored on mount", %{conn: conn} do
      create_solar_system(%{solar_system_id: @hs_sys, system_class: 7, security: "0.9"})
      create_solar_system(%{solar_system_id: @ns_sys, system_class: 9, security: "-0.3"})

      structure(%{
        structure_id: 1_000_000_000_300,
        structure_name: "Highsec Saved",
        solar_system_id: @hs_sys
      })

      structure(%{
        structure_id: 1_000_000_000_301,
        structure_name: "Nullsec Saved",
        solar_system_id: @ns_sys
      })

      {:ok, view, html} = live(conn, ~p"/scout")
      assert html =~ "Highsec Saved"

      restored =
        render_hook(view, "ls_restore_scout_filters", %{
          "value" => Jason.encode!(%{"tab" => "structures", "days" => 1, "space" => ["ns"]})
        })

      refute restored =~ "Highsec Saved"
      assert restored =~ "Nullsec Saved"
    end

    test "a first visit and a corrupt payload both leave the defaults alone", %{conn: conn} do
      structure(%{structure_id: 1_000_000_000_302, structure_name: "Still Here"})

      {:ok, view, _html} = live(conn, ~p"/scout")

      assert render_hook(view, "ls_restore_scout_filters", %{"value" => nil}) =~ "Still Here"

      assert render_hook(view, "ls_restore_scout_filters", %{"value" => "{not json"}) =~
               "Still Here"

      # An unknown window and a tab that is not an existing atom are
      # user-writable storage, not input this page may crash on.
      restored =
        render_hook(view, "ls_restore_scout_filters", %{
          "value" => Jason.encode!(%{"tab" => "nope", "days" => 4242, "space" => ["garbage"]})
        })

      assert restored =~ "Still Here"
    end

    # PRODUCTION CRASH, 1.103.4-chewy.81: the hook fires once per mount,
    # and a mount whose URL was `/scout/planner` has no log category at
    # all -- `@filters` holds entries for `:structures` and `:spawns`
    # only. A `Map.fetch!` on `:planner` took the whole LiveView down
    # with `KeyError key :planner not found`, so every deep-link to the
    # planner died about 100ms after it rendered.
    test "a restore that lands on the planner category stores and renders nothing", %{conn: conn} do
      Application.put_env(:wanderer_app, :scout_planner_enabled, true)
      on_exit(fn -> Application.delete_env(:wanderer_app, :scout_planner_enabled) end)

      {:ok, view, _html} = live(conn, ~p"/scout/planner")

      html =
        render_hook(view, "ls_restore_scout_filters", %{
          "value" =>
            Jason.encode!(%{
              "structures" => %{"days" => 1, "q" => "", "system_id" => nil, "space" => ["ns"]},
              "spawns" => %{"days" => 1, "q" => "", "system_id" => nil, "space" => ["ns"]}
            })
        })

      assert html =~ "scout-planner-pane"

      # And the restored values were kept, not dropped: the next
      # category the reader opens is the one they left.
      assert render_patch(view, ~p"/scout/structures") =~ "scout-space-reset"
    end

    test "a legacy payload migrates onto the category its tab key names, not the one on screen",
         %{conn: conn} do
      create_solar_system(%{solar_system_id: @hs_sys, system_class: 7, security: "0.9"})
      create_solar_system(%{solar_system_id: @ns_sys, system_class: 9, security: "-0.3"})

      structure(%{
        structure_id: 1_000_000_000_304,
        structure_name: "Untouched Structure",
        solar_system_id: @hs_sys
      })

      spawn_sighting(%{
        solar_system_id: @hs_sys,
        spawn_name: "Highsec Spawn Saved",
        observed_at: ago(60)
      })

      spawn_sighting(%{
        solar_system_id: @ns_sys,
        spawn_name: "Nullsec Spawn Saved",
        observed_at: ago(60)
      })

      {:ok, view, html} = live(conn, ~p"/scout")
      assert html =~ "Untouched Structure"

      # A legacy blob naming "spawns" restores while structures is the
      # category on screen -- the structures board, the only thing
      # rendered right now, must not move.
      restored_on_structures =
        render_hook(view, "ls_restore_scout_filters", %{
          "value" => Jason.encode!(%{"tab" => "spawns", "days" => 1, "space" => ["ns"]})
        })

      assert restored_on_structures =~ "Untouched Structure"

      # The migration landed on spawns, not here.
      spawns_html = render_patch(view, ~p"/scout/spawns")
      refute spawns_html =~ "Highsec Spawn Saved"
      assert spawns_html =~ "Nullsec Spawn Saved"
    end
  end

  # The bug report this whole redesign exists for: one flat
  # `scout_filters` blob shared by both tabs, so a space selection made
  # on structures silently applied to spawns too.
  describe "per-category filters" do
    test "a space selection narrowed on structures does not apply to spawns, and survives the trip back",
         %{conn: conn} do
      create_solar_system(%{solar_system_id: @hs_sys, system_class: 7, security: "0.9"})
      create_solar_system(%{solar_system_id: @ns_sys, system_class: 9, security: "-0.3"})

      structure(%{
        structure_id: 1_000_000_000_306,
        structure_name: "Highsec Structure",
        solar_system_id: @hs_sys
      })

      structure(%{
        structure_id: 1_000_000_000_307,
        structure_name: "Nullsec Structure",
        solar_system_id: @ns_sys
      })

      spawn_sighting(%{
        solar_system_id: @hs_sys,
        spawn_name: "Highsec Spawn",
        observed_at: ago(10)
      })

      {:ok, view, html} = live(conn, ~p"/scout")
      assert html =~ "Highsec Structure"

      # Drop highsec from the structures board only.
      narrowed = view |> element("#scout-space-hs") |> render_click()
      refute narrowed =~ "Highsec Structure"
      assert narrowed =~ "Nullsec Structure"

      # The spawns board still carries every space type -- the
      # structures-only selection never crossed the category boundary.
      spawns_html = render_patch(view, ~p"/scout/spawns")
      assert spawns_html =~ "Highsec Spawn"

      # And back on structures, the narrowing a reader picked is still
      # there -- it was never undone by visiting another category.
      back = render_patch(view, ~p"/scout/structures")
      refute back =~ "Highsec Structure"
      assert back =~ "Nullsec Structure"
    end
  end

  describe "URL-driven categories" do
    test "/scout is structures and /scout/spawns deep-links straight into spawns", %{conn: conn} do
      structure(%{structure_id: 1_000_000_000_308, structure_name: "Only A Structure"})
      spawn_sighting(%{spawn_name: "Only A Spawn", observed_at: ago(10)})

      {:ok, _view, structures_html} = live(conn, ~p"/scout")
      assert structures_html =~ "Only A Structure"
      refute structures_html =~ "Only A Spawn"
      assert structures_html =~ ~s(id="scout-structures")
      refute structures_html =~ ~s(id="scout-spawns")

      assert structures_html =~
               ~r/<a[^>]*id="scout-tab-structures"[^>]*class="tab tab-active"[^>]*>/

      # A fresh connection straight to /scout/spawns: structures never
      # ran a single read on this socket, so there is nothing for it to
      # have flashed before spawns painted.
      {:ok, _view, spawns_html} = live(conn, ~p"/scout/spawns")
      refute spawns_html =~ "Only A Structure"
      assert spawns_html =~ "Only A Spawn"
      refute spawns_html =~ ~s(id="scout-structures")
      assert spawns_html =~ ~s(id="scout-spawns")

      assert spawns_html =~
               ~r/<a[^>]*id="scout-tab-spawns"[^>]*class="tab tab-active"[^>]*>/
    end
  end

  describe "spawns tab" do
    test "the window excludes older rows", %{conn: conn} do
      spawn_sighting(%{spawn_name: "Fresh Spawn", observed_at: ago(60)})
      spawn_sighting(%{spawn_name: "Ancient Spawn", observed_at: ago(60 * 24 * 40)})

      {:ok, view, _html} = live(conn, ~p"/scout")

      default_window = render_patch(view, ~p"/scout/spawns")
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
      render_patch(view, ~p"/scout/spawns")

      fresh = view |> element("#scout-fresh-spawns") |> render()

      # One row for the repeated spawn, carrying the newer sighting's value...
      assert fresh =~ "777.0M"
      refute fresh =~ "50.0M"

      # ...and a separate row for a different spawn in the same belt.
      assert fresh =~ "True Sansha Mutant"
      assert fresh =~ "999.0M"
    end

    test "the 24h list ignores the window selector", %{conn: conn} do
      spawn_sighting(%{spawn_name: "Just Landed", observed_at: ago(60)})
      spawn_sighting(%{spawn_name: "Days Ago", observed_at: ago(60 * 30)})

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_patch(view, ~p"/scout/spawns")

      fresh = view |> element("#scout-fresh-spawns") |> render()
      log = view |> element("#scout-spawns") |> render()

      assert fresh =~ "Just Landed"
      refute fresh =~ "Days Ago"

      # Still in the (default 7-day) window-bounded log below it.
      assert log =~ "Days Ago"
    end

    test "the tick ages a spawn out of the 24h list with no query", %{conn: conn} do
      # Mirrors the structures tab's expiring-timer test, scaled to the
      # list's 24-hour horizon instead of a timer's expiry: insert
      # 1s inside the horizon, let 1.1s of real time pass, and the tick
      # (no query) drops it exactly like an expired timer does.
      edge = DateTime.utc_now() |> DateTime.add(-86_399, :second) |> DateTime.truncate(:second)
      spawn_sighting(%{spawn_name: "Expiring Pop", observed_at: edge})

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_patch(view, ~p"/scout/spawns")
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
      render_patch(view, ~p"/scout/spawns")

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

    test "it narrows the spawn log and the 24h list together", %{conn: conn} do
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
      render_patch(view, ~p"/scout/spawns")

      render_click(view, "toggle_space", %{"type" => "hs"})

      for id <- ~w(#scout-spawns #scout-fresh-spawns) do
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

  # CHEWY PATCH: the paste box. `WandererAppWeb.ScoutDiscord` has its own
  # unit tests for the format and the 2000-character budget; what is
  # asserted here is the thing only the page can get wrong — that the
  # message is built from the rows the reader is actually looking at,
  # filters included.
  describe "the Discord paste box" do
    test "a running timer is pasted as Discord's own live markup", %{conn: conn} do
      expires = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

      structure(%{
        structure_id: 1_000_000_000_900,
        structure_name: "Discord Keepstar",
        status: "ArmorReinforced",
        observed_at: ago(5),
        timer_expires_at: expires
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      paste = render_click(view, "discord", %{"board" => "timers"})

      assert paste =~ "scout-discord"
      assert paste =~ "Discord Keepstar"
      # The countdown is Discord's, so it keeps running in the channel.
      assert paste =~ "&lt;t:#{DateTime.to_unix(expires)}:R&gt;"
    end

    test "the paste carries the page's filters", %{conn: conn} do
      expires = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      structure(%{
        structure_id: 1_000_000_000_901,
        structure_name: "Jita Timer",
        solar_system_id: @jita,
        observed_at: ago(5),
        timer_expires_at: expires
      })

      structure(%{
        structure_id: 1_000_000_000_902,
        structure_name: "Amarr Timer",
        solar_system_id: @amarr,
        observed_at: ago(5),
        timer_expires_at: expires
      })

      {:ok, view, _html} = live(conn, ~p"/scout")
      render_click(view, "filter_system", %{"id" => to_string(@amarr)})

      paste = render_click(view, "discord", %{"board" => "timers"})

      assert paste =~ "Amarr Timer"
      refute paste =~ "Jita Timer"
    end

    test "the digest leads with the rarest finding and closes", %{conn: conn} do
      structure(%{
        structure_id: 1_000_000_000_903,
        structure_name: "Free Fortizar",
        status: "Unanchored",
        observed_at: ago(30)
      })

      {:ok, view, _html} = live(conn, ~p"/scout")

      digest = render_click(view, "discord", %{"board" => "digest"})

      assert digest =~ "Scout report"
      assert digest =~ "Free Fortizar"

      refute render_click(view, "close_discord", %{}) =~ "scout-discord-text"
    end

    test "an unknown board is ignored rather than crashing the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/scout")

      refute render_click(view, "discord", %{"board" => "nonsense"}) =~ "scout-discord-text"
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
