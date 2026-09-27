defmodule WandererAppWeb.Plugs.CheckBotSyncDisabled do
  @moduledoc """
  CHEWY PATCH: gates the scanner-client sync routes behind
  `WandererApp.Env.bot_sync_enabled?/0` (`WANDERER_BOT_SYNC`).

  Router routes are compiled once, at build time, before `config/runtime.exs`
  ever runs (the flag is a runtime value) -- so the routes themselves cannot be
  conditionally *defined*. This plug makes them conditionally *reachable*
  instead: with the flag off, a request gets the same 404 a genuinely
  nonexistent route would give. Mirrors `CheckIdentitySuiteDisabled`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if WandererApp.Env.bot_sync_enabled?() do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
