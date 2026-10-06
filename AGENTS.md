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
| Tracking survives the browser being closed | `WANDERER_PERSIST_TRACKING` | `lib/wanderer_app/map/persistent_tracking.ex` (+ 5 one-line hooks in `map_server_impl.ex`, `map_pool.ex`, `map_manager.ex`, `live/map/map_characters_live.ex`). The DB flag `map_character_settings_v1.tracked` becomes the authority, so BOTH untrack paths must write it: the tracking dialog already does (`TrackingUtils` → `MapCharacterSettingsRepo.untrack/1`), the map's Characters page did not — it only dropped the `tracking_start_time` cache key, so `resume/1` re-tracked the character at the next map server start and the button silently reverted. `persist_untrack/1` closes that; any new untrack surface inherits the same obligation |
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
| Scout intel log: `POST /api/maps/:map_identifier/scout/{spawns,structures}` ingests rows of eveknob's `special_spawns.tsv` / `structures.tsv` (`obj_SpawnLog.iss`, `obj_StructureWatch.iss`) as an append-only fleet-intel log, rendered at **`/scout`** — a top-level route with its own sidebar icon, deliberately NOT under `/corp`: its permission is granted by the instance owner, not by a corp admin. Ingest rides `:api_map` so the bot authenticates with the map `public_api_key` it already holds for signature sync; the stored log is NOT map-scoped (map recorded as provenance only). Every value may arrive as a string and re-sends are normal: rows upsert on a natural identity, and one malformed row is reported without rejecting the batch. The observing character is **dropped, not stored** — an older client may still send `character`, it is ignored. `timer_seconds` (relative, `-1` = none) is resolved to an absolute `timer_expires_at` at ingest. **Reading it needs `:scout_intel_view`, which ONLY the `WANDERER_BOOTSTRAP_ADMIN_CHARACTER` user can grant** (`/scout/access`) — a `corp_suite_admin` cannot, deliberately. Both tabs have the same shape: a time-critical lead that ticks every 30s without a query (structures: running reinforcement timers; spawns: "Seen in the last 24h", the latest sighting per system+location+spawn within 24h, a horizon deliberately independent of the window selector and aged out by that same tick), the flat log, and a per-subject history drill-down. The spawns tab has NOTHING between those two on purpose: its hotspot aggregate was deleted in 1.103.4-chewy.75 because "this belt has had 7 spawns in 30 days" never changed what anyone did next, and it cost a `GROUP BY` on every read of the tab. The page is pushed to by ingest (`"scout_intel"` PubSub topic), folds latest-per-structure AND latest-per-spawn in Postgres (`DISTINCT ON`), never truncates silently (reads `limit + 1`; the extra row IS the banner), and exports the same filtered rows with every stored column at `/scout/export.csv`. **Every filter applies to every table on the tab**, the two that ignore the window selector included: one ILIKE, a click-to-filter system chip, and a six-chip space-type filter (High/Low/Null/W-Space/Pochven/Other) whose classification comes from a `map_solar_system_v2.system_class` subquery — NOT from the row's stored `system_truesec`, which cannot separate J-space from Pochven from null — with `:other` defined as the `NOT IN` complement so the selection is total and all six selected means no SQL filter at all. One asymmetry worth knowing: a spawn has no id, so its drill-down is keyed on `{solar_system_id, location_name, spawn_name}` — the `:uniq_sighting` identity the resource already upserts on. Two traps in `structures.tsv`, both handled: its header names 24 columns while the writer emits 26 (`anchoring`/`unanchoring` were added between `vulnerable` and `timer_seconds` and the header was never rewritten), and its `type_name` column actually holds the player-set structure name. See `docs/chewy/scout-intel.md` | `WANDERER_SCOUT_INTEL` | `lib/wanderer_app/scout/{ingest,stats,space}.ex`, `lib/wanderer_app/api/scout_{spawn,structure}_sighting.ex`, `lib/wanderer_app/identity/scout_access.ex`, `lib/wanderer_app_web/controllers/{scout_intel_api_controller,scout_export_controller}.ex`, `lib/wanderer_app_web/controllers/plugs/check_scout_intel_disabled.ex`, `lib/wanderer_app_web/live/scout/scout_{intel,access}_live.ex` (+ `.html.heex`), `lib/wanderer_app_web/components/scout_nav.ex` (+ hooks in `router.ex` `:api_scout_intel` + `:scout_intel` pipelines, its own `/api/maps/:map_identifier` scope and a top-level `/scout` scope + `live_session` + the `export.csv` route outside it, `env.ex` `scout_intel_enabled?/0`, `api.ex` resource registration, `config/runtime.exs` env var, `live/nav.ex` `show_scout?` assign + `active_tab` cases, `components/layouts.ex` one sibling call inside `sidebar_nav_links/1`) |
| Scout coverage ledger: `POST /api/maps/:map_identifier/scout/coverage` records "I finished looking at system S to depth K at time T", even when nothing was found — the one fact the scout-intel sighting tables and `map_system_signature` cannot answer, since their timestamps only move when content changes. `kind` is a CLOSED vocabulary (`visit \| anoms \| sigs \| grid`); storage is table `scout_system_coverage_v1`, **upserted on `(solar_system_id, kind)`** — latest-wins, NOT an append-only log like the sighting tables, and `map_id` is provenance-only and never part of the identity. `observed_at` accepts EITHER an ISO8601 UTC string OR an integer unix-epoch-seconds value; an incoming row older than or equal to the stored one is skipped (still counted as `stored`, since the ingest succeeded idempotently). The `grid` kind also carries the clean-tour verdict: `spawns_found` (scanned locations since arrival with at least one special spawn present — `0` is the point of the feature, meaning toured and clean) and `legs_total` (that pass's `TourOrder.Used` leg count), both OPTIONAL/nullable like every other kind-specific field here; the CLEAN vs partial-tour verdict is derived server-side by the Scout planner row below from these two fields plus `legs_scanned`, never sent by the client as a boolean. Ingest rides `:api_map`, its own router pipeline/scope independent of `:api_scout_intel` so the two flags gate separately. Never creates a `map_system` row, never touches the map canvas. Phase 1 of `docs/design/wanderer-scout-planner.md` in the eve-command-center monorepo; the rows it writes are read by the Scout planner row below, which is the only consumer | `WANDERER_SCOUT_COVERAGE` | `lib/wanderer_app/api/scout_system_coverage.ex`, `lib/wanderer_app/scout/coverage.ex`, `lib/wanderer_app_web/controllers/scout_coverage_api_controller.ex`, `lib/wanderer_app_web/controllers/plugs/check_scout_coverage_disabled.ex` (+ `:api_scout_coverage` pipeline/scope in `router.ex`, `env.ex` `scout_coverage_enabled?/0`, `config/runtime.exs`, resource registration in `api.ex`) |
| Scout planner: `GET /api/maps/:map_identifier/scout/plan` + the `/scout/planner` page turn the coverage rows above into "what needs re-scouting", and `POST .../scout/plan/waypoints?character_eve_id=` pushes the result onto that character's autopilot through **ESI** (`POST /ui/autopilot/waypoint`, one call per stop, first with `clear_other_waypoints`, halting rather than skipping on failure; the response header carries `pushed=<N>`, which may be fewer than the stops listed). The push lives here because a multi-stop CUSTOM route cannot be set from the game client at all — eveknob can set one destination, not an ordered list — and this app already holds every tracked character's token with `esi-ui.write_waypoint.v1` in `default_scope`, the same call the map's own destination button makes. `WandererApp.Scout.Planner` BFSes an adjacency index cached from `map_solar_system_jumps_v1` (built once, never per hop), scores every in-scope system `need*W - jumps*W + value*W + frontier*W - claimed*W` with per-kind TTLs that are **labelled guesses in code** (nothing measures respawn cadence), and returns `rank/1` (score order) or `plan/1` (nearest-neighbour route, origin excluded — a destination equal to the current system leaves EVE with no route and spins the bot); `rank_plan/1` returns both from ONE candidate pool, which is what the page calls — the page needs both at once and was paying for the pool twice. `frontier` — a `Wormhole` signature with no connection off it — is the only term that reads the map, and is exactly 0 without a `map_id`. Three wire formats: `json`, `text` (one stop per line), and `flat` (ONE line, `;`-joined), the last because isxbob has no JSON parser and no proven multi-line split. Chain stops are ranked and shown but emitted `leg != gate` and never pushed — wormhole activation is not a proven verb. **The page runs every read in a task** (`start_async/3`, one monotonic token per read so a result that lands after its controls changed is dropped): a rank, a sweep and a split each took a second or more inside `handle_event/3`, which blocks that LiveView, so every other click queued behind the one in flight. The previous answer stays on screen, dimmed, with a spinner in the header. **Region scope is a name search**, not the `ids, comma-separated` box both modes shipped with — `WandererApp.Scout.Regions` caches the distinct k-space region list for a day and `region_picker/1` renders type-to-search + chips. Phases 2-4 of `docs/design/wanderer-scout-planner.md` in the eve-command-center monorepo | `WANDERER_SCOUT_PLANNER` | `lib/wanderer_app/scout/planner.ex`, `lib/wanderer_app/scout/regions.ex`, `lib/wanderer_app/scout/plan_waypoints.ex`, `lib/wanderer_app_web/controllers/scout_plan_api_controller.ex`, `lib/wanderer_app_web/controllers/plugs/check_scout_planner_disabled.ex`, `lib/wanderer_app_web/live/scout/scout_planner_live.ex` (+ `.html.heex`) (+ `:api_scout_planner` pipeline/scope, the `POST .../scout/plan/waypoints` route and the `/scout/planner` live route in `router.ex`, `env.ex` `scout_planner_enabled?/0`, `config/runtime.exs`, `field/1` `note/1` `busy/1` `region_picker/1` + new cells in `components/scout_components.ex`, the Planner tab link in `scout_intel_live.html.heex`, `:scout_planner` in `live/nav.ex` + `components/scout_nav.ex`) |
| Scout region sweeps: `GET .../scout/plan?mode=sweep&scope=region:ID` answers "visit every system in this region that still needs looking at, cheaply", instead of the rank mode's "10 most urgent near me". `WandererApp.Scout.Sweep` takes the scope as a MEMBERSHIP (not a BFS ball), routes over the FULL k-space graph (some regions are internally disconnected -- Sinq Laison -- so the induced subgraph would drop systems), greedy nearest-unvisited + 2-opt, and suggests the top 3 start systems (a dead end wins in every region measured). **Waypoint compression**: a stop is dropped only when EVERY shortest path between the surrounding kept waypoints runs through it, verified by deleting it from the graph; a coverage re-walk runs on every call and falls back to the uncompressed list rather than emit a route with holes. It assumes the pilot routes shortest with no avoidance list -- ESI cannot read that setting, so it is an operator-declared option, never silent. **Security-band focus**: `security=hs,ls,ns,wh,pochven` -- the toolbar's space chips, `sweep_security` -- picks which systems are STOPS, never which graph the route runs over, so "sweep Metropolis, lowsec only" is 50 stops that still drive through the region's 108 highsec systems. `region_heat/2` counts the SAME bands so the table you pick a region from and the sweep you get agree; it is the one place in `sweep.ex` that buckets space from `system_class` (7/8/9/25) instead of `Planner.classify_space/2`, because it aggregates every k-space system in the game and must not drag 5k rows through the BEAM -- verified zero disagreement against the live static map. `security=` now applies to `mode=rank` too (it was read for sweeps only), and an unrecognised band is a 422, never a silent empty plan. `WandererApp.Scout.Split` carves a scope into k balanced routes (farthest-point seeds, capacity-balanced assignment, Lloyd, then a makespan rebalance under a 2 s wall-clock budget) and `scout_assignments_v1` makes the carve-up stick across boxes: one owner per `(system, kind)`, 12h expiry, completed automatically when a coverage row lands. Wire format for sweeps is `#plan 2` with an 8th `wp` column; rank mode still answers `#plan 1` with 7. Measured on real Domain data: 189 systems, 273 jumps, 86 waypoints, k=4 makespan 3.41x. Phases 1-5 of `docs/design/wanderer-scout-region-sweeps.md` | `WANDERER_SCOUT_PLANNER` (same flag as the planner) | `lib/wanderer_app/scout/{sweep,split,assignments}.ex`, `lib/wanderer_app/api/scout_assignment.ex` (+ migration `20261005000407_add_scout_assignments`), (+ `mode=sweep` in `scout_plan_api_controller.ex`, sweep mode / start picker / region heat / k-split blocks in `live/scout/scout_planner_live.*`, `space_chip/1`'s per-instance `event`/`id` in `components/scout_components.ex` -- hardcoding them made the sweep's own band chips fire the rank mode's event -- plus its new cells, public `graph/0` + helper visibility in `scout/planner.ex`, completion hook in `scout/coverage.ex`, resource registration in `api.ex`) |

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

