defmodule WandererAppWeb.Plugs.CheckScoutPresenceDisabled do
  @moduledoc """
  CHEWY PATCH: gates the scout presence snapshot route behind
  `WandererApp.Env.scout_presence_enabled?/0` (`WANDERER_SCOUT_PRESENCE`).

  Router routes are compiled once, at build time, before `config/runtime.exs`
  ever runs (the flag is a runtime value) -- so the route itself cannot be
  conditionally *defined*. This plug makes it conditionally *reachable*
  instead: with the flag off, a request gets the same 404 a genuinely
  nonexistent route would give. Mirrors `CheckScoutCoverageDisabled` /
  `CheckScoutIntelDisabled`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if WandererApp.Env.scout_presence_enabled?() do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
