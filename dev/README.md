# Agent smoke environment (no EVE account, no SSO)

This spins up a throwaway wanderer instance where `/dev/login` sets an
authenticated session directly — no EVE SSO round trip. It exists so an
agentic developer can boot the app and look at real rendered map UI. It is
NOT a general dev environment: no real characters, no real ESI data, no
real killmails.

`WANDERER_DEV_AUTH_TOKEN` MUST NEVER be set on the production deployment
(wanderer.chewytech.com). Setting it turns on an unauthenticated login
endpoint for anyone who can reach the port. This compose file only publishes
that port on `127.0.0.1`, and it refuses to start at all without the token.

Run every command below from the repo root.

## 1. Generate a token and export it

```sh
export WANDERER_DEV_AUTH_TOKEN=$(openssl rand -hex 24)
```

## 2. Start the stack

```sh
docker compose -f dev/docker-compose.agent.yml up -d
```

This starts Postgres and the app container (`${WANDERER_IMAGE:-chewytech/wanderer:latest}`,
built by the separate deploy repo), published at `http://localhost:4100`
(override with `AGENT_PORT`). Wait for the app to report healthy before
continuing — `docker compose -f dev/docker-compose.agent.yml logs -f app`
until you see the Phoenix endpoint start line.

## 3. Load the EVE static data (SDE)

Without this, systems render with no names or security class. This takes a
couple of minutes — it is a real data import, not a stub.

```sh
docker compose -f dev/docker-compose.agent.yml exec app bin/wanderer_app rpc 'WandererApp.EveDataService.update_eve_data()'
```

**`rpc`, not `eval`.** `eval` loads the release without starting applications,
so Finch has no pools and every HTTP call dies with
`unknown registry: Req.Finch`. The compose file pins short-name distribution
to a loopback node so `rpc` can connect at all — the default (long names from
the container hostname) fails with `Hostname <id> is illegal`.

## 4. Seed a dev user, character, and map

```sh
docker compose -f dev/docker-compose.agent.yml exec app bin/wanderer_app rpc 'WandererApp.Dev.Seed.run() |> IO.inspect()'
```

This is idempotent — running it again reuses the same user/character/map
instead of creating duplicates, and it starts the map server so the map is
immediately renderable. The printed `map_slug` is what you visit in step 5.

Re-running does NOT move systems back: `upsert` leaves positions alone. To put
an already beautified map back into its messy starting shape, pass the opt-in:

```sh
docker compose -f dev/docker-compose.agent.yml exec app bin/wanderer_app rpc 'WandererApp.Dev.Seed.run(reset_positions: true)'
```

## 5. Log in and open the map

Visit, in a real browser or via `dev/agent-smoke.mjs`:

```
http://localhost:4100/dev/login?token=$WANDERER_DEV_AUTH_TOKEN
```

(optionally add `&name=Some+Agent` to set the displayed character name).
This sets the session cookie and redirects to `/maps`. Then open the seeded
map:

```
http://localhost:4100/<map_slug>
```

using the `map_slug` printed in step 4.

### The map canvas will be EMPTY until you do this

On mount the client pushes `ui_loaded` with
`localStorage.wandererLastVersion`. A fresh browser profile has never set it,
so the version does not match the server's and the server never starts the
map: you get the "Update Required / What's new?" splash and zero nodes,
with nothing in the logs. Set it to the running `@version` from `mix.exs`
BEFORE loading the map page:

```js
localStorage.setItem('wandererLastVersion', '1.103.4-chewy.9'); // match mix.exs
location.reload();
```

With a headless browser, do it as an init script or right after the first
navigation, then reload. Confirmed working: 15 nodes and 17 edges render, the
right-bar sparkles button beautifies the layout, and a toast offers Undo.

## 6. Tear down

```sh
docker compose -f dev/docker-compose.agent.yml down -v
```

The `-v` also drops the named Postgres volume (`wanderer-agent-db-data`),
so the next `up` starts from empty and you repeat steps 3–4.

## What is fake here

The seeded character has placeholder ESI tokens (`access_token`,
`refresh_token`, `expires_at`) that do not correspond to any real EVE
Online session. As a result:

- Character location tracking will fail and log errors (no real ESI calls
  succeed).
- Killmail feeds, wallet, and route/autopilot data that depend on ESI will
  not populate.
- Anything that depends on a live EVE SSO character is fake or absent.

Everything map-layout-related — systems, connections, signatures, the map
canvas, the beautifier/tidy-insert fork features — is real and fully
interactive, because it is backed by ordinary database rows, not ESI.

## Automated smoke check

```sh
export MAP_SLUG=<map_slug from step 4's output>
node dev/agent-smoke.mjs
```

Reads `WANDERER_DEV_AUTH_TOKEN` (required) and `MAP_SLUG` (required) from
the environment, plus optional `AGENT_HOST`/`AGENT_PORT`/`AGENT_NAME`. It
logs in over plain HTTP, fetches the map page with the resulting session
cookie, and prints PASS/FAIL. No install step — it only uses Node's
built-in `fetch`. If the `playwright` package happens to be installed
already it also takes a screenshot; otherwise it skips that part with a
clear message and still reports the HTTP-level result.

