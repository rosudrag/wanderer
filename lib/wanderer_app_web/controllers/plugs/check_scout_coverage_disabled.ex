defmodule WandererAppWeb.Plugs.CheckScoutCoverageDisabled do
  @moduledoc """
  CHEWY PATCH: gates the scout coverage ingest route behind
  `WandererApp.Env.scout_coverage_enabled?/0` (`WANDERER_SCOUT_COVERAGE`).

  Router routes are compiled once, at build time, before `config/runtime.exs`
  ever runs (the flag is a runtime value) -- so the route itself cannot be
  conditionally *defined*. This plug makes it conditionally *reachable*
  instead: with the flag off, a request gets the same 404 a genuinely
  nonexistent route would give. Mirrors `CheckScoutIntelDisabled` /
  `CheckBotSyncDisabled`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if WandererApp.Env.scout_coverage_enabled?() do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