**On `/scout`, a board is a finding and the flat log is the tape.** Each status family that implies
an action gets its own `panel/1` board fed by its own scoped read action — Unanchored, Live timers,
Unanchoring, Anchoring, Abandoned (`Status.dead_family/0`: asset safety off or unfuelled) — and the
window-bounded flat log sits at the bottom of both tabs in `log_panel/1`: dashed border, monospace
label, muted body, deliberately NOT a `panel/1`. Two rules that follow: a new status worth acting
on gets a read action and a board, never a column on the log; and ordering is assigned in the BEAM
(`by_deadline/1` / `by_recent/1` in `scout_intel_live.ex`), never inherited from the query, because
every structure board's `DISTINCT ON` orders only to pick the surviving row per structure. Shield /
armor / hull is stored, exported and merge-significant but NOT rendered — a percentage triple read
hours later is not actionable.

**The Unanchoring board's deadline is derived, because the wire has none.** A decommission reports
no countdown (`timer_seconds` is reinforcement timers only), so the old "Comes out" column over
`timer_expires_at` was structurally a column of em dashes and `by_deadline/1` sorted that board on
nothing. EVE's decommission is a fixed **7 days** and a cancel restarts it, so
`WandererApp.Scout.Unanchor` anchors on `unanchoring_since` — the first sweep that saw the run,
cleared the instant the status leaves the family — and renders `≤ first sighting + 7d`: an upper
bound, never a timer. Orbitals are excluded (minutes, not days). Keep the direction: a stale anchor
that survived a cancel would under-predict, which is the only error that gets a fleet killed.

