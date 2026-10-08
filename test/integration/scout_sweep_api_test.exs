defmodule WandererAppWeb.ScoutSweepAPITest do
  @moduledoc """
  The WIRE contract of `GET /api/maps/:map_identifier/scout/plan?mode=sweep`
  -- `#plan 2`, a version `obj_ScoutPlanner.iss` does not know and must
  refuse rather than fly (design doc "only crossroads become waypoints"
  section): a client that cannot tell a pushed waypoint from a
  pass-through would silently fly a sweep with holes in it. Asserted
  here, in the order a sweep client depends on them:

    * `mode=sweep` answers `#plan 2`, one column longer than `#plan 1`
      (`sysid|name|score|reason|age_s|jumps|leg|wp`), and compression
      produces a `wp` flag that is NOT all `1` -- a straight 4-system
      chain has exactly two crossroads (its own ends);
    * `compress=0` keeps every stop a waypoint (`wp` all `1`);
    * `mode=rank`/absent is untouched: still `#plan 1`, 7 columns;
    * `scope` is required and capped at 3 regions (design doc section 9);
    * the feature flag gates `mode=sweep` the same way it gates
      `mode=rank`.

  See `docs/design/wanderer-scout-region-sweeps.md` sections 3 and 6,
  and `test/integration/scout_plan_api_test.exs` (the rank-mode sibling,
  untouched by this change).
  """

  use WandererAppWeb.IntegrationConnCase, async: false

  import WandererAppWeb.Factory

  alias WandererApp.Api.{MapSolarSystem, MapSolarSystemJumps}

  # Outside any real EVE static data, like the rank-mode sibling test's
  # range. A straight 4-system chain: s1 -- s2 -- s3 -- s4, one region,
  # so the ONLY shortest path between s1 and s4 runs through s2 and s3
  # -- exactly the case design section 6's compression rule drops.
  @region 991_000_001
  @s1 990_400_001
  @s2 990_400_002
  @s3 990_400_003
  @s4 990_400_004

  setup do
    WandererApp.Cache.delete("scout:planner:adjacency")
    Application.put_env(:wanderer_app, :scout_planner_enabled, true)
    on_exit(fn -> Application.put_env(:wanderer_app, :scout_planner_enabled, false) end)

    put_system(@s1, "Sweepalpha")
    put_system(@s2, "Sweepbravo")
    put_system(@s3, "Sweepcharlie")
    put_system(@s4, "Sweepdelta")

    put_jump(@s1, @s2)
    put_jump(@s2, @s3)
    put_jump(@s3, @s4)

    user = insert(:user)
    character = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: character.id, name: "Sweep Map"})

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{map.public_api_key || "test-api-key"}")
      |> assign(:current_character, character)
      |> assign(:current_user, user)

    %{conn: conn, map: map}
  end

  describe "mode=sweep, format=flat" do
    test "is `#plan 2`, 8 columns, and compression leaves a wp flag that is not all 1", %{
      conn: conn,
      map: map
    } do
      conn =
        get(
          conn,
          ~p"/api/maps/#{map.id}/scout/plan?mode=sweep&scope=region:#{@region}&kind=sigs&format=flat"
        )

      body = response(conn, 200)

      refute String.contains?(body, "\n")
      assert ["#plan 2 " <> header | records] = String.split(body, ";")
      assert header =~ "kind=sigs"
      assert header =~ "scope=region:#{@region}"
      assert header =~ "compressed=1"

      assert length(records) == 4

      wp_flags =
        for record <- records do
          fields = String.split(record, "|")
          assert length(fields) == 8

          [sysid, name, score, reason, age_s, jumps, leg, wp] = fields

          assert {_id, ""} = Integer.parse(sysid)
          assert name != ""
          assert score == ""
          assert reason in ~w(unseen stale fresh)
          assert {_age, ""} = Integer.parse(age_s)
          assert {_jumps, ""} = Integer.parse(jumps)
          assert leg == "gate"
          assert wp in ~w(0 1)
          wp
        end

      # The chain's two ends are crossroads (nothing to compress past
      # them); its two middle systems are forced pass-throughs with no
      # alternate shortest path, so compression drops them.
      assert "0" in wp_flags
      assert "1" in wp_flags
    end

    test "compress=0 keeps every stop a waypoint", %{conn: conn, map: map} do
      conn =
        get(
          conn,
          ~p"/api/maps/#{map.id}/scout/plan?mode=sweep&scope=region:#{@region}&format=flat&compress=0"
        )

      body = response(conn, 200)
      assert ["#plan 2 " <> header | records] = String.split(body, ";")
      assert header =~ "compressed=0"

      wp_flags =
        for record <- records do
          record |> String.split("|") |> List.last()
        end

      assert Enum.all?(wp_flags, &(&1 == "1"))
    end
  end

  describe "mode=rank / absent is untouched" do
    test "still answers `#plan 1`, 7 columns", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?origin=#{@s1}&format=flat")

      body = response(conn, 200)
      assert ["#plan 1 " <> _header | records] = String.split(body, ";")
      assert Enum.all?(records, &(length(String.split(&1, "|")) == 7))
    end

    test "mode=rank explicitly behaves the same as absent", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=rank&origin=#{@s1}&format=flat")

      assert ["#plan 1 " <> _header | _records] = conn |> response(200) |> String.split(";")
    end
  end

  describe "scope validation" do
    test "scope is required", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=sweep")
      assert response(conn, 422) =~ "scope"
    end

    test "more than 3 regions is refused, not silently capped", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=sweep&scope=region:1,2,3,4")

      assert response(conn, 422) =~ "3"
    end

    test "an unknown mode is refused", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=bogus")
      assert response(conn, 422)
    end
  end

  test "the feature flag gates mode=sweep the same way it gates mode=rank", %{
    conn: conn,
    map: map
  } do
    Application.put_env(:wanderer_app, :scout_planner_enabled, false)

    conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=sweep&scope=region:#{@region}")

    assert response(conn, 404)
  end

  # CHEWY PATCH (target routing): `mode=targets` answers the SAME
  # `#plan 2` a sweep does -- a bot that can fly one can fly the other --
  # and says which it got through the `scope=systems:…` token. Its
  # candidate set comes from `scout_structures_v1`, so there is no
  # `scope` parameter at all.
  describe "mode=targets" do
    setup do
      since = DateTime.add(DateTime.utc_now(), -1, :day)
      put_structure(990_400_901, @s2, "Unanchoring", since)
      put_structure(990_400_902, @s4, "Unanchoring", since)
      # A different family: absent unless `families` asks for it.
      put_structure(990_400_903, @s1, "NoFuel", nil)
      :ok
    end

    test "answers #plan 2 over the systems a finding names", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=targets&format=flat")

      body = response(conn, 200)

      refute String.contains?(body, "\n")
      assert ["#plan 2 " <> header | records] = String.split(body, ";")
      assert header =~ "scope=systems:"
      assert length(records) == 2

      ids = Enum.map(records, &(&1 |> String.split("|") |> hd()))
      assert Enum.sort(ids) == Enum.sort(["#{@s2}", "#{@s4}"])
    end

    test "families widens the candidate set and ignore narrows it", %{conn: conn, map: map} do
      conn =
        get(
          conn,
          ~p"/api/maps/#{map.id}/scout/plan?mode=targets&families=unanchoring,dead&ignore=#{@s4}&format=flat"
        )

      body = response(conn, 200)
      [_header | records] = String.split(body, ";")
      ids = Enum.map(records, &(&1 |> String.split("|") |> hd()))

      assert Enum.sort(ids) == Enum.sort(["#{@s1}", "#{@s2}"])
    end

    test "an unknown family is refused rather than silently ignored", %{conn: conn, map: map} do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=targets&families=bogus")
      assert response(conn, 422) =~ "families"
    end

    test "nothing matching is a 422 naming the reason, not an empty route", %{
      conn: conn,
      map: map
    } do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=targets&families=unanchored")
      assert response(conn, 422) =~ "no_targets"
    end

    test "the feature flag gates it", %{conn: conn, map: map} do
      Application.put_env(:wanderer_app, :scout_planner_enabled, false)

      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=targets")

      assert response(conn, 404)
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

  # `format=json` answered a 500 for every sweep until the scope tuple
  # was rendered as its token: Jason refuses a tuple, and nothing on the
  # wire path had ever asked for JSON.
  describe "format=json" do
    test "a sweep encodes, with scope as the same token the text header carries", %{
      conn: conn,
      map: map
    } do
      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=sweep&scope=region:#{@region}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["scope"] == "region:#{@region}"
      assert length(data["stops"]) == 4
    end

    test "a target run encodes its findings envelope", %{conn: conn, map: map} do
      since = DateTime.add(DateTime.utc_now(), -1, :day)
      put_structure(990_400_911, @s2, "Unanchoring", since)

      conn = get(conn, ~p"/api/maps/#{map.id}/scout/plan?mode=targets")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["route"]["scope"] =~ "systems:"
      assert %{"structures" => 1} = data["targets"]["#{@s2}"]
      assert data["excluded"]["ignored"] == 0
    end
  end

  defp put_system(solar_system_id, name) do
    {:ok, _system} =
      MapSolarSystem
      |> Ash.Changeset.for_create(:create, %{
        solar_system_id: solar_system_id,
        solar_system_name: name,
        solar_system_name_lc: String.downcase(name),
        region_id: @region,
        region_name: "Sweep Region",
        constellation_id: 1,
        constellation_name: "Sweep Constellation",
        system_class: 7,
        security: "0.8"
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
