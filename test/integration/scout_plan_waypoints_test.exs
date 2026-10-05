defmodule WandererApp.Scout.PlanWaypointsTest do
  @moduledoc """
  What a `Set route` click is allowed to claim.

  This module shipped reporting success for every push: it called
  `WandererApp.Character.set_autopilot_waypoint/3`, which discards ESI's
  answer and returns `:ok` unconditionally (correct for the map's
  fire-and-forget destination button, a lie for a route), so "Route set
  on X: 86 waypoints" was printed whether ESI wrote the route, refused
  the token, or was never reached. It was reported from the field as
  "I set a route for Molden Heath and it never arrived in game", and the
  server log had nothing in it either.

  Pinned here, each one a thing a reader must be told and could not be:

    * ESI refusing every stop is an ERROR with the reason, not a route;
    * a refusal partway reports the stop it stopped at and the prefix
      that did land;
    * a token the preflight cannot use sends NOTHING -- a dead token
      must not write half a route;
    * a pilot whose client is not running is reported, because EVE
      accepts the waypoint (204) and discards it;
    * 204 counts as success, which is the ONLY success ESI documents
      for `/ui/autopilot/waypoint`.

  The ESI module is swapped through the `:esi_module` application env --
  the same injection idiom as `WandererApp.CachedInfo.get_character_names/2`
  -- because the real one would write a route onto a real pilot.
  """

  use WandererAppWeb.IntegrationConnCase, async: false

  import WandererAppWeb.Factory

  alias WandererApp.Scout.PlanWaypoints

  @stops [
    %{solar_system_id: 30_002_053, leg: :gate},
    %{solar_system_id: 30_002_054, leg: :gate},
    %{solar_system_id: 30_002_055, leg: :gate}
  ]

  setup do
    {:ok, _pid} = FakeWaypointEsi.start_link()
    Application.put_env(:wanderer_app, :esi_module, FakeWaypointEsi)

    on_exit(fn -> Application.delete_env(:wanderer_app, :esi_module) end)

    user = insert(:user)
    character = insert(:character, %{user_id: user.id})

    # The factory persists no token (the create action does not accept
    # one), and `preflight/1` refuses to push without a usable token --
    # correctly, which is why every test here would otherwise assert
    # that refusal instead of what it is about.
    {:ok, character} =
      WandererApp.Api.Character.update(character, %{
        access_token: "test-access-token",
        expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
      })

    Cachex.del(:character_cache, character.id)

    %{character: character}
  end

  describe "when ESI accepts the route" do
    test "204 is a success, and every stop is reported as pushed", %{character: character} do
      FakeWaypointEsi.script(online: true, waypoints: {:ok, ""})

      assert {:ok, result} = PlanWaypoints.push(@stops, character.eve_id)

      assert result.pushed == [30_002_053, 30_002_054, 30_002_055]
      assert result.total == 3
      assert result.error == nil
      assert result.online? == true

      # The first stop replaces the pilot's route, the rest extend it --
      # the order IS the product.
      assert [{_, true}, {_, false}, {_, false}] = FakeWaypointEsi.waypoint_calls()
    end

    test "a pilot whose client is not running is reported, not called a route", %{
      character: character
    } do
      FakeWaypointEsi.script(online: false, waypoints: {:ok, ""})

      assert {:ok, result} = PlanWaypoints.push(@stops, character.eve_id)

      assert result.pushed == [30_002_053, 30_002_054, 30_002_055]
      assert result.online? == false
    end
  end

  describe "when ESI refuses" do
    test "a refusal on the first stop leaves no route and names the reason", %{
      character: character
    } do
      FakeWaypointEsi.script(online: true, waypoints: {:error, :forbidden})

      assert {:ok, result} = PlanWaypoints.push(@stops, character.eve_id)

      assert result.pushed == []
      assert result.error.index == 0
      assert result.error.solar_system_id == 30_002_053
      assert result.error.reason == :forbidden
    end

    test "a refusal partway keeps the prefix and says where it stopped", %{character: character} do
      FakeWaypointEsi.script(online: true, waypoints: {:ok, ""}, fail_from: 2)

      assert {:ok, result} = PlanWaypoints.push(@stops, character.eve_id)

      assert result.pushed == [30_002_053, 30_002_054]
      assert result.error.index == 2
      assert result.error.solar_system_id == 30_002_055

      # Halt, never skip: a route missing its third system is not the
      # route anybody asked for.
      assert length(FakeWaypointEsi.waypoint_calls()) == 3
    end

    test "an error-limited answer carries its reason through the 3-tuple", %{
      character: character
    } do
      FakeWaypointEsi.script(online: true, waypoints: {:error, :error_limited, []})

      assert {:ok, result} = PlanWaypoints.push(@stops, character.eve_id)

      assert result.error.reason == :error_limited
    end
  end

  describe "when the token cannot be used" do
    test "nothing is pushed at all", %{character: character} do
      FakeWaypointEsi.script(online: {:error, :forbidden}, waypoints: {:ok, ""})

      assert {:error, {:token, :forbidden}} = PlanWaypoints.push(@stops, character.eve_id)
      assert FakeWaypointEsi.waypoint_calls() == []
    end
  end

  describe "what never reaches ESI" do
    test "a chain stop is not a waypoint, and a plan of them has nothing to fly", %{
      character: character
    } do
      FakeWaypointEsi.script(online: true, waypoints: {:ok, ""})

      stops = [%{solar_system_id: 31_000_001, leg: :chain}]

      assert {:error, :no_gate_stops} = PlanWaypoints.push(stops, character.eve_id)
      assert FakeWaypointEsi.waypoint_calls() == []
    end

    test "a character this instance does not know is refused before any call" do
      FakeWaypointEsi.script(online: true, waypoints: {:ok, ""})

      assert {:error, :unknown_character} = PlanWaypoints.push(@stops, "90000001")
      assert FakeWaypointEsi.waypoint_calls() == []
    end
  end
end