**No distances anywhere on `/scout`.** `distance_m` was the observing character's own range — it
located the scout, not the structure, and died with that session — and `nearest_celestial_m` is real
but unactionable. The `Where` column is `ScoutComponents.where/1`: the nearest celestial's NAME or
an em dash, no fallback, and no duplicate copy under the structure name on tables that have the
column. Both metre fields stay stored, merge-significant and exported; only the UI dropped them.

**A reader can archive a structure, and the expiry clock is `last_changed_at`.** `✕` on any
structure board (`ScoutComponents.archive_cell/1`) sets `archived_at` on the current-state row; every
opportunity board, the red banner and the sidebar badge filter `archived == false` through one expr
calculation on `WandererApp.Api.ScoutStructure`, and the row moves to its own window-independent
**Archived** board, where `↺` undoes it. It is never a delete — the ingest log, the drill-down and
the CSV export keep it, and `presence` is untouched. The clock is the point: a sweep re-confirming
the same hull moves `last_confirmed_at` every few minutes, so keying suppression on THAT would make
the button useless in the one case it exists for; only a real state change (`last_changed_at`)
brings a finding back. Any new board added to this page must carry the same filter, or an archived
structure reappears on it alone.

**`/scout` is ONE LiveView with three URL-driven categories, and the planner is a nested child.**
`WandererAppWeb.ScoutIntelLive` is the only routed view under `live_session :scout`: `/scout` and
`/scout/structures`, `/scout/spawns`, `/scout/planner` are its `live_action`s, so switching category
is a `<.link patch>` into `handle_params/3` — never a remount, which is what removes the live
layout's `opacity-0 → duration-500` fade, the scroll reset and the rebuilt chrome, and what makes
every category deep-linkable. `ScoutPlannerLive` is NOT routed any more: it is `live_render`'d as
`#scout-planner-live` inside the shell-owned `#scout-planner-pane`, mounted lazily on the first
visit and then only ever hidden with a class — unmounting it would discard a sweep that cost
seconds. A nested child skips `live_session`'s `on_mount` chain, so it resolves `current_user` from
the session itself and re-checks `ScoutAccess.can_view?/1` and its flag rather than trusting the
parent, and it must never `push_patch` (a child does not own the URL). Page chrome is
`<.scout_header>` → optional alert → `<.scout_toolbar>` → body for EVERY category, all from
`ScoutComponents`, which is why nothing moves when you switch.

