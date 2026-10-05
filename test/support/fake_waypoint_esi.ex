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
           fn -> %{online: true, waypoints: {:ok, ""}, fail_from: nil, calls: []} end,
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
      |> Map.put(:calls, [])
    end)
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
