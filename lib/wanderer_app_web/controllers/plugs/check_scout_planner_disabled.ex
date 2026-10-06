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

  The same flag separately gates the Planner CATEGORY of `/scout`, and
  not through a plug: `WandererAppWeb.ScoutIntelLive.handle_params/3`
  patches `/scout/planner` back to `/scout/structures` with a flash, and
  the nested `ScoutPlannerLive` child re-reads the flag on its own
  account before rendering anything. A browser page says why it is gone;
  only the wire gets a 404.
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