**`/scout`'s filters are sticky, in localStorage, PER CATEGORY, with no new JavaScript.** Window,
search, system chip and space ride upstream's generic `LocalStorageSetting` hook
(`ls_restore_<key>` on mount, `ls_update_<key>` on change) through a hidden `#scout-filter-store`
div. The stored blob is keyed by category (`{"structures": {…}, "spawns": {…}}`, planner on its own
`scout_planner_filters` key) because the single flat blob it used to be was a reported bug:
narrowing structures to highsec silently narrowed spawns too. No `tab` key is stored — the URL owns
that, and restoring it after first paint is exactly what made landing on `/scout` flash through the
wrong category. A legacy flat blob migrates onto the category its old `tab` key names. Server-side
storage was rejected on purpose: a Cachex entry dies with every deploy. Everything restored is
re-validated like a click — localStorage is user-writable, and `String.to_existing_atom/1` on a
stored string is how a page crashes on mount.

**A `/scout` board leaves this app as a Discord message, never as a screenshot or a webhook.**
Each board header and the toolbar carry a copy button; `WandererAppWeb.ScoutDiscord` formats the
rows the socket ALREADY holds (so the paste matches the filters on screen) into Discord's own
`<t:unix:R>` / `<t:…:f>` timestamp markup, which keeps counting down in the channel and renders in
each reader's timezone — the single reason this is text and not a picture. Three constraints are
load-bearing: Discord REJECTS a message over 2000 characters rather than cutting it (so every board
is fitted to the budget and says "_… N more not shown_" when it drops rows, and the digest shares
the budget fairly with carry-forward instead of letting the first board eat it); timestamps do NOT
render inside a code fence, so the message is plain markdown; and therefore every wire value is
escaped, because an EVE structure named `*** |LOOT PINATA| ***` would otherwise spoiler-tag half
the channel. Nothing is posted server-side — no webhook URL is stored and no outbound call is made.
See `docs/chewy/scout-intel.md` §"Pasting a board into Discord".

