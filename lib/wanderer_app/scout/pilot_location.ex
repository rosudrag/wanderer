defmodule WandererApp.Scout.PilotLocation do
  @moduledoc """
  CHEWY PATCH (pilot start): where one of this user's characters actually
  is, right now, so `/scout/planner` can start a route there instead of
  making the reader type the name of the system they are sitting in.

  Every start picker on that page is a system SEARCH -- the operator
  reads the system name off the game client and types it back into the
  browser, once per pilot, every time anybody undocks somewhere else.
  The app already holds each tracked character's token with
  `esi-location.read_location.v1` in `default_scope` (`config/runtime.exs`),
  which is the same credential `WandererApp.Character.Tracker` polls with,
  so the answer is one authenticated GET away.

  Two sources, in this order, and the caller is told which one answered:

    * `:esi` -- `GET /characters/{id}/location/` through
      `WandererApp.Esi.get_character_location/2` with `refresh_token?: true`,
      so an expired token is refreshed by the GET path's own
      `do_get_retry/5` (the trap `WandererApp.Scout.PlanWaypoints`
      documents: the POST path has no such retry). This is the only
      source that is true for a character nobody is tracking on an open
      map.
    * `:tracked` -- the `solar_system_id` column on the character row,
      written by the tracker. Used ONLY when ESI refused, because it is
      as old as the last time that character was tracked, which may be
      never.

  A character with neither is an error, never a silent "no start": a
  route that quietly opened somewhere else is the exact failure the
  searchable start picker was added to fix.
  """

  require Logger

  alias WandererApp.Api.{Character, MapSolarSystem}

  # Same `:esi_module` test-injection idiom as
  # `WandererApp.Scout.PlanWaypoints`: asserting the fallback order
  # against live ESI would mean a test depending on where a real pilot
  # is parked.
  defp esi, do: Application.get_env(:wanderer_app, :esi_module, WandererApp.Esi)

  @type location :: %{
          solar_system_id: pos_integer(),
          name: String.t(),
          source: :esi | :tracked
        }

  @type error :: :unknown_character | :no_location | {:esi, term()} | {:token, term()}

  @doc """
  Resolves one character's current system by EVE id.
  """
  @spec resolve(String.t() | integer() | nil) :: {:ok, location()} | {:error, error()}
  def resolve(nil), do: {:error, :unknown_character}

  def resolve(character_eve_id) do
    with {:ok, character} <- fetch_character(character_eve_id) do
      case live_location(character) do
        {:ok, solar_system_id} ->
          {:ok, describe(solar_system_id, :esi)}

        {:error, reason} ->
          case character.solar_system_id do
            id when is_integer(id) and id > 0 ->
              Logger.debug(fn ->
                "[scout planner] ESI location for #{character.eve_id} failed " <>
                  "(#{inspect(reason)}); using the tracked location"
              end)

              {:ok, describe(id, :tracked)}

            _none ->
              {:error, reason}
          end
      end
    end
  end

  defp fetch_character(character_eve_id) do
    case Character.by_eve_id(to_string(character_eve_id)) do
      {:ok, character} -> {:ok, character}
      _error -> {:error, :unknown_character}
    end
  end

  defp live_location(%{id: id, eve_id: eve_id}) do
    with {:ok, %{access_token: token}} when is_binary(token) <-
           WandererApp.Character.get_character(id),
         {:ok, body} <-
           esi().get_character_location(eve_id,
             access_token: token,
             character_id: id,
             refresh_token?: true
           ),
         solar_system_id when is_integer(solar_system_id) <- system_id(body) do
      {:ok, solar_system_id}
    else
      {:ok, _no_token} -> {:error, {:token, :no_token}}
      nil -> {:error, :no_location}
      {:error, reason} -> {:error, {:esi, reason}}
      {:error, reason, _headers} -> {:error, {:esi, reason}}
      other -> {:error, {:esi, other}}
    end
  rescue
    error -> {:error, {:esi, error}}
  end

  defp system_id(%{"solar_system_id" => id}) when is_integer(id) and id > 0, do: id
  defp system_id(_body), do: nil

  # A J-space or Pochven system is a perfectly good answer here even
  # though `WandererApp.Scout.Planner.graph/0` has no node for it -- the
  # routers report an unreachable start rather than dropping it, and
  # naming the system is what lets the reader see why.
  defp describe(solar_system_id, source) do
    %{solar_system_id: solar_system_id, name: system_name(solar_system_id), source: source}
  end

  defp system_name(solar_system_id) do
    case MapSolarSystem.by_solar_system_id(solar_system_id) do
      {:ok, %{solar_system_name: name}} when is_binary(name) -> name
      _other -> to_string(solar_system_id)
    end
  end
end
