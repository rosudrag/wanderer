# dev/boot.exs
#
# Boots the real application and answers HTTP on the fixed port from
# `config/dev.exs` (4444), WITHOUT the `npm run watch` esbuild watcher that
# `config/dev.exs`'s `watchers:` key configures for `mix phx.server`. This
# checkout has no local `npm install`, so `mix phx.server` hangs forever
# spawning that watcher process and `-Boot`/`-Routes` time out.
#
# `config/dev.exs` is NEVER edited for this — the watcher is legitimate
# config for a real interactive dev loop with a running npm toolchain.
# Instead this script overrides only the in-memory Application env, and
# only `server:` and `watchers:`, before the application (and therefore the
# Endpoint supervisor) starts:
#
#   * `server: true`   — Phoenix only opens the HTTP listener when this
#     (or `config :phoenix, :serve_endpoints`) is true; `mix phx.server`
#     achieves the same by setting `PHX_SERVER=1` before boot. Neither
#     `config/dev.exs` nor `config/runtime.exs` set it for plain `mix run`.
#   * `watchers: []`    — Phoenix only starts watcher children when
#     `server?` is true (or `force_watchers: true`) — see
#     `Phoenix.Endpoint.Supervisor.watcher_children/3` in
#     `deps/phoenix/lib/phoenix/endpoint/supervisor.ex`. Since this script
#     flips `server: true`, the watcher WOULD start unless also cleared.
#
# The override must land before the application starts, so this must run
# as `mix run --no-start dev/boot.exs` (never plain `mix run`, which starts
# the application — and therefore the Endpoint supervisor, reading the
# un-overridden config — before any user script code executes).
#
# The script then blocks forever; `check.ps1` kills the OS process by PID
# once it is done probing.
endpoint_config =
  :wanderer_app
  |> Application.get_env(WandererAppWeb.Endpoint, [])
  |> Keyword.put(:server, true)
  |> Keyword.put(:watchers, [])
  |> Keyword.put(:force_watchers, false)

Application.put_env(:wanderer_app, WandererAppWeb.Endpoint, endpoint_config)

{:ok, _started} = Application.ensure_all_started(:wanderer_app)

IO.puts("BOOT_READY port=#{Keyword.get(endpoint_config[:http] || [], :port, "?")}")

Process.sleep(:infinity)