**A control whose only result renders below the fold reads as broken.** Reported 2026-10-05, in
those words: "changing split in ui doesnt do anything". It did -- `update_sweep_k` recomputed the
parts in ~2.3 s and rendered them correctly (proven by replaying the event against real 189-system
Domain data), but the panel sat under a 189-row sweep table, a screenful down. On `/scout` a table
can be hundreds of rows, so any control that produces one must ALSO report its outcome inline next
to itself ("3 parts, longest 94 jumps"), and the panel it fills belongs ABOVE the long table, not
after it. The same trap applies to any future per-row action on these pages.

**A sweep a scout repeats every evening must be the SAME sweep, so `sweep_stable` is on by
default.** Reported 2026-10-06: "i am getting completely different 3 way split in delve than we had
before. We used to start in RF-K9W / 23G-XC / R5-MM8 ... I need consistent routes so that i do my
officer and faction scouts". Nothing in the algorithm had changed; three inputs had. A sweep's
MEMBERSHIP is time-dependent by default — anything inside `Planner.ttl_seconds(kind, class)` of its
last coverage row is dropped as `:fresh` (so your own bot's coverage erases tomorrow's stops), and
anything "Assign all" claimed sits in `scout_assignments_v1` for 12h and is excluded outright — and
`Split`'s rebalance stopped at a 2 s WALL CLOCK, so a loaded box returned a different partition from
the same stops. Membership change moves the start systems, which is what a human notices. Stable
mode sets `include_fresh: true`, `exclude: []` and `budget_ms: 0`, making the plan a pure function
of scope + bands + kind + k. Measured cost of exhaustive balancing on a 189-system graph
(2026-10-06): k=3 4.8 s, k=4 2.5 s — both already identical to the budgeted answer, so only k=2
(62 s) actually pays. Any future knob that silently narrows a plan by TIME belongs behind this same
flag.

