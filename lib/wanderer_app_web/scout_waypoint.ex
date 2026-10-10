defmodule WandererAppWeb.ScoutWaypoint do
  @moduledoc """
  CHEWY PATCH: one place every `/scout` button that writes a waypoint
  reports through.

  `WandererApp.Scout.PlanWaypoints` does the ESI work; this turns its
  result into the sentence a reader sees. It exists as its own module
  because there are now two callers with nothing else in common —
  `WandererAppWeb.ScoutPlannerLive`'s `Set route` (a whole plan) and
  `WandererAppWeb.ScoutIntelLive`'s per-row `Fly to` (one system) — and
  the failure wording is the entire value of the feature. Reported
  2026-10-05 ("I just tried to set planned route for Molden Heath and i
  wasnt getting it ingame"): the page had said "Route set" every time
  while ESI had refused, so a second copy of these clauses that drifted
  from the first would re-open exactly that bug on the other button.

  Three failures are named rather than lumped into "could not set
  route", because each has a different fix and only the reader can
  apply it: ESI refused the token (re-authorise that character), ESI
  refused a stop (the route is a valid prefix, fly it or retry), and
  the pilot is not logged in (EVE accepts waypoints for a logged-out
  character and discards them — the one that looks like nothing
  happened at all).
  """

  alias WandererApp.Scout.PlanWaypoints

  @type status :: %{level: :ok | :warn | :error, text: String.t()}

  @doc """
  Pushes `stops` and returns the status to render.

  `label` names what was pushed ("This plan", "Jita") and only appears
  in the "nothing to fly" case; `name` is the pilot, and appears in
  every other one, because a route written to the wrong character is
  the mistake this page can actually make.
  """
  @spec push([map()], String.t() | integer() | nil, String.t(), String.t()) :: status()
  def push(stops, character_eve_id, name, label)

  def push(_stops, nil, _name, _label),
    do: %{level: :error, text: "Pick a character before setting a waypoint."}

  def push(stops, character_eve_id, name, label) do
    stops
    |> PlanWaypoints.push(character_eve_id)
    |> status(name, label)
  end

  @doc "The pilot's name, or a phrase that still reads as a sentence."
  @spec character_name([map()], String.t() | nil) :: String.t()
  def character_name(characters, eve_id) do
    case Enum.find(characters, &(&1.eve_id == eve_id)) do
      nil -> "that character"
      character -> character.name
    end
  end

  @doc "Turns a `PlanWaypoints.push/2` result into a status. Public so both pages share the wording."
  @spec status(term(), String.t(), String.t()) :: status()
  def status(result, name, label)

  def status({:error, :no_gate_stops}, _name, label),
    do: %{level: :error, text: "#{label} has no gate-reachable stops to fly."}

  def status({:error, :unknown_character}, _name, _label),
    do: %{
      level: :error,
      text: "Pick a character this instance tracks before setting a route."
    }

  # The token case is the one a reader can fix, so it says how: this
  # instance refreshes an expired token on the preflight call, and the
  # only way that still fails is a revoked or never-granted grant.
  def status({:error, {:token, reason}}, name, _label),
    do: %{
      level: :error,
      text:
        "EVE would not accept #{name}'s token (#{esi_reason(reason)}). " <>
          "Nothing was sent. Re-authorise that character on the Characters page, then try again."
    }

  def status({:ok, %{pushed: [], total: total, error: error}}, name, _label)
      when not is_nil(error),
      do: %{
        level: :error,
        text:
          "ESI refused the first of #{total} stops (system #{error.solar_system_id}): " <>
            "#{esi_reason(error.reason)}. #{name}'s in-game route is unchanged."
      }

  # A partial push is a real route, just not this one: the stops that
  # landed are a valid prefix, which is why the push halts instead of
  # skipping the refused stop.
  def status({:ok, %{pushed: pushed, total: total, error: error}}, name, _label)
      when not is_nil(error),
      do: %{
        level: :warn,
        text:
          "Stopped at stop #{error.index + 1} of #{total} (system #{error.solar_system_id}): " <>
            "#{esi_reason(error.reason)}. #{name} has the first " <>
            "#{length(pushed)} #{plural(length(pushed), "waypoint", "waypoints")} only."
      }

  # ESI accepts a waypoint for a character whose client is not running
  # and discards it. That is exactly the "I set it and nothing happened"
  # report this page could not explain, so it is a warning, not a tick.
  def status({:ok, %{pushed: pushed, online?: false}}, name, _label),
    do: %{
      level: :warn,
      text:
        "EVE accepted #{length(pushed)} #{plural(length(pushed), "waypoint", "waypoints")}, " <>
          "but reports #{name} as not logged in — waypoints only reach a running client, " <>
          "so this route went nowhere. Log that character in and set it again."
    }

  def status({:ok, %{pushed: pushed}}, name, _label),
    do: %{
      level: :ok,
      text:
        "Route set on #{name}: #{length(pushed)} " <>
          "#{plural(length(pushed), "waypoint", "waypoints")} at " <>
          "#{Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")}Z."
    }

  @doc "ESI's refusal, in words a reader can act on."
  @spec esi_reason(term()) :: String.t()
  def esi_reason(:forbidden), do: "ESI answered 403 Forbidden"
  def esi_reason(:timeout), do: "ESI timed out"
  def esi_reason(:pool_timeout), do: "no HTTP connection was available"
  def esi_reason(:error_limited), do: "ESI rate-limited this instance"
  def esi_reason(:no_token), do: "this instance holds no access token for it"
  def esi_reason(reason) when is_binary(reason), do: reason
  def esi_reason(reason) when is_atom(reason), do: to_string(reason)
  def esi_reason(%{__exception__: true} = error), do: Exception.message(error)
  def esi_reason(reason), do: inspect(reason)

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural
end
