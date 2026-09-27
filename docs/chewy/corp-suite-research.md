# Corp/Alliance Management Suite — Domain & Feasibility Research

Companion to a separate codebase-inventory pass. This half covers: (A) what corp/alliance
management actually is, (B) what in *this* repo is reusable, (C) the hard problems, (D) three
scoped proposals + a recommendation, (E) questions for the owner.

All codebase claims are `path:line` against the `chewy` branch as read on 2026-09-27. Constraints
below are load-bearing: **additive files only, no edits to hot upstream files, every feature gated
behind an env var defaulting to upstream behaviour** (`AGENTS.md:16-28`).

---

## A. The corp/alliance management feature space

Legend: **ESI-available** (CCP's API gives the data directly), **ESI-partial** (ESI has a piece,
rest is derived/aggregated/needs a third party), **needs-manual-entry** (no ESI source, it's a form).
Token column: **member** = any authenticated character; **director** = requires a role
(`Director`, `Personnel_Manager`, `Accountant`, station-manager roles, etc.) granted in-game, and
CCP's token is scoped to *that specific character*, not "the corp."

| Feature | ESI endpoints (representative) | SSO scopes | Token holder | Status |
|---|---|---|---|---|
| **Member roster + affiliation** | `GET /characters/{id}/` (public), `POST /characters/affiliation/` (bulk, no scope) | none for affiliation; `esi-corporations.read_corporation_membership.v1` for full member list | member for affiliation ping; **director-ish** (`read_corporation_membership`) for the authoritative roster (titles, join dates need it too) | ESI-partial |
| **Member activity / last login** | `GET /characters/{id}/online/` | `esi-location.read_online.v1` | member, per-character | ESI-available (per character with a token; no bulk "who logged in last week" endpoint — must poll every tracked character) |
| **Skills & doctrine-fit compliance** | `GET /characters/{id}/skills/`, `/attributes/`, `/skillqueue/` | `esi-skills.read_skills.v1`, `esi-skills.read_skillqueue.v1` | member, own character only — no director bypass | ESI-available (per-character opt-in only; can't compel members to grant it) |
| **Fleet ops: scheduling** | none | — | — | needs-manual-entry (calendar/RSVP is pure app data) |
| **Fleet ops: attendance** | `GET /fleets/{id}/members/` only works *while the fleet is live and you're the FC/boss*, no historical query | `esi-fleets.read_fleet.v1` | FC/boss token, live-only | ESI-partial (live composition only; historical attendance is manual log-off-of-what-you-recorded) |
| **SRP (ship replacement)** | none (killmail hash can corroborate a loss) | — | — | needs-manual-entry, cross-checked against killmails |
| **Fittings / doctrines** | `GET /characters/{id}/fittings/` (character's saved fits only) | `esi-fittings.read_fittings.v1` | member, own fits | ESI-partial (no corp-wide "the doctrine list" endpoint — doctrine catalog is app data; ESI only confirms a member *has* a fit saved) |
| **Structures & timers** | `GET /corporations/{id}/structures/` (full, incl. fuel/vulnerability), `GET /universe/structures/{id}/` (public, name/position only) | `esi-corporations.read_structures.v1` | **director** (station-manager role) for the full list; public endpoint needs no scope but gives almost nothing | ESI-available for owned structures; this repo already tracks *foreign* structure sightings manually (`lib/wanderer_app/api/map_system_structure.ex:1-25` — name/owner/status/`end_time` are free-text/manual fields, no ESI sync) |
| **Industry / mining ops** | `GET /characters/{id}/industry/jobs/`, `GET /characters/{id}/mining/`, `GET /corporations/{id}/mining/observers/` | `esi-industry.read_character_jobs.v1`, `esi-industry.read_character_mining.v1`, `esi-industry.read_corporation_mining.v1` (director, needs mining observer set up) | member for own jobs; **director** for corp mining ledger | ESI-available |
| **Wallet / journal / taxes** | `GET /characters/{id}/wallet/`, `/wallet/journal/`, `GET /corporations/{id}/wallets/{div}/`, `/journal/` | `esi-wallet.read_character_wallet.v1`; `esi-wallet.read_corporation_wallets.v1` (**director**, Accountant/Junior_Accountant role) | member for personal; **director** for corp wallets | ESI-available — **already built**: `lib/wanderer_app/api/corp_wallet_transaction.ex:1-133`, `lib/wanderer_app/init_corp_wallet_tracker_task.ex:1-53`, scopes `lib/wanderer_app/character.ex:9-10,203-213` |
| **Contracts** | `GET /characters/{id}/contracts/`, `GET /corporations/{id}/contracts/` | `esi-contracts.read_character_contracts.v1`, `esi-contracts.read_corporation_contracts.v1` (director) | member / director | ESI-available |
| **Assets** | `GET /characters/{id}/assets/`, `GET /corporations/{id}/assets/` | `esi-assets.read_assets.v1`, `esi-assets.read_corporation_assets.v1` (director) | member / director | ESI-available (corp assets endpoint is notoriously heavy — full re-page every call, no delta) |
| **Killmails / stats** | `GET /characters/{id}/killmails/recent/` + `GET /killmails/{id}/{hash}/` (ESI only gives *your own* char/corp mails, needs the token owner to have been involved) | `esi-killmails.read_killmails.v1` (character), `.read_corporation_killmails.v1` (director) | member/director, and only mails they were a party to | ESI-partial — **zKillboard is strictly better here**: public, no token, alliance-wide, has an existing killmail-format webhook (`ZKillboard websocket`/RedisQ) and this repo *already* consumes zKB, not ESI (`lib/wanderer_app/map/map_zkb_data_fetcher.ex:1-16`, `lib/wanderer_app/kills/*`) |
| **Recruitment / application pipeline** | `POST /characters/affiliation/` to verify a corp claim; nothing else | none beyond affiliation check | member (applicant logs in) | needs-manual-entry (the workflow is 100% app-side; ESI only corroborates identity/corp at the moment of login) |
| **Standings / contacts** | `GET /characters/{id}/contacts/`, `GET /alliances/{id}/contacts/` (director), `GET /characters/{id}/standings/` | `esi-characters.read_contacts.v1`, `esi-alliances.read_contacts.v1` (director) | member / director | ESI-available |
| **Notifications / Discord pings** | `GET /characters/{id}/notifications/` (structure attacks, wars, etc.) | `esi-characters.read_notifications.v1` | member (whoever's token is polled) | ESI-partial — this repo already has a generic Discord/webhook fan-out (`lib/wanderer_app/external_events/webhook_dispatcher.ex`) that's the right hook point; ESI notifications are noisy/character-scoped, most alliances get this better from a structure-ping bot |
| **Maps / intel** | n/a — this is the existing product | n/a | n/a | **already exists**, this is the base to extend, not build |

**Takeaway for A:** everything director-scoped (corp wallet, corp structures, corp mining
ledger, corp contracts/assets, corp killmails, alliance contacts) needs a **second, higher-privilege
SSO grant** from whoever holds that role — it is not obtainable via the ordinary member login flow,
and CCP does not let you request "director scopes if you happen to have the role"; the app must ask
for the scope, EVE SSO always shows the consent screen, and the *character* must actually hold the
role at request time. Corp wallet is the only director-scoped feature already implemented here.

---

## B. Fit with this codebase

| Building block needed | Exists? | Evidence | Verdict |
|---|---|---|---|
| SSO login + OAuth2 flow | Yes | `lib/wanderer_app/ueberauth/strategy/eve.ex:1-180`, `.../eve/oauth.ex:1-118` (Ueberauth + `OAuth2.Strategy`), routed through `config/config.exs:46-54` / `config/runtime.exs:325-333` for three named scope tiers (`default_scope`, `wallet_scope`, `admin_scope`) | Reusable pattern — a 4th tier (`director_scope`) is additive config, same shape |
| Token storage + refresh | Yes | `lib/wanderer_app/api/character.ex:198-203` (`scopes`, `access_token`, `refresh_token`, `expires_at` columns, `AshCloak`-encrypted via `lib/wanderer_app/vault.ex:1-22`), refresh logic in `.../ueberauth/strategy/eve/oauth.ex:85-113` (`refresh_token`) | Reusable as-is; a director grant is just another `Character` row for the same EVE character with a superset of scopes in `scopes` |
| Scope-gated ESI calls | Yes | `WandererApp.Character.can_track_wallet?/1`, `can_track_corp_wallet?/1` (`lib/wanderer_app/character.ex:203-213`) check the `scopes` string before calling ESI | This is the house pattern to copy for `can_track_corp_structures?/1`, `can_track_corp_contracts?/1`, etc. |
| ESI client + rate-limit/error-limit handling | Yes | `lib/wanderer_app/esi/api_client.ex` already parses `x-esi-error-limit-remain`/`-reset` headers and emits telemetry (`:512-536`), two dedicated Finch pools (`lib/wanderer_app/application.ex:20-41`) | Reusable — new endpoints are new `WandererApp.Esi.ApiClient` functions behind `WandererApp.Esi` delegates (`lib/wanderer_app/esi.ex:1-5`), same pool |
| Background job / polling infra | Yes | Per-character tracker GenServers + pools (`lib/wanderer_app/character/tracker*.ex`, `tracker_pool*.ex`), a working precedent for a *privileged, singleton* corp-level poller in `lib/wanderer_app/init_corp_wallet_tracker_task.ex:1-53` (one designated character's token drives a corp-wide feed) and `lib/wanderer_app/character/transactions_tracker*.ex` | Directly reusable template for corp structures/contracts/mining pollers — same "one admin character, one env var naming it" shape |
| Roster / affiliation data model | Partial | `Character` resource already has `corporation_id/name/ticker`, `alliance_id/name/ticker`, `online`, `eve_wallet_balance`, `last_active` action (`lib/wanderer_app/api/character.ex:180-227`, `:27`); refreshed on every login (`update_character_affiliation/1`, `lib/wanderer_app_web/controllers/auth_controller.ex:68-158`) | Good foundation for "who's in the corp," but it is **derived from who has ever logged into this app**, not a full ESI membership pull — no corp-membership-endpoint poller exists, so anyone who never logged in is invisible |
| Structures/timers | Partial, manual only | `lib/wanderer_app/api/map_system_structure.ex:1-25,38-40` — free-text `name`/`owner_name`/`status`/`end_time`, filled in by mappers spotting a structure, not synced from ESI | Good UI/data shape to extend with an ESI-backed sync job for *owned* structures, additive |
| Killmail pipeline | Yes, zKB not ESI | `lib/wanderer_app/kills/{client,storage,message_handler,config}.ex`, `lib/wanderer_app/map/map_zkb_data_fetcher.ex:1-16` | Reuse the ingestion/storage pattern for alliance-wide stats; ESI killmail endpoints add nothing zKB doesn't already give more easily |
| Per-map ACLs / roles | Yes | `lib/wanderer_app/permissions.ex:1-62` (bitmask viewer/member/manager/admin), `lib/wanderer_app/api/access_list.ex:1-31` (Ash resource + policy) | This is a **map-scoped** ACL, not a corp-wide one — a corp suite needs a *new*, separate authorization axis (e.g. "director of corp X" vs "map admin"), additive resource + policy module, do not repurpose `Permissions` |
| Encryption for sensitive resources | Yes | `AshCloak` used on `Character` (`api/character.ex:152-175`) and `CorpWalletTransaction` (`api/corp_wallet_transaction.ex:77-91`) | Same extension covers any new PII/financial resource (assets, contracts, journal) |
| Webhook/Discord fan-out | Yes | `lib/wanderer_app/external_events/webhook_dispatcher.ex`, generic `event.ex`/`event_filter.ex` | Reusable sink for fleet-ping / SRP-approved / doctrine-updated notifications instead of building a new Discord integration |
| LiveView UI shell + design system | Yes | `lib/wanderer_app_web/live/{maps,characters,admin}/*_live.ex` + `.html.heex`, `core_components.ex`, nav (`live/nav.ex`) are the established page/route/component idiom | New corp pages are new LiveView modules mounted under new routes in an additive router include, following e.g. `map_characters_live.ex` as the template |
| External JSON:API surface | Yes | `lib/wanderer_app_web/api_v1_router.ex`, `api_router.ex`, `AshJsonApi.Resource` extension already used on `AccessList`/`MapSystemStructure` | New corp resources get JSON:API for free via the same extension; auth via existing `check_json_api_auth*` plugs pattern |

**Greenfield (genuinely new, no analog in repo):** fleet scheduling/RSVP, SRP request/approval
workflow, recruitment pipeline/application forms, doctrine-fit calculator (skill-vs-fit diff),
a corp-wide authorization model distinct from map ACLs, any UI for director-only data.

---

## C. Hard problems / risks

| Risk | Detail | Mitigation posture |
|---|---|---|
| **Multi-scope SSO without breaking mapper login** | Three scope tiers already coexist via named Ueberauth configs selected by query param (`is_admin?`/`with_wallet` in `lib/wanderer_app/ueberauth/strategy/eve.ex:28-34`, `config/runtime.exs:325-333`). A 4th "director" tier is additive to that same `cond`, but the entry point that sets `is_admin?`/`with_wallet` is `characters_live.ex:66-76` (existing file — must be edited, small, or forked into a new additive "request director access" LiveView action that calls the same underlying Ueberauth config by a new param) | Add a new query param + config block, never touch the existing two paths; new login button lives in a new component, not `characters_live.html.heex` |
| **Token scope upgrade flow** | EVE SSO has no "add a scope" — it's a brand-new authorize + consent screen; the returned character has a *new* token that must overwrite the old `Character` row's `scopes`/`access_token`/`refresh_token` without breaking existing trackers mid-flight (a tracker GenServer may be holding stale token in its state) | Reuse `update_character/2` (`character.ex:93-109`, Cachex-backed) which already coalesces; trackers re-read from cache each poll, so refresh, not restart, is likely sufficient — verify with a throwaway smoke test before shipping |
| **ESI rate limits / error-limit (420)** | Already instrumented (`esi/api_client.ex:360-420`), but corp-wide pollers (assets, structures, contracts) are **much heavier** per call than character trackers — a full corp asset list is multi-page with no delta endpoint. Adding these to the shared `WandererApp.Finch.ESI.General` pool risks starving character tracking | Give heavy corp-scope endpoints their own Finch pool + generous poll interval (mirror `map_zkb_data_fetcher.ex`'s 15s/1h cadence choices, but slower — hours, not seconds — for assets/contracts) |
| **Corp-role verification & privilege escalation** | ESI does not expose "is this character a Director" via a cheap call usable at login time — `GET /characters/{id}/roles/` requires `esi-characters.read_corporation_roles.v1` and is itself scope-gated. A malicious/former-director could keep a valid director-scoped token after being demoted; ESI calls with a stale-but-technically-valid token will 403 once CCP re-checks the role server-side on each request (CCP enforces role-at-call-time for role-gated endpoints), so escalation via a stale token is largely self-limiting at the ESI layer — but the app must not cache "is director" as a boolean past token refresh | Never store a derived `is_director` flag; re-derive per privileged action, or accept ESI's 403 as the enforcement boundary and surface it cleanly |
| **PII / data retention** | Corp wallet journal, member assets, contracts all contain real names, isk amounts, locations — more sensitive than current map/character data. `AshCloak` + `Vault` (`vault.ex:1-22`) already cover encryption-at-rest for tokens/wallet rows; a corp suite multiplies the *volume* of sensitive rows | Reuse `AshCloak` on every new PII-bearing resource; add explicit retention/purge job (none exists today) since journal/killmail history has no natural TTL |
| **DB growth (journal/assets/killmails)** | `CorpWalletTransaction` and kill storage already exist with no visible purge — `lib/wanderer_app/kills/storage.ex` uses a 24h TTL for map-kill cache (`map_zkb_data_fetcher.ex:14`) but that's an in-memory/cache TTL, not a DB retention policy. Corp wallet journal is unbounded, and a full asset/contract sync is O(members × items) | Cap history windows (e.g. 90-day journal), paginate/cursor corp assets rather than storing every snapshot, decide retention *before* first sync, not after the table is large |
| **Upstream merge cost** | Everything above is designed additive-file per `AGENTS.md` rule 4, but two touchpoints are unavoidable edits to hot files: (1) whatever triggers the "request director scope" login button — currently `characters_live.ex`/`.html.heex` — and (2) mounting new LiveView routes into `router.ex`. Both are exactly the kind of one-line-hook pattern already used for `persistent_tracking.ex` (4 one-line hooks, `AGENTS.md:36`) | Budget the same "N one-line hooks" cost per feature as existing patches; document each hook in `AGENTS.md`'s patch table so merges are a known, not surprising, diff |
| **Director leaves** | If the character supplying the corp-wide token (wallet, structures, contracts) is kicked/leaves/quits ESI access, every corp-scope poller silently starts 403ing. The existing corp-wallet tracker already has this exact single-point-of-failure (`init_corp_wallet_tracker_task.ex:24-30` picks one hardcoded `corp_wallet_eve_id`) | Needs an admin UI to re-point the "which director's token feeds this" pointer without a redeploy, and alerting when a corp-scope poller starts erroring — none of this exists today even for the one corp-wallet feature already shipped |

---

## D. Product shaping — three scopes

### Scope 1 — "Thin" (2–3 weeks)

Roster + activity visibility only, no director scopes beyond what's already used for wallet.

- Member roster page: corp/alliance affiliation, `online`, last-seen, from data already collected at login (`character.ex:180-227`) — pure read of existing columns, new LiveView page only.
- "Who hasn't logged in in N days" report — same data, a query + a page.
- Discord ping on member join/leave to the corp (reuses `webhook_dispatcher.ex`), driven by the affiliation-refresh that already runs on every login (`auth_controller.ex:68-158`).
- Env gate: `WANDERER_CORP_ROSTER` (bool).
- Merge cost: near zero — no new SSO scope, no new poller, one new route, one new nav entry (1-line hook, same class as existing patches).

### Scope 2 — "Medium" (4–8 weeks, builds on Scope 1)

Adds a genuine director-token path and a handful of high-value director-scoped feeds.

- Director-scope SSO tier (`director_scope` config block + new login entry point), token stored on the same `Character` resource.
- Corp wallet (already built — wire it into UI) + corp structures/timers sync (poll `read_structures`, merge into a new resource, distinct from the existing manual `MapSystemStructure`) + corp contracts (read-only ledger).
- Fleet scheduling + RSVP (greenfield, but simple CRUD + LiveView, no ESI dependency).
- Alliance-wide kill/loss stats dashboard sourced from the existing zKB pipeline (`map_zkb_data_fetcher.ex`), not ESI killmails.
- Env gates: `WANDERER_CORP_DIRECTOR_SCOPE`, `WANDERER_CORP_STRUCTURES_SYNC`, `WANDERER_CORP_CONTRACTS_SYNC`, `WANDERER_FLEET_OPS`.
- Merge cost: moderate — one new Finch pool config, one new hook into the login flow, otherwise additive resources/pollers/pages. This is where the "director leaves" and "scope upgrade" risks in §C become load-bearing and need the admin re-point UI.

### Scope 3 — "Full suite" (3–6+ months)

Everything in A that's ESI-available or ESI-partial, plus SRP workflow, recruitment pipeline,
doctrine-fit compliance, corp assets, industry/mining ledgers, standings.

- Every director-scoped endpoint, multiple heavy pollers (assets is the worst — no delta, full re-page), retention/purge jobs for journal & assets, a real "corp admin" authorization model separate from map ACLs, recruitment application forms + review queue, doctrine-fit calculator against `esi-skills`.
- Env gates: one per subsystem, ~10+ flags.
- Merge cost: high, ongoing — this is effectively building (a slice of) Alliance Auth / SeAT inside a mapper fork, maintained by one person against an upstream that ships weekly.

### Recommendation: **Scope 2 ("Medium")**

- Scope 1 alone under-delivers on "corp/alliance management tool" — it's a roster page, not a tool.
- Scope 3 duplicates **Alliance Auth** and **SeAT**, both mature, community-maintained, already do recruitment pipelines, SRP, doctrine-fit, full asset/industry ledgers, and standings — building that solo against a fork that must forever re-merge upstream is not a good trade; **integrate** (link out / webhook into an existing Alliance Auth or SeAT instance) rather than rebuild those specific features, if one exists (see open question E.2).
- Scope 2's fleet scheduling and structure timers are the two things a mapper audience actually feels day-to-day (this app already shows wormhole structures manually — syncing owned-structure timers is a natural, low-risk extension of exactly what the product already does).
- The corp-wallet precedent (`init_corp_wallet_tracker_task.ex`) proves the "one director token feeds a corp-wide poller" shape already works in this codebase — Scope 2 is mostly replicating that shape three more times, not inventing a new architecture.
- Killmail/stats via the existing zKB pipeline is nearly free (data already flows in) — high value, near-zero new merge cost, worth doing regardless of which scope is picked.
- Recruitment, SRP-as-a-full-workflow, and industry/mining ledgers are deliberately deferred to a possible future Scope 3 decision, not built speculatively now.

---

## E. Open questions for the owner

1. **Single corp or multi-tenant?** Does this stay one corp/alliance (as today, private branding for one alliance) or must it serve multiple corps with data isolation? Changes the entire authorization model (§B, "corp-wide ACL" row).
2. **Is there an existing Alliance Auth or SeAT install?** If yes, Scope 3 items (SRP, recruitment, asset ledgers, doctrine-fit) should integrate/link, not be rebuilt — changes Scope 2 vs 3 entirely.
3. **Is Discord already in use for the corp, and is there a bot with roles synced to EVE?** If yes, notification/ping work in §D should target that bot's webhook, not build new Discord OAuth.
4. **Roughly how many active members?** Under ~50, manual/lightweight roster (Scope 1) may be sufficient forever; at hundreds, ESI rate limits and DB growth (§C) become real constraints on poll intervals.
5. **Who holds/will hold the director-scope token, and what happens organizationally if they quit or lose the role?** Directly determines whether the "director leaves" mitigation (§C) is a nice-to-have or a launch blocker.
6. **Is SRP a formal, budgeted program or informal reimbursement?** Determines whether Scope 2/3 SRP needs an approval workflow + wallet payout integration, or just a loss-reporting form.
7. **Value of doctrine-fit compliance** (comparing member skills against required doctrine skills) — this requires *members* to grant `esi-skills.read_skills.v1` individually; is there appetite/mandate to require that, or is it opt-in-only and therefore partial coverage forever?
8. **Acceptable ops budget for new background pollers** — corp assets/contracts pollers add real DB and ESI load on the Hetzner EX44 box already running the mapper; is there a ceiling (RAM/DB size) that should cap Scope 3-style ambitions regardless of feature desirability?
