defmodule WandererAppWeb.Plugs.CheckIdentitySuiteDisabled do
  @moduledoc """
  Gates the `/corp` scope behind `WandererApp.Env.identity_suite_enabled?/0`.

  Router routes are compiled once, at build time, before
  `config/runtime.exs` ever runs (the flag is a runtime value) — so the
  routes themselves cannot be conditionally *defined*. This plug makes
  them conditionally *reachable* instead: with the flag off, every
  request into `/corp/*` gets the same 404 a genuinely nonexistent route
  would give, before Phoenix.LiveView ever mounts. See
  docs/chewy/corp-suite-plan.md §9 Phase 0.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if WandererApp.Env.identity_suite_enabled?() do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
