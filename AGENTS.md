# Wanderer — chewytech fork

Fork of [`wanderer-industries/wanderer`](https://github.com/wanderer-industries/wanderer), the EVE
Online mapper. Runs at **wanderer.chewytech.com** on the Hetzner EX44.

This file is OURS — upstream has no `AGENTS.md`, so it never conflicts on a merge.

| | |
|---|---|
| Our branch | `chewy` — upstream tag + our commits. `main` stays a plain copy of upstream |
| Upstream remote | `upstream`, **fetch only** |
| Deploy config | `chewytech` monorepo → `projects/infrastructure/hetzner/wanderer/` (separate repo) |
| Build | on the server, from `origin/chewy`, by that repo's `deploy.ps1 -Build` |
| GitHub Actions | **disabled on this fork** — we do not use GitHub CI |

## Rules

1. **Bump `@version` in `mix.exs` in every commit that changes behaviour.** `deploy.ps1 -Build`
   derives the image tag from it (`1.103.4-chewy.2`). Skip the bump and two builds share a tag;
   docker keeps the old image and the deploy reports success while running old code.
2. **Merge upstream, never rebase `chewy`.** It is pushed and it is what the server builds.
3. **Never edit `.github/workflows/` or `CHANGELOG.md`.** Upstream's CI rewrites both on every
   release — editing them buys a conflict on every single merge, for nothing we use.
4. **Prefer additive files to edits in hot files.** A new module never conflicts; ten lines
   through `map_live.ex` conflict every time upstream touches it.
5. **Prefix our commits `chewy:`** so `git log upstream/main..chewy` is the honest patch list.
6. **Gate every feature behind an env var, defaulting to upstream behaviour.** Rollback then costs a
   redeploy, not a revert, and the patch survives an upstream release unchanged.
7. **Upstream what is not ours.** A plain bug fix accepted upstream is a patch that stops costing
   merges.

## Our patches

| Feature | Env var | Entry point |
|---|---|---|
| Tracking survives the browser being closed | `WANDERER_PERSIST_TRACKING` | `lib/wanderer_app/map/persistent_tracking.ex` (+ 4 one-line hooks in `map_server_impl.ex`, `map_pool.ex`, `map_manager.ex`) |
| Map beautifier (auto-layout: Dotlan-geometry k-space, tidy-tree wormhole chains) | `WANDERER_MAP_BEAUTIFIER` | `assets/js/hooks/Mapper/components/map/layout/` + `components/map/hooks/useBeautify.ts`, `lib/wanderer_app/map/bulk_reposition.ex` (+ `update_system_positions_bulk` event) |
| Direction-aware placement for newly added systems | `WANDERER_TIDY_INSERT` | `lib/wanderer_app/map/map_position_calculator.ex` |
| Agent dev access: log in and seed a map with no EVE account | `WANDERER_DEV_AUTH_TOKEN` (unset = endpoint is a plain 404; **never set in production**) | `lib/wanderer_app_web/controllers/dev_auth_controller.ex`, `lib/wanderer_app/dev/seed.ex`, `dev/` (compose stack, README, smoke script) |
| Connection traffic: recorded jumps kept on the connection and drawn as a weighted line | `WANDERER_CONNECTION_TRAFFIC` | `lib/wanderer_app/map/connection_traffic.ex` (+ hooks in `map_server_connections_impl.ex`, `map_ui_connection/1`, `DotlanEdge.tsx`) |
| Wormhole chains hang off the k-space lattice instead of growing through it (N cells of clearance) | `WANDERER_CHAIN_STANDOFF` (cells, `0` = upstream) | `lib/wanderer_app/map/chain_standoff.ex` + `layout/index.ts` chain placement, `map_position_calculator.ex` tidy-insert offsets |
| Angle discipline: every connection drawn along one of four cell directions (0°, 90°, ±22.6°, ±39.8° on the 180x75 grid) | `WANDERER_ANGLE_SNAP` (`false` = upstream) | `assets/js/hooks/Mapper/components/map/layout/octilinear.ts` + `geometry.ts` `ANGLE_DIRECTIONS`, `settle()` in `layout/index.ts` |
| Private ChewyTech branding (SSO-only landing, no public newsboard, no upstream analytics) | `WANDERER_PRIVATE_BRANDING` | `lib/wanderer_app/branding.ex` (+ `lib/wanderer_app_web/controllers/blog_controller.ex`, `lib/wanderer_app_web/components/layouts/blog.html.heex`, `lib/wanderer_app_web/components/layouts/root.html.heex`) |

## Testing the map without an EVE account

`dev/README.md` is the command sequence: a throwaway compose stack on `127.0.0.1:4100`, `/dev/login?token=…`,
and `WandererApp.Dev.Seed.run/1` for a real 15-system map. Two traps are documented there and cost an hour each
if you rediscover them: use `bin/wanderer_app rpc`, never `eval` (eval starts no applications, so Finch has no
pools), and set `localStorage.wandererLastVersion` to the running `@version` or the server silently never starts
the map and you get an empty canvas with an "Update Required" splash.

`node dev/layout-bench.mjs` scores the beautifier: quality (crossings, span, edge length, idempotence) and
**round-trip stability** — beautify, add k systems, beautify again — which is the number that matters, plus the
cold full re-solve cost. `--json`/`--compare` gate regressions. Run it after any change under
`assets/js/hooks/Mapper/components/map/layout/`.

## Traps that cost real time here

- **Never `docker build` from a tar of this Windows working tree.** NTFS drops the exec bit and git hands
  you CRLF, so the image fails with `exec /app/entrypoint.sh: no such file or directory`, then
  `/app/releases/*/env.sh: not found`. Build from a fresh `git clone` on the server, the way
  `deploy.ps1 -Build` does. Same reason `mix format --check-formatted` reports every file as unformatted
  until you strip CR: the formatter also wants 100 columns, not 120.
- **Actor-less Ash reads can return nothing even with `authorize?: false`.** `MapConnection`'s primary read
  is `prepare WandererApp.Api.Preparations.FilterConnectionsByActorMap`, so with no actor it yields 0 rows
  while the table holds hundreds — a duplicate guard built on it silently inserts every time. Use the
  purpose-built read actions (`:read_by_locations`, `:read_by_map`) in any script or seeder that runs
  without an actor.
- **`deploy.ps1` does not run from an agent session**: `SSH_KEY_PATH` is empty in `.env` and `SERVER_HOST`
  is `root@…`, while the agent's ssh alias authenticates as `claude`. Replicate its steps over
  `ssh ex44 "sudo …"` — fetch + `git checkout --detach origin/chewy`, read `@version`, `docker build` with
  both tags, install `.env`/`docker-compose.yml`, `compose pull` the sidecars, `compose up -d --force-recreate`.

## Loop

```bash
git switch chewy
# patch, bump @version
git commit -am "chewy: <what>" && git push
```

Then from the monorepo: `cd projects\infrastructure\hetzner\wanderer; .\deploy.ps1 -Build` →
put the printed `WANDERER_IMAGE=` into `.env` → `.\deploy.ps1`.

**It builds `origin/chewy`, not your working tree.** An uncommitted edit is not deployed.

## Reaching the deploy config from here

`infra/` is a **junction** to the monorepo's `projects/infrastructure/hetzner/wanderer/`
(`.env`, `.env.example`, `deploy.ps1`, `docker-compose.yml`, `README.md`). It is untracked —
listed in `.git/info/exclude`, not `.gitignore`, so it costs nothing on an upstream merge and
can never be committed. Recreate it after a fresh clone:

```powershell
New-Item -ItemType Junction -Path infra `
  -Target I:\Development\azure\chewytech\projects\infrastructure\hetzner\wanderer
Add-Content .git\info\exclude "infra/"
```

What works through it and what does not:

| | |
|---|---|
| `read infra/.env`, `edit infra/docker-compose.yml`, `glob infra/*` | work |
| `grep … path=infra/README.md` (explicit file) | works |
| `grep`/`rg`/`grep -r` **recursing into** `infra/` | silently finds nothing — no tool follows the junction |
| recursive search of the deploy config | use the real path: `I:/Development/azure/chewytech/projects/infrastructure/hetzner/wanderer` |

"Silently finds nothing" is the trap: a search that should have matched returns clean, and the
absence reads like the config not containing the thing. Search the absolute path instead.

Editing `infra/**` edits the monorepo working tree; commit it from the monorepo, not here. The
reverse junction also exists — `infra/wanderer` points back at this repo — but nothing traverses
it, so there is no recursion.

`deploy.ps1` must be **run** from the monorepo (it resolves siblings like
`hetzner/reverse-proxy`), and it builds `origin/chewy`, not `infra/wanderer`.

## Taking an upstream release

```bash
git fetch upstream --tags
git merge v1.104.0          # conflicts are in OUR files, by construction
# set @version to 1.104.0-chewy.1
git commit -am "chore: merge upstream v1.104.0" && git push
```

Migrations run from the container's own entrypoint on start; no manual step.

## Verifying a running build

`bin/wanderer_app rpc` does **not** work on the deployment (`ERL_AFLAGS=-proto_dist inet6_tcp`
plus a short container hostname ⇒ `:noconnection`). Use:

```bash
ssh ex44 "sudo docker exec wanderer sh -c 'ls -d /app/lib/wanderer_app-*'"   # which build
ssh ex44 "sudo docker logs wanderer 2>&1 | grep PersistentTracking"
```

Full operational notes: `projects/infrastructure/hetzner/wanderer/README.md` in the monorepo.
