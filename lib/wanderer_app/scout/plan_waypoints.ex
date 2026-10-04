defmodule WandererApp.Scout.PlanWaypoints do
  @moduledoc """
  CHEWY PATCH: pushes a `WandererApp.Scout.Planner` plan onto a
  character's in-game autopilot through ESI
  (`POST /ui/autopilot/waypoint`).

  ## Why the server does this and not the bot

  A multi-stop CUSTOM route cannot be set from the client side. eveknob
  can set a single DESTINATION (`ISXBob:SetDestination`, field-proven in
  `obj_Travel.iss`), but an ordered list of waypoints only goes in
  through ESI -- which is why the push lives here, where the character's
  token already is. The fork is an EVE SSO app whose `default_scope`
  has always included `esi-ui.write_waypoint.v1` (`config/runtime.exs`),
  and the map's own "set destination" button already uses exactly this
  call (`MapRoutesEventHandler.set_autopilot_waypoint/5`), so this adds
  no scope, no credential and no new ESI surface.

  ## Order is the whole point

  ESI has no "set these N systems" call; it has one call per waypoint.
  The FIRST stop is sent with `clear_other_waypoints: true` (it replaces
  whatever route the character had), every later stop with
  `clear_other_waypoints: false` and `add_to_beginning: false`, so they
  land in plan order. Sequential on purpose -- `Task.async_stream` would
  race the ordering, and the plan's order IS the product.

  A failure stops the push rather than skipping a stop: a route missing
  its third system is not the route anybody asked for, and the half that
  already landed is still a valid prefix the pilot can see.

  Only `leg == :gate` stops are ever pushed (design section 6, mode A):
  EVE's own route planner cannot express a wormhole, so a chain stop
  silently becomes a k-space detour the long way round.
  """

  require Logger

  alias WandererApp.Api.Character

  @doc """
  Pushes `stops` onto `character_eve_id`'s autopilot, in order.

  Returns `{:ok, pushed_solar_system_ids}` -- possibly a PREFIX of the
  gate stops if ESI refused partway -- or `{:error, reason}` when the
  character is unknown to this instance or holds no usable token.
  """
  @spec push([map()], String.t() | integer()) ::
          {:ok, [integer()]} | {:error, :unknown_character | :no_gate_stops}
  def push(stops, character_eve_id) do
    gate_stops = Enum.filter(stops, &(&1.leg == :gate))

    # Stops first, character second: "there is nothing to fly" is true
    # regardless of who asked, and answering it costs no query.
    with :ok <- require_stops(gate_stops),
         {:ok, character} <- fetch_character(character_eve_id) do
      {:ok, do_push(gate_stops, character.id)}
    end
  end

  defp fetch_character(character_eve_id) do
    case Character.by_eve_id(to_string(character_eve_id)) do
      {:ok, character} -> {:ok, character}
      _error -> {:error, :unknown_character}
    end
  end

  defp require_stops([]), do: {:error, :no_gate_stops}
  defp require_stops(_stops), do: :ok

  defp do_push(gate_stops, character_id) do
    gate_stops
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {stop, index}, pushed ->
      case set_waypoint(character_id, stop.solar_system_id, index == 0) do
        :ok ->
          {:cont, [stop.solar_system_id | pushed]}

        {:error, reason} ->
          Logger.warning(
            "[scout planner] waypoint push stopped at #{stop.solar_system_id} " <>
              "(stop #{index + 1}): #{inspect(reason)}"
          )

          {:halt, pushed}
      end
    end)
    |> Enum.reverse()
  end

  # `WandererApp.Character.set_autopilot_waypoint/3` answers `:ok`
  # unconditionally (it is fire-and-forget for the map's own button), and
  # it MATCHES on the character lookup, so a character with no cached
  # token raises rather than returning. Both are wrong for a route, where
  # stop 3 failing changes what stop 4 means -- so the rescue is the
  # error channel this module needs, not defensive padding.
  defp set_waypoint(character_id, destination_id, first?) do
    WandererApp.Character.set_autopilot_waypoint(character_id, destination_id,
      add_to_beginning: false,
      clear_other_waypoints: first?
    )

    :ok
  rescue
    error -> {:error, error}
  end
end
