defmodule FakeWaypointEsi do
  @moduledoc """
  Scripted stand-in for `WandererApp.Esi`, injected through the
  `:esi_module` application env. Records every waypoint call as
  `{destination_id, clear_other_waypoints}` so the test can assert
  ORDER semantics, not just counts.
  """

  use Agent

  def start_link(_opts \\ []) do
    case Agent.start_link(
           fn ->
             %{online: true, waypoints: {:ok, ""}, fail_from: nil, calls: [], location: nil}
           end,
           name: __MODULE__
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def script(opts) do
    Agent.update(__MODULE__, fn state ->
      state
      |> Map.put(:online, Keyword.get(opts, :online, true))
      |> Map.put(:waypoints, Keyword.get(opts, :waypoints, {:ok, ""}))
      |> Map.put(:fail_from, Keyword.get(opts, :fail_from))
      # CHEWY PATCH (pilot start): what `GET /characters/{id}/location/`
      # answers. `nil` means "not scripted" and is reported as a refusal,
      # so a test that forgot to script it cannot pass by accident.
      |> Map.put(:location, Keyword.get(opts, :location))
      |> Map.put(:calls, [])
    end)
  end

  def get_character_location(_eve_id, _opts) do
    case Agent.get(__MODULE__, & &1.location) do
      nil ->
        {:error, :forbidden}

      solar_system_id when is_integer(solar_system_id) ->
        {:ok, %{"solar_system_id" => solar_system_id}}

      other ->
        other
    end
  end

  def waypoint_calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def get_character_online(_eve_id, _opts) do
    case Agent.get(__MODULE__, & &1.online) do
      online when is_boolean(online) -> {:ok, %{"online" => online}}
      other -> other
    end
  end

  def set_autopilot_waypoint(_add_to_beginning, clear_other_waypoints, destination_id, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      index = length(state.calls)
      calls = [{destination_id, clear_other_waypoints} | state.calls]

      answer =
        cond do
          state.fail_from && index >= state.fail_from -> {:error, :forbidden}
          true -> state.waypoints
        end

      {answer, %{state | calls: calls}}
    end)
  end
end
