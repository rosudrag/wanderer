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
| Wormhole chains hang off the k-space lattice instead of growing through it (N cells of clearance). An **existing** chain is a rigid pocket: incremental beautify never relocates one member of it on its own — it pins the pocket where the user has it (measured: moving the whole pocket instead fails the bench's `rankInv<=2` gate) | `WANDERER_CHAIN_STANDOFF` (cells, `0` = upstream) | `lib/wanderer_app/map/chain_standoff.ex` + `layout/index.ts` chain placement, `layout/anchor.ts` (`chainPockets`, crowded-node rules), `map_position_calculator.ex` tidy-insert offsets |
| Angle discipline: every connection drawn along one of four cell directions (0°, 90°, ±22.6°, ±39.8° on the 180x75 grid) | `WANDERER_ANGLE_SNAP` (`false` = upstream) | `assets/js/hooks/Mapper/components/map/layout/octilinear.ts` + `geometry.ts` `ANGLE_DIRECTIONS`, `settle()` in `layout/index.ts` |
| Private ChewyTech branding (SSO-only landing, no public newsboard, no upstream analytics) | `WANDERER_PRIVATE_BRANDING` | `lib/wanderer_app/branding.ex` (+ `lib/wanderer_app_web/controllers/blog_controller.ex`, `lib/wanderer_app_web/components/layouts/blog.html.heex`, `lib/wanderer_app_web/components/layouts/root.html.heex`) |
| Identity/state/groups suite foundation (Phase 0): main-character-only state engine, groups with auto-rules + permissions, ESI-derived director check, audit log, GDPR purge framework, self-service main-character UI | `WANDERER_IDENTITY_SUITE` | `lib/wanderer_app/identity/` (`state_engine.ex`, `director_check.ex`, `permission_cache.ex`, `audit.ex`, `gdpr.ex`), `lib/wanderer_app/api/{owned_corporation,group,group_membership,group_auto_rule,group_permission,standing_grant,user_identity,audit_log}.ex`, `lib/wanderer_app/api/policies/identity_scoped.ex`, `lib/wanderer_app_web/live/corp/{corp_management_live,corp_identity_live}.ex` (+ `.html.heex`), `lib/wanderer_app_web/components/corp_nav.ex`, `lib/wanderer_app_web/controllers/plugs/check_identity_suite_disabled.ex` (+ hooks in `config/runtime.exs` director-scope SSO tier + daily recompute job, `ueberauth/strategy/eve.ex` + `uberauth.ex` director-scope selection, `auth_controller.ex` + `character/tracker.ex` state recompute, `esi/api_client.ex` + `esi.ex` `get_character_roles/2`, `env.ex`, `api.ex` resource registration, `router.ex` new `/corp` pipeline + scope + `live_session`, `live/nav.ex` `corp_flags` assign + `active_tab` cases, `components/layouts/live.html.heex` sibling nav component call). See `docs/chewy/corp-suite-plan.md` §2/§8/§9 Phase 0. |
| Map-ACL-from-groups (Phase 1): a `Group` -> `AccessList` -> role grant materializes/retracts ordinary `AccessListMember` rows automatically, event-driven off group membership and grant changes — zero edits to `permissions.ex`/`access_list_member.ex` | `WANDERER_GROUP_MAP_SYNC` | `lib/wanderer_app/identity/map_acl_sync.ex`, `lib/wanderer_app/identity/changes/{sync_group_membership,sync_map_access_grant}.ex`, `lib/wanderer_app/api/{group_map_access_grant,group_map_synced_member}.ex`, `lib/wanderer_app_web/live/corp/group_map_grants_live.ex` (+ `.html.heex`) (+ hooks in `lib/wanderer_app/api/group_membership.ex` `active_by_group` read action + `:create`/`:update`/`:destroy` change attachment, `env.ex`, `api.ex` resource registration, `config/runtime.exs` env var, `router.ex` one route inside the existing `/corp` `live_session`, `live/nav.ex` `corp_flags` extension + `active_tab` case, `components/corp_nav.ex` nav entry, `live/corp/corp_shell_live.html.heex` conditional link). See `docs/chewy/corp-suite-plan.md` §2.5, §9 Phase 1. |
| ESI sync framework (Phase 2): one supervised scheduler (cadence, ETag, capped exponential backoff, `:stalled` after 5 consecutive failures) shared by every later ESI-backed phase instead of a bespoke poller per feature; zero registered feeds yet | `WANDERER_SYNC_FRAMEWORK` | `lib/wanderer_app/sync/{feed,registry,scheduler,retention}.ex`, `lib/wanderer_app/esi/rate_limit_gate.ex`, `lib/wanderer_app/api/sync_run.ex` (+ hooks in `lib/wanderer_app/esi/api_client.ex` `do_get/4`/`do_get_request/4` gain a backward-compatible `:etag` opt (If-None-Match request header + `:not_modified`/3-tuple response, no-op unless a caller passes the key), `application.ex` `maybe_start_sync_scheduler/1` (also attaches `RateLimitGate`'s telemetry handler), `env.ex`, `api.ex` resource registration, `config/runtime.exs` env var + daily retention-purge Quantum job). See `docs/chewy/corp-suite-plan.md` §3, §9 Phase 2. |
| Corp roster feed (Phase 3): one director-token call (`GET /corporations/{id}/membertracking/`) upserts a live current-state roster (last logon/logoff, location, ship) for every in-game member, including characters that have never logged into this app; known limit, not silent — page 1 only (100 rows), disclosed in code + a roster-page banner; self-service director-access consent link on the same page (no `characters_live.ex` edit needed) | `WANDERER_CORP_ROSTER` | `lib/wanderer_app/sync/feeds/corp_roster_feed.ex`, `lib/wanderer_app/api/corp_roster_snapshot.ex`, `lib/wanderer_app_web/live/corp/corp_management_live.ex` (+ `.html.heex`, incl. the `/auth/eve?director=true` consent link + explanatory copy) (+ hooks in `lib/wanderer_app/esi/api_client.ex` `get_corp_membertracking/2` + `resolve_universe_names/1`, `lib/wanderer_app/esi.ex` delegates, `lib/wanderer_app/cached_info.ex` `get_character_name/1`, `lib/wanderer_app/sync/registry.ex` conditional `default_feeds/0` entry, `lib/wanderer_app/sync/feed.ex` `token_holder/1` typespec widened to admit `{:error, term()}`, `config/runtime.exs` `director_scope` (hook #1) now includes `esi-corporations.track_members.v1` alongside `esi-characters.read_corporation_roles.v1` — every scope in that string is commented with the exact call it maps to, `env.ex`, `api.ex` resource registration, `config/runtime.exs` env var, `router.ex` one route inside the existing `/corp` `live_session`, `live/nav.ex` `corp_flags` extension + `active_tab` case, `components/corp_nav.ex` nav entry, `live/corp/corp_shell_live.html.heex` conditional link). See `docs/chewy/corp-suite-plan.md` §9 Phase 3, `docs/chewy/seat-parity.md` §6/§8.4. |
| Bootstrap admin by character name (Phase 0): on every login, ensures named character's owning user holds `:corp_suite_admin` permission via "Corp Suite Administrators" group; idempotent; unset/empty = inert (no group/permission ever created), unlike `WANDERER_ADMINS` | `WANDERER_BOOTSTRAP_ADMIN_CHARACTER` (EVE character name, unset/empty = off) | `lib/wanderer_app/identity/bootstrap_admin.ex` (`maybe_bootstrap/0` never raises), `lib/wanderer_app/env.ex` `bootstrap_admin_character/0`, `read` actions (`Character.by_name/2`, `Group.by_name/2`, `GroupPermission.by_group_and_permission/3` in `lib/wanderer_app/api/`) (+ hook in `lib/wanderer_app_web/controllers/auth_controller.ex` line 111, permission check in `lib/wanderer_app_web/live/corp/group_map_grants_live.ex:27-31`) |
| Scanner-client signature sync: `POST /api/maps/:map_identifier/signatures/sync` takes the COMPLETE probe-scanner list for one system and reconciles it server-side (the map UI diffs in TypeScript; nothing did it server-side before), applying adds/updates/removals as one `Server.update_signatures/2` batch. Removals need `authoritative: true`; an empty authoritative payload for a non-empty system is refused unless `allow_empty: true`; connections are never deleted off a signature absence. Fields the client omits keep their stored value. Feeds the eveknob/isxbob EVE bot — see `docs/design/wanderer-bridge.md` in the eve-command-center monorepo | `WANDERER_BOT_SYNC` | `lib/wanderer_app/map/operations/signature_sync.ex`, `lib/wanderer_app_web/controllers/map_signature_sync_api_controller.ex`, `lib/wanderer_app_web/controllers/plugs/check_bot_sync_disabled.ex` (+ `router.ex` `:api_bot_sync` pipeline and its own `/api/maps/:map_identifier` scope, `env.ex` `bot_sync_enabled?/0`, `config/runtime.exs`) |
| Scout intel log: `POST /api/maps/:map_identifier/scout/{spawns,structures}` ingests rows of eveknob's `special_spawns.tsv` / `structures.tsv` (`obj_SpawnLog.iss`, `obj_StructureWatch.iss`) as an append-only fleet-intel log, rendered at **`/scout`** — a top-level route with its own sidebar icon, deliberately NOT under `/corp`: its permission is granted by the instance owner, not by a corp admin. Ingest rides `:api_map` so the bot authenticates with the map `public_api_key` it already holds for signature sync; the stored log is NOT map-scoped (map recorded as provenance only). Every value may arrive as a string and re-sends are normal: rows upsert on a natural identity, and one malformed row is reported without rejecting the batch. The observing character is **dropped, not stored** — an older client may still send `character`, it is ignored. `timer_seconds` (relative, `-1` = none) is resolved to an absolute `timer_expires_at` at ingest. **Reading it needs `:scout_intel_view`, which ONLY the `WANDERER_BOOTSTRAP_ADMIN_CHARACTER` user can grant** (`/scout/access`) — a `corp_suite_admin` cannot, deliberately. Both tabs have the same shape: a time-critical lead that ticks every 30s without a query (structures: running reinforcement timers; spawns: "Still out there", the latest sighting per system+location+spawn within 3h, a horizon deliberately independent of the window selector and aged out by that same tick), an aggregate, the flat log, and a per-subject history drill-down. The page is pushed to by ingest (`"scout_intel"` PubSub topic), folds latest-per-structure AND latest-per-spawn in Postgres (`DISTINCT ON`), groups spawn hotspots in schemaless Ecto (Ash has no general `GROUP BY`), never truncates silently (reads `limit + 1`; the extra row IS the banner), and exports the same filtered rows with every stored column at `/scout/export.csv`. **Every filter applies to every table on the tab**, the two that ignore the window selector included: one ILIKE, a click-to-filter system chip, and a six-chip space-type filter (High/Low/Null/W-Space/Pochven/Other) whose classification comes from a `map_solar_system_v2.system_class` subquery — NOT from the row's stored `system_truesec`, which cannot separate J-space from Pochven from null — with `:other` defined as the `NOT IN` complement so the selection is total and all six selected means no SQL filter at all. One asymmetry worth knowing: a spawn has no id, so its drill-down is keyed on `{solar_system_id, location_name, spawn_name}` — the `:uniq_sighting` identity the resource already upserts on. Two traps in `structures.tsv`, both handled: its header names 24 columns while the writer emits 26 (`anchoring`/`unanchoring` were added between `vulnerable` and `timer_seconds` and the header was never rewritten), and its `type_name` column actually holds the player-set structure name. See `docs/chewy/scout-intel.md` | `WANDERER_SCOUT_INTEL` | `lib/wanderer_app/scout/{ingest,stats,space}.ex`, `lib/wanderer_app/api/scout_{spawn,structure}_sighting.ex`, `lib/wanderer_app/identity/scout_access.ex`, `lib/wanderer_app_web/controllers/{scout_intel_api_controller,scout_export_controller}.ex`, `lib/wanderer_app_web/controllers/plugs/check_scout_intel_disabled.ex`, `lib/wanderer_app_web/live/scout/scout_{intel,access}_live.ex` (+ `.html.heex`), `lib/wanderer_app_web/components/scout_nav.ex` (+ hooks in `router.ex` `:api_scout_intel` + `:scout_intel` pipelines, its own `/api/maps/:map_identifier` scope and a top-level `/scout` scope + `live_session` + the `export.csv` route outside it, `env.ex` `scout_intel_enabled?/0`, `api.ex` resource registration, `config/runtime.exs` env var, `live/nav.ex` `show_scout?` assign + `active_tab` cases, `components/layouts.ex` one sibling call inside `sidebar_nav_links/1`) |
| Scout coverage ledger: `POST /api/maps/:map_identifier/scout/coverage` records "I finished looking at system S to depth K at time T", even when nothing was found — the one fact the scout-intel sighting tables and `map_system_signature` cannot answer, since their timestamps only move when content changes. `kind` is a CLOSED vocabulary (`visit \| anoms \| sigs \| grid`); storage is table `scout_system_coverage_v1`, **upserted on `(solar_system_id, kind)`** — latest-wins, NOT an append-only log like the sighting tables, and `map_id` is provenance-only and never part of the identity. `observed_at` accepts EITHER an ISO8601 UTC string OR an integer unix-epoch-seconds value; an incoming row older than or equal to the stored one is skipped (still counted as `stored`, since the ingest succeeded idempotently). Ingest rides `:api_map`, its own router pipeline/scope independent of `:api_scout_intel` so the two flags gate separately. Never creates a `map_system` row, never touches the map canvas. Phase 1 of `docs/design/wanderer-scout-planner.md` in the eve-command-center monorepo (ranking, `/scout/plan`, route planner and UI are later phases, not built here) | `WANDERER_SCOUT_COVERAGE` | `lib/wanderer_app/api/scout_system_coverage.ex`, `lib/wanderer_app/scout/coverage.ex`, `lib/wanderer_app_web/controllers/scout_coverage_api_controller.ex`, `lib/wanderer_app_web/controllers/plugs/check_scout_coverage_disabled.ex` (+ `:api_scout_coverage` pipeline/scope in `router.ex`, `env.ex` `scout_coverage_enabled?/0`, `config/runtime.exs`, resource registration in `api.ex`) |

**Corp-suite navigation convention.** `/corp` (`corp_management_live.*`, "Management") is the one
page the suite lives on: new features land as a section on it, or as a link out from it if they are
genuinely a separate page (per-user identity, admin-only map grants) — never as a route a user has
to know. The sidebar stays at **one** icon (`components/corp_nav.ex`); it is a fixed column shared
with the map canvas and cannot grow an icon per phase. Three rules that each cost a shipped bug:
render corp entries INSIDE `Layouts.sidebar_nav_links/1`'s `<ul>` (it is `h-full`; a sibling after it
lays out below the aside and is invisible); give every page root `p-4 pl-20 … overflow-auto` like
every upstream page, or the sidebar overlaps the content; and never gate a sidebar entry on an
uncached permission read — `Nav.on_mount/4` runs for every LiveView, so `PermissionCache.corp_admin?/2`
there is a DB round trip per map mount. Each page gets its own `active_tab` atom in
`Nav.set_active_tab/3`.

The **one** permission-gated icon is `/scout` (`components/scout_nav.ex`), and it is not a corp-suite
page. It is affordable only because `ScoutAccess.can_view_cached?/1` answers from `WandererApp.Cache`
and grant/revoke invalidate the entry; the page's own `mount/3` still calls the uncached `can_view?/1`,
so a stale cache can cost a wrong icon but never a wrong page. Copy that pattern or don't gate at all.

**`/scout`'s markup is a component vocabulary, not nine hand-written tables.**
`components/scout_components.ex` owns the page's panels, summary cards, cells and formatters, and
both scout LiveViews `import` it; the templates are markup and the LiveViews are reads. It exists
because the inline version drifted — a truesec in one table and not the next, two of four tables
showing the nearest celestial, three spellings of "nothing here". Three rendering traps it also
pins down: daisyUI `select-sm` (`line-height: 2rem`) plus `@tailwindcss/forms` (`padding: .5rem`)
clips a select's own text until `py-0`; `.modal:not(dialog:not(.modal-open))` outranks a
`bg-black/70` utility, so a dimmed backdrop needs `!bg-black/70`; and the sidebar's icons must stay
distinct — `scout_nav.ex` shipped `hero-viewfinder-circle-solid`, which is already the Map entry's
glyph. Add to that module rather than styling a new table inline. See `docs/chewy/scout-intel.md`
§"How it is rendered".

**The unanchored alert is the one thing on `/scout` allowed to shout.** `status == "Unanchored"`
(floating undeployed — no fitting, no services, no timer) is its own status family, its own
`:unanchored` read action, and four surfaces: a cached red count badge on the sidebar icon visible
from the map canvas (`Scout.Alerts.count_cached/0`, invalidated by the ingest — never a query in
`Nav.on_mount/4`), a red banner above the toolbar on BOTH tabs, its own panel above Live timers,
and the only solid-red status badge on the page. It uses a 7-day horizon instead of the window
selector and ignores the search box on purpose: an alert a search box can hide is not an alert.
Everything else on the page stays muted so this one reads. See `docs/chewy/scout-intel.md`
§"The unanchored alert".

**`/scout`'s filters are sticky, in localStorage, with no new JavaScript.** Tab, window, search and
space ride upstream's generic `LocalStorageSetting` hook (`ls_restore_<key>` on mount,
`ls_update_<key>` on change) through a hidden `#scout-filter-store` div. Server-side storage was
rejected on purpose: a Cachex entry dies with every deploy. Everything restored is re-validated
like a click — localStorage is user-writable, and `String.to_existing_atom/1` on a stored string is
how a page crashes on mount.

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

`powershell -NoProfile -File dev/check.ps1 -All` is the one-command gate for anything server-side:
compile (`--warnings-as-errors`), scoped format, DB + migrations, seed, every discovered test file,
a real HTTP boot, and the feature-flag route contract probed **both ways** (flag off ⇒ 404, flag on
⇒ 200). Runbook and traps: `dev/CHECK.md`. Two things to read correctly: `Format` reports `SKIP`
on a clean tree because it diffs against the base, and a `SKIP` still counts toward the "7/7"
total; and `-Boot` uses `dev/boot.exs` (`mix run --no-start`, overriding only `server:`/`watchers:`)
because `mix phx.server` hangs forever on the npm watcher `config/dev.exs` configures.

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
- **`deploy.ps1` DOES run from an agent session now** (changed 2026-09-29, infra repo). `SSH_KEY_PATH`
  may be blank — an ssh_config alias is a complete answer, and `SERVER_HOST=ex44` is one — and a
  non-root account is fine: every mutating command goes through passwordless `sudo`, with files staged
  in `/tmp` and `install`ed, because `scp` cannot write the root-owned deploy path. Run it from the REAL
  infra path (`…\infrastructure\hetzner\wanderer`), never through the `infra/` junction: `$PSScriptRoot`
  resolved through a junction cannot find `..\common\deploy-functions.ps1`. The old manual
  `ssh ex44 "sudo …"` fetch/build/install/compose sequence this file used to prescribe is OBSOLETE —
  do not reintroduce it.
- **A new `WANDERER_*` in `.env` does not reach the container on its own.** `infra/docker-compose.yml`
  names every app env var explicitly — deliberately, so the deploy repo's `SSH_KEY_PATH`/`SERVER_HOST`
  can never leak in via `env_file`. Miss the `environment:` entry and the deploy reports success while
  the feature stays off and `.env` claims otherwise. Add the var in both places, in the same change.
- **Several agent sessions run against this box at once, so a deploy is not atomic.** Observed
  2026-09-29: `compose up -d --force-recreate` reported all four containers Started, and a minute later
  `wanderer-db`, `wanderer-kills` and `wanderer-route-builder` sat in `Created` beside a renamed
  `<hash>_wanderer` duplicate — a second session's `compose up` had been interrupted mid-recreate,
  leaving the app running with its database down and the site answering **502**. `docker compose up -d`
  reconciles it. So: after any deploy, verify the END state rather than trusting the command's own
  output — `docker ps --filter name=wanderer` must show four containers `Up`, and the site must answer.
  A renamed `<hash>_<service>` container is the tell that someone else is mid-recreate.
- **`/auth/eve` is invite-gated whenever `WANDERER_INVITES=true`.** With no `invite` param,
  `Eve.check_invite_valid/1` returns `{not invites(), :user}` and `handle_request!/1` redirects to
  `/welcome` **before** reaching EVE SSO — logged-in session or not. Any in-app link to `/auth/eve?…`
  must first mint `invite_<uuid>` in `WandererApp.Cache` and pass it through, the way
  `characters_live.ex`'s `"authorize"` handler and `corp_management_live.ex`'s `"request_director_access"`
  handler both do. A plain `<.link href={~p"/auth/eve?…"}>` is dead on this deployment.
- **Boolean env vars are `String.to_existing_atom`'d** (`config/runtime.exs`, the upstream idiom every
  flag follows). A trailing space — `WANDERER_IDENTITY_SUITE=true ` — crashes the container at boot
  with `not an already existing atom`. Loud, not silent, but baffling until you know.
- **`mix compile` proves nothing about Ash query pipelines.** `Ash.read(Resource, …) |> Ash.Query.filter(…)`
  compiles clean and raises `ArgumentError: Expected a resource or a query` on first execution —
  it shipped that way once, in the login path, where it would have broken every login. Build queries as
  `Resource |> Ash.Query.filter(…) |> Ash.read_one(…)`, or use purpose-built `get_by:` code interfaces,
  and require a real run or test before believing any Ash change works.

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
(`.env`, `.env.example`, `deploy.ps1`, `docker-compose.yml`, `README.md`), and `infra-repo/` is a
second junction to that submodule's **root** (`projects/infrastructure/`), which is where its git
repo actually lives. Both are untracked — listed in `.git/info/exclude`, not `.gitignore`, so they
cost nothing on an upstream merge and can never be committed. Recreate them after a fresh clone:

```powershell
New-Item -ItemType Junction -Path infra `
  -Target I:\Development\azure\chewytech\projects\infrastructure\hetzner\wanderer
New-Item -ItemType Junction -Path infra-repo `
  -Target I:\Development\azure\chewytech\projects\infrastructure
Add-Content .git\info\exclude "infra/"
Add-Content .git\info\exclude "infra-repo/"
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

Editing `infra/**` edits the monorepo working tree. Commit it with `git -C infra-repo …` — that is
what `infra-repo/` is for: `git -C infra` would work too (git walks up to the submodule root by the
real path), but only `infra-repo` lets you see and stage paths outside `hetzner/wanderer/`. Stage
explicit paths: that submodule usually carries unrelated dirty files from other projects. Its own
`AGENTS.md` applies there — conventional-commit subjects, 50/72, no AI attribution — and after
pushing it, bump the pointer in the superproject (`git -C I:/Development/azure/chewytech add
projects/infrastructure`), or the change exists only in the submodule.

The reverse junction also exists — `infra/wanderer` points back at this repo — but nothing
traverses it, so there is no recursion.

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
