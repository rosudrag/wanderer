defmodule WandererAppWeb.Plugs.CheckScoutPlannerDisabled do
  @moduledoc """
  CHEWY PATCH: gates `GET /api/maps/:map_identifier/scout/plan` behind
  `WandererApp.Env.scout_planner_enabled?/0` (`WANDERER_SCOUT_PLANNER`).

  Router routes are compiled once, at build time, before
  `config/runtime.exs` ever runs (the flag is a runtime value) -- so the
  route itself cannot be conditionally *defined*. This plug makes it
  conditionally *reachable* instead: with the flag off, a request gets
  the same 404 a genuinely nonexistent route would give. Mirrors
  `CheckScoutCoverageDisabled` / `CheckScoutPresenceDisabled`.

  The same flag separately gates `WandererAppWeb.ScoutRefreshLive` (the
  `/scout` "Refresh queue" tab), which checks
  `WandererApp.Env.scout_planner_enabled?/0` directly in `mount/3` rather
  than through a plug, since a disabled LiveView redirects with a flash
  instead of 404ing.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if WandererApp.Env.scout_planner_enabled?() do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
