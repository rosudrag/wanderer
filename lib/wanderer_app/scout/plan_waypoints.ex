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

  ## Why a preflight call

  `WandererApp.Character.set_autopilot_waypoint/3` discards ESI's answer
  and returns `:ok` unconditionally -- correct for the map's
  fire-and-forget button, useless for a route, where this page told the
  reader "Route set: 86 waypoints" whether ESI wrote the route, refused
  the token or was never reached. So the push calls
  `WandererApp.Esi.set_autopilot_waypoint/4` itself and reads the result.

  Reading the result is only half of it: the POST path has NO
  refresh-on-403 retry (`do_get_retry/5` is the GET path's), so an
  EXPIRED access token -- normal for a character not currently tracked on
  an open map -- is a silent 403 on every stop. The preflight is one
  authenticated GET (`/characters/{id}/online`), which goes through
  `get_character_auth_data/3` and therefore refreshes and persists the
  token before the first waypoint, and answers the second question this
  page could not answer either: EVE applies waypoints only to a RUNNING
  client, so a route pushed at a logged-out pilot is accepted by ESI
  (204) and lands nowhere.
  """

  require Logger

  alias WandererApp.Api.Character

  @type result :: %{
          pushed: [integer()],
          total: non_neg_integer(),
          online?: boolean() | nil,
          error: nil | %{index: non_neg_integer(), solar_system_id: integer(), reason: term()}
        }

  # Same `:esi_module` test-injection idiom as
  # `WandererApp.CachedInfo.get_character_names/2`: the failure handling
  # here is the whole point of the module, and asserting it against live
  # ESI would mean writing a real route onto a real pilot from a test
  # run.
  defp esi, do: Application.get_env(:wanderer_app, :esi_module, WandererApp.Esi)

  @doc """
  Pushes `stops` onto `character_eve_id`'s autopilot, in order.

  Returns `{:ok, result}` where `:pushed` may be a PREFIX of the gate
  stops and `:error` carries the stop ESI refused, or `{:error, reason}`
  when there was nothing to fly, the character is unknown to this
  instance, or its token could not be made usable.
  """
  @spec push([map()], String.t() | integer()) ::
          {:ok, result()}
          | {:error, :unknown_character | :no_gate_stops | {:token, term()}}
  def push(stops, character_eve_id) do
    gate_stops = Enum.filter(stops, &(&1.leg == :gate))

    # Stops first, character second: "there is nothing to fly" is true
    # regardless of who asked, and answering it costs no query.
    with :ok <- require_stops(gate_stops),
         {:ok, character} <- fetch_character(character_eve_id),
         {:ok, token, online?} <- preflight(character) do
      {:ok, do_push(gate_stops, character, token, online?)}
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

  # One authenticated GET that refreshes an expired token as a side
  # effect (`get_character_auth_data/3` routes an expired token through
  # `do_get_retry/5`) and reports whether the pilot's client is running.
  defp preflight(%{id: id, eve_id: eve_id}) do
    with {:ok, %{access_token: token}} when is_binary(token) <-
           WandererApp.Character.get_character(id),
         {:ok, body} <-
           esi().get_character_online(eve_id,
             access_token: token,
             character_id: id,
             refresh_token?: true
           ) do
      {:ok, current_token(id, token), online_flag(body)}
    else
      {:ok, _no_token} -> {:error, {:token, :no_token}}
      {:error, reason} -> {:error, {:token, reason}}
      {:error, reason, _headers} -> {:error, {:token, reason}}
      other -> {:error, {:token, other}}
    end
  rescue
    error -> {:error, {:token, error}}
  end

  defp online_flag(%{"online" => online?}) when is_boolean(online?), do: online?
  defp online_flag(_body), do: nil

  # The refresh above rewrites the cached character, so the token to push
  # with is the one in the cache NOW, not the one read before the call.
  defp current_token(character_id, fallback) do
    case WandererApp.Character.get_character(character_id) do
      {:ok, %{access_token: token}} when is_binary(token) -> token
      _other -> fallback
    end
  end

  defp do_push(gate_stops, character, token, online?) do
    total = length(gate_stops)

    {pushed, error} =
      gate_stops
      |> Enum.with_index()
      |> Enum.reduce_while({[], nil}, fn {stop, index}, {pushed, _error} ->
        case set_waypoint(token, stop.solar_system_id, index == 0) do
          :ok ->
            {:cont, {[stop.solar_system_id | pushed], nil}}

          {:error, reason} ->
            {:halt,
             {pushed,
              %{index: index, solar_system_id: stop.solar_system_id, reason: reason}}}
        end
      end)

    result = %{
      pushed: Enum.reverse(pushed),
      total: total,
      online?: online?,
      error: error
    }

    log(character, result)

    result
  end

  # The push left no trace in the server log at all, which is why the
  # first report of "I set a route and nothing happened" had nothing to
  # read. One line per push, at `warning` when it was not whole.
  defp log(character, %{pushed: pushed, total: total, online?: online?, error: error}) do
    message =
      "[scout planner] waypoint push for #{character.name} (#{character.eve_id}): " <>
        "#{length(pushed)}/#{total} stops, online=#{inspect(online?)}" <>
        if error, do: ", stopped at #{error.solar_system_id}: #{inspect(error.reason)}", else: ""

    if error || online? == false,
      do: Logger.warning(message),
      else: Logger.info(message)
  end

  # `WandererApp.Esi.set_autopilot_waypoint/4` answers ESI's own result
  # (204 included, since `do_post_esi/3` counts it as success). The
  # rescue stays because a token that vanished between the preflight and
  # here raises rather than returning.
  defp set_waypoint(access_token, destination_id, first?) do
    case esi().set_autopilot_waypoint(false, first?, destination_id,
           access_token: access_token
         ) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, _headers} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    error -> {:error, error}
  end
end
