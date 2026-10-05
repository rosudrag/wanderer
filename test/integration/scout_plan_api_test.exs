defmodule WandererAppWeb.ScoutPlanAPITest do
  @moduledoc """
  The WIRE contract of `GET /api/maps/:map_identifier/scout/plan`, which
  is the half of the planner a compiler cannot check: eveknob parses the
  `flat` body with `${str.Token[n,"|"]}` and refuses the whole plan on an
  unrecognised header version (`obj_ScoutPlanner.iss`), so a stray
  newline, a renamed field or a reordered column breaks the bot silently
  while every Elixir test still passes.

  Asserted here, in the order the bot depends on them:

    * flag off => 404 (`WANDERER_SCOUT_PLANNER`), flag on => 200;
    * `flat` is ONE line: `#plan 1 ...` then `;`-joined records, each
      `sysid|name|score|reason|age_s|jumps|leg`;
    * `text` is the same records, one per line, for a human with curl;
    * a kind outside the closed vocabulary is a 422, not a silent
      fallback to `sigs`.

  See `docs/design/wanderer-scout-planner.md` sections 6-7 and
  `test/integration/scout_planner_test.exs` (the ranking-core sibling).
  """

  use WandererAppWeb.IntegrationConnCase, async: false

  import WandererAppWeb.Factory

  alias WandererApp.Api.{MapSolarSystem, MapSolarSystemJumps}

  # Outside any real EVE static data, like the ranking-core test's range.
  @origin 990_200_001
  @one_jump 990_200_002
  @two_jumps 990_200_003

  # No jump rows at all: BFS reaches nothing from it, so a plan over it is
  # empty and the push has nothing to send.
  @isolated 990_200_009

  # The one lowsec system in the fixture, three gates out through
  # highsec -- a band filter has to keep it and drop the two highsec
  # systems that lead to it.
  @lowsec 990_200_004

  setup do
    WandererApp.Cache.delete("scout:planner:adjacency")
    Application.put_env(:wanderer_app, :scout_planner_enabled, true)
    on_exit(fn -> Application.put_env(:wanderer_app, :scout_planner_enabled, false) end)

    put_system(@origin, "Planalpha", "1.0")
    put_system(@one_jump, "Planbravo", "0.9")
    put_system(@two_jumps, "Plancharlie", "0.8")
    put_system(@lowsec, "Plandelta", "0.3", 8)

    put_jump(@origin, @one_jump)
    put_jump(@one_jump, @two_jumps)
    put_jump(@two_jumps, @lowsec)

    user = insert(:user)
    character = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: character.id, name: "Plan Map"})

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{map.public_api_key || "test-api-key"}")
      |> assign(:current_character, character)
      |> assign(:current_user, user)

    %{conn: conn, map: map}
  end

  describe "the feature flag" do
    test "answers 404 with WANDERER_SCOUT_PLANNER off", %{conn: conn, map: map} do
      Application.put_env(:wanderer_app, :scout_planner_enabled, false)

      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?origin=#{@origin}")

      assert response(conn, 404)
    end
  end

  describe "format=flat (what the bot parses)" do
    test "is a single line of pipe-delimited records behind a versioned header", %{
      conn: conn,
      map: map
    } do
      conn =
        get(conn, ~p"/api/maps/#{map.id}/scout/plan?origin=#{@origin}&kind=sigs&format=flat")

      body = response(conn, 200)

      refute String.contains?(body, "\n")
      assert ["#plan 1 " <> header | records] = String.split(body, ";")
      assert header =~ "origin=#{@origin}"
      assert header =~ "kind=sigs"

      # Both neighbours are unscouted, so both rank; the bot only ever
      # waypoints `gate` legs, and a k-space-only graph is all gates.
      assert length(records) >= 1

      for record <- records do
        assert [sysid, name, score, reason, age_s, jumps, leg] = String.split(record, "|")
        assert {_id, ""} = Integer.parse(sysid)
        assert name != ""
        assert {_score, _} = Float.parse(score)
        assert reason in ~w(unseen stale fresh frontier)
        assert {_age, ""} = Integer.parse(age_s)
        assert {_jumps, ""} = Integer.parse(jumps)
        assert leg == "gate"
      end

      assert Enum.any?(records, &String.contains?(&1, "Planbravo"))

      # The origin must never be a stop: the client sets the first stop
      # as the EVE destination, and a destination equal to the current
      # system leaves no route, so the bot would declare the route
      # exhausted and re-fetch the identical plan forever without moving.
      refute Enum.any?(records, &String.starts_with?(&1, "#{@origin}|"))
    end
  end

  describe "format=text (what a human curls)" do
    test "is the same records, one per line, behind the same header", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?origin=#{@origin}&format=text")

      [header | lines] =
        conn
        |> response(200)
        |> String.split("\n", trim: true)

      assert header =~ ~r/^#plan 1 origin=#{@origin} kind=sigs generated=/
      assert Enum.all?(lines, &(length(String.split(&1, "|")) == 7))
    end
  end

  # CHEWY PATCH (security focus): "scout Metropolis, specifically the
  # lowsec". `security=` was read for `mode=sweep` only, so the same
  # parameter on the same endpoint was silently ignored in rank mode
  # even though `Planner.rank/1` has always taken the option. Silently,
  # which is the part worth a test: the caller got a full-band plan and
  # nothing said so.
  describe "security= (one band, either mode)" do
    test "rank mode narrows the candidates to the requested bands", %{conn: conn, map: map} do
      lines =
        conn
        |> get(~p"/api/maps/#{map.id}/scout/plan?origin=#{@origin}&format=text&security=ls")
        |> response(200)
        |> String.split("\n", trim: true)
        |> tl()

      assert Enum.any?(lines, &String.contains?(&1, "Plandelta"))
      refute Enum.any?(lines, &String.contains?(&1, "Planbravo"))
      refute Enum.any?(lines, &String.contains?(&1, "Plancharlie"))
    end

    test "an unrecognised band is refused, never a quiet narrowing", %{conn: conn, map: map} do
      conn =
        get(conn, ~p"/api/maps/#{map.id}/scout/plan?origin=#{@origin}&format=text&security=bogus")

      assert response(conn, 422)
    end
  end

  # The ESI call itself is not exercised here: `WandererApp.Esi` delegates
  # straight to `ApiClient` with no behaviour seam, so a passing push would
  # mean a real HTTP request to CCP from a test run. What IS asserted is
  # everything that decides WHETHER a push happens, which is where this
  # endpoint can refuse a pilot's route by accident.
  describe "POST .../scout/plan/waypoints (the ESI push)" do
    test "a character this instance does not know is refused", %{conn: conn, map: map} do
      conn =
        post(
          conn,
          ~p"/api/maps/#{map.id}/scout/plan/waypoints?origin=#{@origin}&character_eve_id=90000001"
        )

      assert response(conn, 422) =~ "unknown_character"
    end

    test "character_eve_id is required -- a route is pushed onto exactly one pilot", %{
      conn: conn,
      map: map
    } do
      conn = post(conn, ~p"/api/maps/#{map.id}/scout/plan/waypoints?origin=#{@origin}")

      assert response(conn, 422) =~ "character_eve_id"
    end

    test "an isolated origin yields no gate stops, and says so", %{conn: conn, map: map} do
      put_system(@isolated, "Planisolated", "0.7")

      conn =
        post(
          conn,
          ~p"/api/maps/#{map.id}/scout/plan/waypoints?origin=#{@isolated}&character_eve_id=90000001"
        )

      assert response(conn, 422) =~ "no_gate_stops"
    end

    test "the flag gates the push as well as the read", %{conn: conn, map: map} do
      Application.put_env(:wanderer_app, :scout_planner_enabled, false)

      conn =
        post(
          conn,
          ~p"/api/maps/#{map.id}/scout/plan/waypoints?origin=#{@origin}&character_eve_id=90000001"
        )

      assert response(conn, 404)
    end
  end

  describe "param validation" do
    test "a kind outside the closed vocabulary is refused, never defaulted", %{
      conn: conn,
      map: map
    } do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?origin=#{@origin}&kind=bogus")

      assert response(conn, 422)
    end

    test "origin is required", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan")

      assert response(conn, 422)
    end
  end

  defp put_system(solar_system_id, name, security, system_class \\ 7) do
    {:ok, _system} =
      MapSolarSystem
      |> Ash.Changeset.for_create(:create, %{
        solar_system_id: solar_system_id,
        solar_system_name: name,
        solar_system_name_lc: String.downcase(name),
        region_id: 1,
        region_name: "Plan Region",
        constellation_id: 1,
        constellation_name: "Plan Constellation",
        system_class: system_class,
        security: security
      })
      |> Ash.create(authorize?: false)
  end

  defp put_jump(from_id, to_id) do
    {:ok, _jump} =
      MapSolarSystemJumps
      |> Ash.Changeset.for_create(:create, %{
        from_solar_system_id: from_id,
        to_solar_system_id: to_id
      })
      |> Ash.create(authorize?: false)
  end
end