**A `Set route` push reports what ESI actually said, and three things made that impossible.**
Reported 2026-10-05: "I just tried to set planned route for Molden Heath and i wasnt getting it
ingame". The page said "Route set: N waypoints" every time, and the server log held nothing at all.
Upstream's `WandererApp.Character.set_autopilot_waypoint/3` DISCARDS ESI's answer and returns `:ok`
— right for the map's fire-and-forget destination button, a lie for a route — so
`WandererApp.Scout.PlanWaypoints` calls `WandererApp.Esi.set_autopilot_waypoint/4` itself. Reading
the answer needed two more fixes: `do_post_esi/3` counted only 200/201 as success, and **204 is the
only success `/ui/autopilot/waypoint` documents**, so a route EVE accepted came back
`{:error, "Unexpected status: 204"}`; and the POST path has no refresh-on-403 retry (`do_get_retry/5`
is the GET path's), so an expired token — normal for a pilot not currently tracked on an open map —
403s on every stop silently. The push now opens with one authenticated GET
(`/characters/{id}/online`), which refreshes the token through the GET path as a side effect and
answers the other question nothing could: EVE applies waypoints to a RUNNING client only, so a route
pushed at a logged-out pilot is accepted and discarded. Outcome, reason and stop number render
beside the button (`ScoutComponents.route_outcome/1`) and go to the log as one line per push. Any
future ESI write from this app inherits all three traps.

**Scout structure intel is deduplicated twice, and both halves are load-bearing.** The eveknob
client re-reports every structure on grid on every pass. Reads fold
(`DISTINCT ON (structure_id) ORDER BY observed_at DESC`) — the live timer table was missing that
fold and showed one row per poll — and writes merge: `lib/wanderer_app/scout/merge.ex` turns an
unchanged `SEEN` into a `:touch` of the stored row's `observed_at` rather than another insert,
comparing timers with a 120s tolerance because `timer_expires_at` is derived from a relative
countdown re-read each pass. `event: :change` is never merged. Add a structure board to `/scout`
without the fold and the duplicates come straight back.

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

**`_build/<env>/lib/wanderer_app/priv` is a symlink mix cannot replace on this box, and it costs
gate steps.** Mix re-links it on every start and compares the stored target with the path it would
write; Windows stores backslashes where mix passed forward slashes, so the comparison never matches
and mix tries to delete the link — which Erlang refuses for a directory symlink (`Cannot remove
symlink ... due to reason: not owner`). Only `cmd /c rmdir` removes one; `file:delete/1` and
`file:del_dir/1` both refuse. `check.ps1`'s `Repair-PrivDir` replaces it with a REAL directory
before every mix invocation (mix's other branch copies, and cannot raise), which is what makes
Compile/Format/Database/Seed/Tests runnable at all — they were five environmental FAILs before it.
**`-Boot` and `-Routes` are still red on this box** and the failures are NOT the code under test:
the booted server's Phoenix code reloader calls the same mix function on every request, re-creates
the link, and answers 500 to everything — including `/corp`, which no current change touches. When
a feature's route contract matters, prove it with a `WandererAppWeb.IntegrationConnCase` test
instead (`test/integration/scout_plan_api_test.exs` flips `:scout_planner_enabled` and asserts
404-vs-200 plus the wire body); that is deterministic and does not depend on this.

## Traps that cost real time here

- **Another agent may be editing this working tree right now, so `git add -A` is not a commit scope.**
  Observed 2026-10-04: `scout_intel_live.ex` was being rewritten by a second session while this one
  edited the same file; staging it whole carried half of that feature into a commit whose resources
  were still untracked, and the resulting image built with
  `WandererApp.Api.ScoutStructure.by_structure_id/2 is undefined` — `/scout`'s drill-down would have
  raised on click. Before committing, read `git status` for files you never touched, and treat the
  `#17 mix compile` step of `deploy.ps1 -Build` as the gate: an `is undefined` warning there means the
  commit is internally inconsistent, so do NOT put that tag in `.env`. Same reason a version bump is
  not optional even when someone else already bumped it — `@version` must be one you have not built.
- **The toolchain for this repo is `C:\erl26` + `C:\elixir1173`, and neither is on PATH by default.**
  `C:\Program Files\Elixir` (1.20) with `C:\Program Files\Erlang OTP` (OTP 28) is also installed and
  cannot build this project: `x509` fails with `no record AttributePKCS-10 found` in `PKCS-FRAME.hrl`.
  Worse, running `mix local.hex --force` under that pair rewrites `~/.mix/archives/hex-2.5.1` into a
  1.20 build, after which 1.17 dies with `corrupt atom table` — for every session on this box, not
  just yours. Prefix PATH explicitly, and if you do corrupt it, reinstall hex with 1.17's own mix.
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
- **Run `deploy.ps1` with `pwsh` (7.x), never `powershell` (5.1), from an agent shell.** The script
  sets `$ErrorActionPreference = "Stop"`, and under 5.1 a native command's stderr becomes an error
  record whenever the host's streams are redirected — which they always are for a tool-invoked
  shell. `docker compose pull` writes its progress to stderr, so the deploy aborted at `[4/5]` with
  exit 1 while the same command over plain `ssh` returned 0 (observed 2026-10-05, `-Build` died the
  same way at `[1/3]` on `git fetch`). PowerShell 7 does not promote native stderr, so
  `pwsh -NoProfile -ExecutionPolicy Bypass -File <wrapper>.ps1` runs it to completion.
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
- **A default-step `a..b` range NEVER yields zero iterations -- it flips descending.** `for i <- 0..(n-3), j <- (i+2)..(n-2)`
  in a 2-opt loop looked like an empty inner range on the last `i`; Elixir ran it backwards instead
  and read past the end of the tuple, crashing every route with >= 4 stops
  (`lib/wanderer_app/scout/sweep.ex`, 2026-10-05 -- two separate sessions hit it from different call
  sites within minutes). Any computed range whose bounds can cross needs an explicit `//1`, and a
  unit test at the SMALLEST n that exercises the loop, not a comfortable one.

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

Nothing probes the app container directly: port 8000 is `expose`d but never published, and the runner
image carries neither `curl` nor `wget`. Probe the public origin from the box instead, and read data
from Postgres — whose database is named `postgres`, not `wanderer_db`:

```bash
ssh ex44 "curl -s -o /dev/null -w '%{http_code}\n' https://wanderer.chewytech.com/scout"   # 302 = alive
ssh ex44 "sudo docker exec wanderer-db psql -U postgres -d postgres -c 'select count(*) from scout_structures_v1;'"
```

`/scout` and the rest of the LiveViews are SSO-only in production (`WANDERER_DEV_AUTH_TOKEN` is never
set there), so a deploy can prove routing, migrations and data but NOT a rendered page. Say so rather
than implying the page was seen.

Full operational notes: `projects/infrastructure/hetzner/wanderer/README.md` in the monorepo.
