# SeAT / Alliance Auth Parity Reference

**Created:** 2026-09-27  
**Purpose:** Research-only fact collection for feature parity with industry-standard EVE auth systems.  
**PREMISE (Revised 2026-09-27):** *"We have no SeAT and I do not want 2 different auths. I want fully-fledged management in our tool."* **(Owner decision)** This app will be the alliance's **SINGLE auth + management platform — no external SeAT or Alliance Auth installation.** All features are assessed on value to this alliance alone; no assumption of external fallback systems.  
**Scope:** Single corp/alliance use case (~100 active characters), wormhole-focused.

---

## 1. SeAT Module Inventory (Revised: Single-Auth Decision)

**Source:** https://github.com/eveseat, https://github.com/eveseat-plugins  
**Question:** If we don't build this, what does the group lose, given there is no other system to fall back on?

| Module (Package) | Purpose / Core Features | Current Implementation | Loss if Not Built | Assessment |
|---|---|---|---|---|
| **seat-web** | Web UI, HTML rendering, dashboard, character/corp data views | None | Cannot manage corp at all; no UI | `MUST-HAVE` |
| **seat-eveapi** | OAuth2 EVE SSO handler, token storage, character auth | Wanderer's Ueberauth (default + wallet + admin scope tiers) | No SSO; manual account creation; no token refresh or multi-scope support | `MUST-HAVE` |
| **seat-services** | Discord/Mumble/Teamspeak connector framework, role sync | None (webhook_dispatcher exists; Discord bot integration planned) | Discord roles not synced to corp membership; manual role assignment | `MUST-HAVE` (if Discord is primary comms) |
| **seat-notifications** | Ingress for structure/war notifications from ESI | None (zKB for kills exists; structure notifications not polled) | No timely pings on attacks/wars/fuel; manual ESI UI monitoring; defense response time: hours | `MUST-HAVE` (for ops-critical alerts) |
| **seat-moons** | Moon anomaly tracking (tracker for moon events) | Wanderer only tracks K-space structure sightings; no moon harvestable tracking | Cannot track which moons are ready for extraction; no ESI polling visibility | `NICE-TO-HAVE` (if K-space moon ops relevant) |
| **seat-srp** | Ship Replacement Program (request/approval/payout tracking) | None | SRP handled manually (spreadsheet, Discord DMs); no audit trail; payouts manual; dispute resolution manual | `MUST-HAVE` (if formalized SRP with rules) / `SKIP` (if informal reimbursement only) |
| **seat-fitting** | Doctrine fitting library + skill-compliance checker | None | Doctrine enforcement manual; no skill audit; comms-based only; external tools (EFT, Osmium) used instead | `NICE-TO-HAVE` (low priority; external tools sufficient; opt-in scopes only) |
| **seat-recruitment** (WCS) | Application form + recruiter review pipeline | None | Recruitment manual (in-game PM, spreadsheet, Discord); no formal workflow; no vetting history; no application tracking | `MUST-HAVE` (if recruiting) / `SKIP` (if corp closed to applications) |
| **seat-buyback** | NPC buyback / price feed integration | None | Buyback handled manually; no price automation; no volume tracking; spreadsheet-based | `SKIP` (only if corp runs buyback program; otherwise none) |
| **seat-inquiry** | Discord bot connector for price checks, item lookups | None (webhook_dispatcher exists; could build bot) | Queries manual (external price bots, Zkillboard); no centralized lookup | `SKIP` (convenience only; external tools sufficient) |
| **seat-scheduler** | Ops calendar / fleet scheduling with RSVP | Discord events (Discord native, not app-integrated) | Fleet ops coordination via Discord only; no RSVP tracking; no automated attendance stats | `MUST-HAVE` (if ops-driven group) / `NICE-TO-HAVE` (if ad-hoc fleets only) |
| **seat-info** | Corp bulletin board, wiki/article system | Discord channels / external wiki | No centralized doc repository; knowledge siloed in Discord channels | `SKIP` (Discord channels + external wiki sufficient) |

---

## 2. Alliance Auth Feature Inventory (Revised: Single-Auth Decision)

**Source:** https://allianceauth.readthedocs.io, https://github.com/allianceauth  
**Question:** If we don't build this, what does the group lose, given there is no other system to fall back on?

| Module / Feature | Purpose / Core Features | Current Implementation | Loss if Not Built | Assessment |
|---|---|---|---|---|
| **Core: Auth / SSO** | OAuth2 EVE SSO, user account creation, token storage | Wanderer's Ueberauth (default/wallet/admin scope tiers) | No login via EVE; manual account creation only; no token refresh; single-scope tier | `MUST-HAVE` |
| **Core: States** | Member/Blue/Guest state machine, auto-assign from corp/alliance membership | Character.corporation_id/alliance_id tracking exists; no State machine | No automatic access tiers based on corp membership; manual role assignment; no automatic Discord access tier changes | `MUST-HAVE` |
| **Core: Groups** | Group RBAC, group requests, leadership, auto-sync corp/alliance membership to groups | AccessListMember role (map-scoped only, not corp-wide); no groups/auto-sync | No role-based access; no group management UI; group membership manual; no leadership delegation | `MUST-HAVE` |
| **Core: Permissions** | Django permission system, role-based access control | permissions.ex bitmask (map-scoped only) | No granular resource-level permissions; all-or-nothing access; no audit trail; no role-based delegation | `MUST-HAVE` |
| **Core: Discord Service** | Discord bot role sync, nickname sync, server join/kick | None (webhook_dispatcher exists; Discord bot planned) | Discord roles not synced to corp state; manual role management; members not kicked on leave; no visibility into who has access | `MUST-HAVE` (if Discord is primary comms) |
| **Discord (alt)** | `aa-discordbot` — advanced reaction roles, web integration | None | No reaction role workflows; no Discord command interface to app | `NICE-TO-HAVE` (can use external bot) |
| **Services: Mumble** | Mumble ACL sync | None (Mumble not used) | Mumble channels not managed via app; legacy service | `SKIP` (Mumble obsolete; use Discord) |
| **Services: Teamspeak3** | TS3 server groups sync | None (TS3 not used; Discord primary) | TS3 not managed via app; nobody uses it | `SKIP` (Discord supersedes) |
| **Services: SMF Forums** | Forum account sync, group bridging | None (no forums; Discord channels used) | Forums not managed via app; nobody uses them | `SKIP` (Discord supersedes) |
| **Apps: Corporation Stats** | Member roster, registration status, character relationships (main/alt detection) | Character.corporation_id/alliance_id only; no alt linking or main character tracking | No registry of who's registered; no main/alt detection; no member status dashboard; manual tracking | `MUST-HAVE` (corp management baseline) |
| **Apps: Structures / Timers** (`aa-structures`) | Structure/moon/starbase timer management, auto-create from ESI notifications | MapSystemStructure (manual sightings only, no ESI sync; no timers, no fuel tracking) | Structures tracked manually in Wanderer; no fuel tracking; no timer automation; no auto-created timers from notifications; timers only on Discord calendar (manual) | `MUST-HAVE` (ops-critical for PvP/PvE) |
| **Apps: Structure Timers II** | Enhanced timerboard UI, Discord ping rules | None | Basic timer view only; no structured ping rules; no threshold alerts (e.g., "ping 15 min before armor timer") | `NICE-TO-HAVE` (UX improvement on structures) |
| **Apps: FAT / AFAT** | Fleet Activity Tracking (participation logging, PAP stats) | None | No fleet attendance tracking; no participation stats; no CTA compliance metrics; informal PAP only (manual sign-up link) | `MUST-HAVE` (if ops-driven / CTA-mandated) / `NICE-TO-HAVE` (if casual fleet ops only) |
| **Apps: HRApplications** | Recruitment application forms + review workflow | None | Recruitment manual (in-game PM, spreadsheet, Discord); no application history; no structured review workflow | `MUST-HAVE` (if recruiting) / `SKIP` (if corp closed) |
| **Apps: Auto Groups** | Auto-create groups for each corp/alliance, auto-assign users | None | Groups manual; members must be individually added; no auto-sync on corp join/leave; high admin overhead | `MUST-HAVE` (if multi-corp alliance; reduces admin overhead significantly) |
| **Apps: Moon Extraction** | Moon extraction status + tracking | None | Cannot track extraction status; no ISK splits; manual coordination | `NICE-TO-HAVE` (if K-space moon ops) |
| **Apps: Timerboard** (built-in) | Simple timer CRUD UI | None | Timers managed elsewhere (Discord, spreadsheet); redundant with aa-structures | `SKIP` (same function as aa-structures; use aa-structures instead) |
| **Community: Fleetup/Optimer** | Op planning calendar sync (external service integration) | None (Discord events used) | Fleetup data not synced; comms-based only; requires manual duplication | `SKIP` (Discord events sufficient; Fleetup integration low priority) |
| **Community: Wiki** | In-app wiki for corp docs | None (external wiki or Discord channels) | Wiki manual; knowledge siloed; search unavailable | `SKIP` (Discord channels + external wiki sufficient) |

---

## 3. Auth & Permission Models — Data Model Details

### 3.1 Alliance Auth: State Machine + Groups

**Source:** https://allianceauth.readthedocs.io/en/latest/features/core/states.html, https://allianceauth.readthedocs.io/en/latest/features/core/groups.html

#### State Model (Priority-Based Assignment)

**Concept:** A `State` is a membership classification (Member, Blue, Guest). Users have exactly one active state, auto-computed from their main character's corp/alliance affiliation.

**Data Model (Django ORM):**

```
Table: core.State
  - id (PK)
  - name (str: "Member", "Blue", "Guest")
  - priority (int: 100, 50, 10) — higher = tested first
  - public (bool) — visible in UI

Table: core.StateAffiliation
  - id (PK)
  - state_id (FK) — which state
  - affiliation_type (enum: 'character', 'corporation', 'alliance', 'faction')
  - affiliation_id (int: EVE entity ID)
  
Example rows:
  StateAffiliation(state=Member, type=alliance, affiliation_id=123456789)
  StateAffiliation(state=Blue, type=alliance, affiliation_id=987654321)
  StateAffiliation(state=Guest, type=*, affiliation_id=NULL) — catch-all

Table: core.UserProfile (extends Django User)
  - user_id (FK to User)
  - main_character_id (FK to EVECharacter) — **primary character**
  - main_state_id (FK to State) — cached; re-computed on login
```

**Assignment Logic:**
1. User logs in with EVE OAuth2.
2. Character's corp/alliance fetched via ESI.
3. Loop states in priority order (Member: 100 → Blue: 50 → Guest: 10).
4. First state whose affiliations match user's character membership wins.
5. Store result in `UserProfile.main_state`; auto-update on login or corp change.

**Staleness:** Updated immediately on login; up to 15 minutes stale between logins if character is corp-kicked.

#### Groups Model (RBAC Overlay)

**Concept:** A `Group` is a collection of users. Groups are granted Django permissions and synced to Discord roles.

**Data Model:**

```
Table: auth.Group (Django default, extended)
  - id (PK)
  - name (str: "Directors", "Hunting Squad", etc.)
  - permissions (M2M to Permission) — standard Django perms
  - [CUSTOM] group_type (enum: 'open', 'closed', 'internal')
  - [CUSTOM] public (bool) — hidden groups not shown in UI

Table: auth.GroupRequest
  - id (PK)
  - group_id (FK)
  - user_id (FK)
  - request_date (datetime)
  - response (enum: None/'approved'/'rejected')
  - response_date (datetime)

Table: auth.User
  - groups (M2M to Group)
  - [CUSTOM] main_character (FK to EVECharacter)
  - [CUSTOM] main_state (FK to State)

Table: core.AutoGroup
  - id (PK)
  - corp_id (int: EVE corp ID)
  - alliance_id (int: EVE alliance ID)
  - corp_group_name_prefix (str: "Corp ") — group name = "Corp " + corp_name
  - alliance_group_name_prefix (str: "Alliance ")
```

**Auto-Group Sync Logic:**
- When `User.main_state` changes, or on a scheduled job (e.g., hourly):
  - Query ESI affiliation of user's main character.
  - Get configured AutoGroup entries.
  - Create group "Corp MyCorpName" if not exists.
  - Add user to that group; remove from previous corp group.

**Group Request Workflow:**
1. Non-member user clicks "Request Group".
2. If group is "open", auto-approve; if "closed", send to group leader/HR review.
3. Leader approves/rejects in UI → group membership changes → Discord role synced.

---

### 3.2 SeAT: Role-Based Access Control (RBAC)

**Source:** https://seat-docs.readthedocs.io/en/latest/admin_guides/rbac/, https://eveseat.github.io/docs/admin_guides/authorizations/

**Concept:** A `Role` is a set of `Permission`s. A `Permission` is a resource action (e.g., "view corporation wallet"). Roles are tied to EVE entities via `Affiliation` (corp/char ID).

**Data Model (Laravel/MySQL):**

```
Table: seat_web.roles
  - id (PK)
  - name (str: "Admin", "Director", "Recruiter")
  - description (text)

Table: seat_web.permissions
  - id (PK)
  - permission (str: "corporation.wallet_journal", "character.skills")
  - title (str: "View Corp Wallet Journal")

Table: seat_web.role_permissions (pivot)
  - role_id (FK)
  - permission_id (FK)

Table: seat_web.role_users (pivot)
  - role_id (FK)
  - user_id (FK) — SeAT user account

Table: seat_web.role_affiliations (pivot)
  - role_id (FK)
  - affiliation (int: EVE corp/char ID)
  - affiliation_type (enum: 'corporation', 'character')

Example rows:
  role_permissions: (director_role, corporation.wallet_journal)
  role_affiliations: (director_role, affiliation=98765432, type='corporation')
  → Director role applies only to corp 98765432; in SeAT 3 = no scope; in SeAT 4 = global if NULL
```

**Permission Evaluation:**
- User has role if `role_users` entry exists + role's affiliations match user's corp/char.
- **SeAT 3:** Empty affiliation = no scope (role never applies).
- **SeAT 4:** Empty affiliation = global scope (role applies to all entities).
- Default rule: **DENY** (user without permission → forbidden).

**Distinction from Alliance Auth:**
- SeAT roles are **manually assigned** by admins; no auto-sync from corp membership.
- Alliance Auth groups **auto-sync** corp/alliance membership (via State).
- SeAT scope is **narrower**: permission to specific resource (view wallet, see member).
- Alliance Auth scope is **broader**: group → Discord role → service access.

---

### 3.3 Comparison: Data Model Implications

| Aspect | Alliance Auth | SeAT | This Codebase (Planned) |
|---|---|---|---|
| **Membership origin** | ESI affiliation (corp/alliance), auto-synced on login | Manual user-role grant; no ESI loop | ESI affiliation (Character table) + manual app-role assignment (CorpRoleAssignment) |
| **Role scope** | Group → many services (Discord, Mumble, etc.) | Permission → specific resource view (fine-grained) | Corporation + app-role (director, recruiter, fc, member) — separate from map ACLs |
| **Permission model** | Django permission (coarse; service-level) | LaravelACL (fine-grained; resource action-level) | Ash policy (resource + field-level; see corp-suite-plan.md §3) |
| **Staleness window** | 15 min (state re-eval on login) | Static until manually edited | 15 min cache on ESI director-role check; app-role assignment is live |
| **Revocation trigger** | Corp kick → auto-expire state on next login | Manual admin unassign | ESI 403 on role-gated call (CCP enforces role at call time) |
| **Source of truth** | EVE ESI + optional local override | Local DB only | ESI for director; local DB for recruiter/fc/member |

---

## 4. Discord Integration Mechanics

**Source:** https://allianceauth.readthedocs.io/en/latest/features/services/discord.html, https://developers.discord.com/docs/topics/oauth2

### 4.1 Alliance Auth Discord Service

**OAuth2 Flow (User perspective):**

1. User clicks "Enable Discord" in Alliance Auth UI.
2. Redirect to Discord OAuth authorize endpoint:
   ```
   GET https://discord.com/api/oauth2/authorize
     ?client_id={DISCORD_APP_ID}
     &scope=identify%20guilds.join
     &response_type=code
     &redirect_uri={AA_CALLBACK_URL}
   ```
   Scopes: `identify` (read user ID/email) + `guilds.join` (bot can add user to guild).
3. User consents on Discord.
4. Discord redirects to AA callback: `GET {AA_CALLBACK_URL}?code={CODE}&state={STATE}`.
5. AA backend exchanges code for token:
   ```
   POST https://discord.com/api/oauth2/token
     client_id={DISCORD_APP_ID}
     client_secret={DISCORD_APP_SECRET}
     code={CODE}
     redirect_uri={AA_CALLBACK_URL}
   ```
6. AA stores `access_token` (short-lived, ~7 days) + `refresh_token` for user.
7. AA bot adds user to guild via `PUT /guilds/{GUILD_ID}/members/{USER_ID}` (requires bot token).
8. AA bot syncs user's Discord roles based on user's `State` + `Groups`:
   - Fetch user's State + Groups from DB.
   - For each Group, find corresponding Discord role (by name match or role ID map).
   - Call `PUT /guilds/{GUILD_ID}/members/{USER_ID}/roles/{ROLE_ID}` to grant/revoke.

**Role Sync Details:**

```
Example: User promoted from Guest → Member state

Before: Discord roles = [@everyone]
After:  Discord roles = [@everyone, @Member]

Sync algorithm (per login or on-demand):
  1. Query user.main_state (Member)
  2. Query user.groups (e.g., [Isk Farmers, Hunting Squad])
  3. Build expected_roles = {
       role for Group in user.groups: find_discord_role(group.name)
     } + {role for State: find_discord_role(state.name)}
  4. Query current_roles = /guilds/{id}/members/{user_id}
  5. For role in expected_roles: grant if missing
  6. For role in current_roles: revoke if not in expected
```

**Rate Limits & Caching:**

- Discord API: 50 reqs/second per bot token (429 Retry-After respected).
- AA caches role sync results; re-runs on login or via admin command.
- State changes (corp kick → Guest) trigger immediate Discord kick if configured.

### 4.2 SeAT Discord Service

SeAT has a simpler model:

- **No OAuth2**: SeAT does not request user's Discord permission.
- **Bot-only**: SeAT bot is given a token by admin; bot manages roles directly.
- **No refresh**: SeAT does not need to store user Discord tokens.
- **Role mapping**: Similar to AA—role name in SeAT matches Discord role name; bot adds/removes roles.
- **Disadvantage**: No `identify` scope means bot cannot verify user's Discord account is linked; must use EVE char name → Discord nick match (fragile).

---

## 5. Complete ESI Scope Catalogue

**Source:** https://esi.evetech.net/ui/, https://developers.eveonline.com/docs, https://docs.esi.evetech.net

**Table key:**
- `?` = could not confirm from available sources.
- **ETag** = endpoint supports `If-None-Match` conditional requests (304 Not Modified).
- **Cache** = documented Cache-Control TTL (else ESI's default is used).
- **CEO-only** = no director bypass; character must be CEO.
- **Error Limit** = 100 non-2xx responses / minute → 420 responses.
- **Data volume risk:** Low = <1KB/call; Medium = 1–100KB; High = 100KB+.

### 5.1 Character Endpoints (Member or Character-Scoped)

| Scope String | ESI Path(s) | Unlocks | Token Holder | Feature Use | ETag | Cache | Data Vol | Notes |
|---|---|---|---|---|---|---|---|---|
| `esi-characters.read_public_data.v1` | `/characters/{id}/` | Public char info: name, corp, alliance, birthday, gender | Any member (public data) | Affiliation verification, roster display | ✓ | 3600s | Low | Most basic scope; needed for any integration |
| `esi-location.read_location.v1` | `/characters/{id}/location/` | Current system & station/structure ID | Member (own char only) | Real-time location tracking (map overlay) | ✓ | 1h | Low | Already in wanderer default tier |
| `esi-location.read_ship_type.v1` | `/characters/{id}/ship/` | Current ship type_id, name | Member | Ship tracking in HUD | ✓ | 1h | Low | Already in wanderer default tier |
| `esi-location.read_online.v1` | `/characters/{id}/online/` | Online/offline status, last login time | Member | Last-seen for activity reports | ✓ | 1h | Low | Most valuable for member tracking (per-char) |
| `esi-ui.write_waypoint.v1` | `/ui/autopilot/waypoint` (POST) | Set autopilot destination | Member | Travel automation (niche) | ✗ | (write endpoint) | Low | Already in wanderer default tier |
| `esi-search.search_structures.v1` | `/characters/{id}/search/` | Search for structures by name (player-accessible stations) | Member | Autocomplete in UI | ✓ | 1h | Low | Already in wanderer default tier |
| `esi-wallet.read_character_wallet.v1` | `/characters/{id}/wallet/` | Character ISK balance | Member | Balance display | ✓ | 1h | Low | Already in wanderer wallet tier |
| `esi-wallet.read_character_wallet.v1` (cont.) | `/characters/{id}/wallet/journal/` | Wallet transaction history | Member | Personal wallet tracking | ✓ | 1h | Medium | Per-character only; useful for audit |
| `esi-characters.read_contacts.v1` | `/characters/{id}/contacts/` | Character's personal contacts (standings) | Member | Standings tracking | ✓ | 3600s | Medium | Can contain 1000+ contacts |
| `esi-characters.read_standings.v1` | `/characters/{id}/standings/` | Faction/corp standings | Member | Standings for access gates | ✓ | 3600s | Low | Useful for CONCORD status |
| `esi-characters.read_notifications.v1` | `/characters/{id}/notifications/` | Notifications (attacks, war decls, etc.) | Member | Event ingestion (noisy) | ✗ | 600s | Medium | CCP endpoint is best-effort; zKB is better for kills |
| `esi-characters.read_corporation_roles.v1` | `/characters/{id}/roles/` | Director/Accountant/etc role string | Member (but must hold role in corp) | Director verification at login | ✓ | Variable? | Low | **CEO-only bypass** if needed; always checked by ESI at call time |
| `esi-skills.read_skills.v1` | `/characters/{id}/skills/` | Trained skills + levels | Member (opt-in only) | Doctrine compliance check | ✓ | 3600s | Medium | **Cannot compel members to grant**; must be opt-in |
| `esi-skills.read_skillqueue.v1` | `/characters/{id}/skillqueue/` | Skills being trained + completion time | Member (opt-in only) | ETA + queue planning | ✓ | 1h | Low | Opt-in only |
| `esi-clones.read_clones.v1` | `/characters/{id}/clones/` | Clone locations, active implants | Member | Medical clone tracking | ✓ | 1h | Low | Useful for logistics planning |
| `esi-clones.read_implants.v1` | `/characters/{id}/implants/` | Implants in active clone | Member | PvP risk assessment | ✓ | 1h | Low | Duped in `read_clones` mostly |
| `esi-assets.read_assets.v1` | `/characters/{id}/assets/` | Character's item locations (ships, mats, etc.) | Member | Asset tracking | ✓ | 3600s | High | Huge: 100+ items per char typical; paginated |
| `esi-contracts.read_character_contracts.v1` | `/characters/{id}/contracts/` | Personal contracts | Member | Contract ledger | ✓ | 1h | Medium | Useful for artifact tracking |
| `esi-industry.read_character_jobs.v1` | `/characters/{id}/industry/jobs/` | Industry jobs (manufacturing, copying) | Member | Job status tracking | ✓ | 600s | Low | Useful for industry-focused corps |
| `esi-industry.read_character_mining.v1` | `/characters/{id}/mining/` | Mining ledger (ore types, quantities, date) | Member | Mining audit trail | ✓ | 600s | Low | Used in buyback systems |
| `esi-fittings.read_fittings.v1` | `/characters/{id}/fittings/` | Character's saved fittings | Member | Doctrine validation | ✓ | 1h | Low | Can confirm fit is saved; cannot mandate compliance |
| `esi-killmails.read_killmails.v1` | `/characters/{id}/killmails/recent/` | Character's kills/losses | Member (only mails char was in) | Killmail aggregation | ✓ | 1h | Medium | ESI gives only participant kills; zKB is better for corp-wide |
| `esi-calendar.read_calendar_events.v1` | `/characters/{id}/calendar/` | Calendar events (fleet ops invites) | Member | Event discovery | ✓ | 1h | Low | Useful if corp uses ESI calendar (rare) |
| `esi-mail.read_mail.v1` | `/characters/{id}/mail/` | In-game mail headers | Member | Notification fallback | ✓ | 600s | Medium | Noisy; most ignore |
| `esi-planets.read_planets.v1` | `/characters/{id}/planets/` | PI installations, outputs | Member | PI auditing | ✓ | 1h | Low | Niche for PI-focused groups |
| `esi-loyalty.read_loyalty.v1` | `/characters/{id}/loyalty/` | LP balance by faction | Member | LP audit (rare) | ✓ | 3600s | Low | Useful for mission-running corps only |
| `esi-bookmarks.read_bookmarks.v1` | `/characters/{id}/bookmarks/` | Bookmarks | Member | Bookmark sync (niche) | ✓ | 3600s | Medium | Ultra-niche feature |

### 5.2 Corporation Endpoints (Director-Only Scopes)

| Scope String | ESI Path(s) | Unlocks | Token Holder | Feature Use | ETag | Cache | Data Vol | Role Gate | Notes |
|---|---|---|---|---|---|---|---|---|---|
| `esi-corporations.read_corporation_membership.v1` | `/corporations/{id}/members/` | Full member roster (character IDs) | Director | Complete member list (no activity data) | ✓ | 3600s | Medium | Director role | **Same data as member tracking but simpler**; used with titles endpoint |
| `esi-corporations.track_members.v1` | `/corporations/{id}/membertracking/` | **Full member roster + activity data** | Director | **Last login/logoff, location, ship** (most valuable single endpoint) | ✓ | 3600s | Medium | Director role | **Single call gives last-seen for entire roster without per-char tokens** |
| (cont.) | Response fields: `character_id`, `start_date`, `logon_date`, `logoff_date`, `location_id`, `ship_type_id`, `base_id` (IDs only; names require `POST /universe/names/`) | | | | | | | | See §6 below |
| `esi-corporations.read_titles.v1` | `/corporations/{id}/titles/` | Corp titles + assigned members | Director | Organizational structure, role assignments | ✓ | 3600s | Low | Director role | Works with `/members/` to show who holds what title |
| `esi-corporations.read_structures.v1` | `/corporations/{id}/structures/` | **Corp-owned structures** (Upwell, starbases, Customs) | Director | Structure list, fuel, vulnerability windows | ✓ | 3600s | Low | Director role | **CEO-only for certain POS data** (fuel in old starbases) — check response |
| `esi-wallet.read_corporation_wallets.v1` | `/corporations/{id}/wallets/` | List of wallet divisions | Director | Wallet roster | ✓ | 3600s | Low | Director + Accountant roles | Already implemented in wanderer |
| (cont.) | `/corporations/{id}/wallets/{division}/journal/` | Wallet transaction history | Director | **Corporate ISK movements** (most complete audit trail) | ✓ | 3600s | High | Accountant role | Paginated; can be 10k+ rows/month; **requires ETag polling** to stay under rate limits |
| (cont.) | `/corporations/{id}/wallets/{division}/transactions/` | Wallet transactions (atomic buys/sells) | Director | Item buy/sell audit | ✓ | 3600s | High | Accountant role | Similar to journal but more granular; also large volume |
| `esi-assets.read_corporation_assets.v1` | `/corporations/{id}/assets/` | **Corp asset list** (ships, modules, ore, etc.) | Director | Asset inventory, ship doctrine compliance | ✓ | 3600s | **Very High** | Director role | **Biggest challenge**: no delta endpoint; full re-page every call; can be 10k–100k+ rows for industrious corps; **no cursor pagination yet** |
| (cont.) | `/corporations/{id}/assets/locations/` | Asset location names (coords for bookmarks) | Director | Asset search UI | ✓ | 3600s | High | (same) | Separate call; also needs pagination |
| `esi-contracts.read_corporation_contracts.v1` | `/corporations/{id}/contracts/` | Corp contracts (buy/sell/courier) | Director | Contract ledger, auction audit | ✓ | 1h | Medium | (?) | Paginated; useful for trade auditing |
| (cont.) | `/corporations/{id}/contracts/{id}/items/` | Items in a corp contract | Director | Item-level detail | ✓ | 1h | Medium | (?) | Separate paginated call per contract |
| `esi-industry.read_corporation_jobs.v1` | `/corporations/{id}/industry/jobs/` | Corp-wide industry jobs | Director | Manufacturing status | ✓ | 600s | Low | Director role | Useful if corp runs factories |
| `esi-industry.read_corporation_mining.v1` | `/corporations/{id}/mining/observers/` | **Corp mining ledger** (ore mined by all members) | Director | Mining audit + taxes | ✓ | 600s | High | Director + Station Manager roles | **Requires mining observer structure setup**; paginated; large for active mining corps |
| `esi-killmails.read_corporation_killmails.v1` | `/corporations/{id}/killmails/recent/` | Corp's kills/losses | Director | Loss audit (kills via zKB better) | ✓ | 1h | Medium | (?) | **Rarely used**; zKB WebSocket / RedisQ is better, real-time, all alliances |
| `esi-alliances.read_contacts.v1` | `/alliances/{id}/contacts/` | Alliance contacts (standings) | Director? | Alliance-wide standings | ✓ | 3600s | Medium | ? | **Not character-scoped; may be accessible to members?** Needs verification |
| `esi-corporations.read_blueprints.v1` | `/corporations/{id}/blueprints/` | Corp-owned BPOs (blueprints) | Director | BPO inventory, ME/TE levels | ✓ | 3600s | Medium | Director role | Useful if corp manages tech tree |
| `esi-corporations.read_shareholders.v1` | `/corporations/{id}/shareholders/` | Shareholders (ISK holders) | Director | Corporate structure (rare) | ✓ | 3600s | Low | CEO only | **CEO-only; not director-delegatable** |
| `esi-corporations.read_standings.v1` | `/corporations/{id}/standings/` | Corp standings vs entities | Director | Standings audit | ✓ | 3600s | Low | (?) | Corp-level diplomatic data |

### 5.3 Top 5 Highest-Value ESI Scopes (Small Alliance Priority)

For a ~100-character wormhole alliance focused on combat + ISK generation:

| Rank | Scope | Payload | Why |
|---|---|---|---|
| 1 | `esi-corporations.track_members.v1` | Medium | **Single call → entire roster + activity (login, location, ship); director-scoped; no per-char token loop** |
| 2 | `esi-wallet.read_corporation_wallets.v1` (journal) | High | Complete ISK audit trail; tax collection; already in wanderer |
| 3 | `esi-corporations.read_structures.v1` | Low | Owned structure status, fuel, timers; ops planning |
| 4 | `esi-location.read_online.v1` (per-char) | Low | Last login timestamp per member; roster health check |
| 5 | `esi-contracts.read_corporation_contracts.v1` | Medium | Trade audit, anti-theft, market ops |

---

## 6. Corp Member Tracking Specifics

**Source:** https://skoli.ru/en/apis/eve-online/corporations-corporation-id-membertracking, https://developers.eveonline.com/docs

### 6.1 The `GET /corporations/{corporation_id}/membertracking/` Endpoint

**Why this is the single most valuable director scope:**

Standard approach (naive): Poll `GET /characters/{id}/online/` for every member every 15 min → N tokens/calls, rate limit stress.

Better approach: One director's token on `GET /corporations/{id}/membertracking/` → one call, all members' data at once.

**Response Schema (Verified against https://skoli.ru/en/apis/eve-online/corporations-corporation-id-membertracking):**

ESI returns **IDs only, not names**. Names require separate resolution via `POST /universe/names/`.

```json
[
  {
    "character_id": 2112869217,
    "start_date": "2020-01-15T12:00:00Z",
    "logon_date": "2026-09-27T14:30:00Z",
    "logoff_date": "2026-09-27T08:00:00Z",
    "location_id": 60003068,
    "ship_type_id": 587,
    "base_id": 60003068
  },
  ...
]
```

**Field Definitions:**

| Field | Type | Meaning | Notes |
|---|---|---|---|
| `character_id` | int | EVE character ID | Static; use for lookups |
| `start_date` | ISO8601 | Corp join date | Static unless corp re-joined |
| `logon_date` | ISO8601 timestamp | **Last login time** | Updates every login |
| `logoff_date` | ISO8601 timestamp | **Last logout time** | NULL if char currently online; updates on logoff |
| `location_id` | int | ESI location ID (station/system/structure) | Updates on movement + login; IDs only (e.g., 60003068 = Jita IV-4); **requires name resolution** |
| `ship_type_id` | int | ESI item type ID of current ship | Updates on undocking (e.g., 587 = Rifter); IDs only; **requires name resolution** |
| `base_id` | int | ? | Unclear; appears to duplicate `location_id` sometimes |

**Name Resolution (Required for UI):**

ESI does **not** return `character_name`, `location_name`, or `ship_name`. To display names:

1. Collect all `character_id`, `location_id`, `ship_type_id` values from membertracking response.
2. Call `POST /universe/names/` with batch of IDs:
   ```
   POST /universe/names/
   Body: [2112869217, 60003068, 587]
   Response: [
     {"id": 2112869217, "name": "Kaffeine"},
     {"id": 60003068, "name": "Jita IV-4"},
     {"id": 587, "name": "Rifter"}
   ]
   ```
3. **Wanderer advantage:** This repo already caches name lookups via `WandererApp.CachedInfo` (`lib/wanderer_app/cached_info.ex`). Reuse for membertracking display.

**API Specifics:**

- **Scope required:** `esi-corporations.track_members.v1`
- **Role gate:** Director role (verified at ESI call time; if character loses Director between token grant and call, ESI returns 403)
- **Pagination:** Offset-based (x-pages header); for 100 members expect 1–2 pages at 100 rows/page
- **Cache:** CCP caches for 3600s (response has `Cache-Control: max-age=3600`)
- **ETag:** ✓ Supported (RFC7232 compliant); 304 Not Modified responses do NOT count against error limit (critical optimization)
- **Rate limit:** Standard ESI error limit (100 non-2xx/min → 420) applies; but 304s don't count

**Compared to Alternatives:**

| Method | Cost | Completeness | Staleness | Notes |
|---|---|---|---|---|
| Poll per-character `online/` + `location/` + `ship/` for each member | 3N tokens/calls per poll (300 calls for 100 members every 15 min) | Yes: all data | 1h each, age varies | **Unsustainable; ruins rate limits** |
| Corp membertracking (single call) | 1 token/call per poll | Yes: all data | 1h (corp-wide; all synced) | **Best option; rate-limit friendly** |
| Query local DB of logins (manual audit) | 0 tokens | No: only members who logged into this app | Days–weeks | **Incomplete if app isn't mandatory** |

**Real-World Usage (100-char wormhole corp, with ETag support):**
- Polling every 4 hours → 6 calls/day.
- Typical response: 100 rows, ~4–5 KB JSON (compact ID list).
- Without ETag: 6 full responses/day = 24–30 KB/day.
- **With ETag:** 6 requests, ~5 are 304 Not Modified (no body) = 1 full response + 5 tiny 304 headers ≈ 4–5 KB/day (80% reduction).

---

## 7. What SeAT / Alliance Auth Get Wrong (or Do Badly)

| Shortcoming | System | Impact | Workaround / Why Wanderer Can Beat It |
|---|---|---|---|---|
| **No live map integration** | Both SeAT, AA | Corp activity is invisible to fleet navcomp; roster/structure/kills data siloed from spatial context | **Wanderer advantage:** Members see live locations + roster + activity on the same canvas; Tripwire-like killmail + activity overlay on map; auto-route calc to member locations |
| **Notification latency (ESI poll-based)** | SeAT SRP, AA notifications | ESI notifications polled every 60–300s; structure attack pings are 2–5 min late | zKB WebSocket is real-time (< 1s); build structure ping bot off event stream in app, not ESI polling |
| **Corp asset endpoint is huge, no delta** | Both (if they use it) | 10k–100k rows per call; no delta/ETag support (must re-page entire list every poll); forces 1–6h poll intervals to avoid rate limits | Wanderer can afford slower polls (hours); or use cursor pagination (new ESI feature, not yet on assets) |
| **Recruitment pipeline is heavyweight** | AA HRApplications, SeAT recruitment | Requires form/question setup, approval queue, link to Discord roles — overkill for small closed groups | Wanderer: simple form (no ESI binding) + admin approval; Discord pings |
| **Doctrine-fit compliance requires opt-in skills scope** | SeAT fitting | Can't compel members to share `esi-skills.read_skills.v1`; compliance is voluntary and partial | Accept opt-in for now; no blocker |
| **Group auto-sync is fragile (Lagged corp changes)** | AA auto-groups | Corp kick → Discord role revoke can lag 15 min (until next login or sync job); no immediate revocation | Wanderer: if needed, monitor ESI affiliation on login + webhook to Discord bot for immediate kick |
| **PHP/Django frameworks are legacy** | SeAT (PHP/Laravel), AA (Python/Django) | Tech debt; slow on-disk caching; migration burden when upgrading EVE item DB (Fuzzworks, datadump); community burnout | Elixir + Postgres: modern, functional, concurrent; trivial to parallelize ESI polling |
| **No first-class moon extraction tracking** | Both have modules, limited | Moon extraction data is sparse in ESI; manual timer creation; no unified buyback→extraction→tax flow | Wanderer: can integrate ESI moon observer + auto-timer + auto-assign moon extraction ISK to corp wallet |
| **SRP approval is manual queue** | AA, SeAT SRP | No automation of loss correlation (killmail ↔ claim); no wallet integration for payouts | Wanderer: auto-correlate zKB killmail hash with SRP claim; link to corp wallet journal for transparency |
| **Discord webhooks are one-way, no reaction roles** | Both (unless aa-discordbot) | Can't use Discord as a command interface (react to approve SRP, assign fleets, etc.) | Wanderer: embed Discord webhook sink; event-driven reactions (role sync, SRP approval ping, fleet signup via reaction) in roadmap |
| **Multi-tenant overhead** | AA, SeAT | Both designed for hosters; configs leaked across instances if not careful; unnecessary for single-corp fork | Wanderer: single corp, no multi-tenant auth layer; simpler, safer |

**Bottom line:** SeAT/AA are platforms; Wanderer is a mapping tool extended into corp suite. Wanderer can beat them on **context** (all data on the map), **latency** (zKB + live events), and **simplicity** (single-use case, no plugin ecosystem bloat).

---

## 8. Data Volume Reality Check (~100 Characters, 1 Wormhole Alliance)

**Assumptions:**
- 100 active characters (60–70 alts, 30–40 mains; ~50 unique players).
- Moderate PvE (mining, ratting), some PvP (kill/loss ~2–5 per day alliance-wide).
- 2–3 fleet ops per week (50–100 kills/losses per month).
- 3–5 corp structures (Upwell stations, maybe a POS or two).
- Casual wallet activity (tax daily, major buyback/SRP weekly).

### 8.1 Row Count Estimates (Monthly Growth)

| Table / Feature | Est. Monthly Rows Created | Cumulative After 12 Months | Notes | Retention Window | ETag Needed? |
|---|---|---|---|---|---|
| **Corp wallet journal** (taxing, buyback, SRP) | 1,200–2,000 | 15k–24k | ~3–5 txns/day avg; spikes during buyback events | 180 days (6 months); archive older | Yes; ~1–2 rows/call without filtering |
| **Corp assets snapshot** (full re-page) | 5,000–15,000 | 60k–180k | ~150–500 unique items per snapshot; poll every 4h → ~180 snapshots/month | Snapshots only; purge after 90d; keep latest 1 snapshot | Yes; huge; no delta support yet |
| **Contracts (corp-wide)** | 50–200 | 600–2,400 | Buy/sell/courier mixed; most <1 week TTL | 90 days | Yes if polled; usually manual lookup |
| **Industry jobs** | 100–500 | 1,200–6,000 | Dependent on manufacturing activity; jobs complete in days | Job history: 90d; active only: live | No; low volume |
| **Mining ledger** (if mining observers exist) | 500–2,000 | 6k–24k | 1–10 ore types, hundreds of entries per day if active | 180 days | Yes; large if many miners |
| **Killmails (via zKB, not ESI)** | 60–150 | 720–1,800 | ~2–5 kills/losses per day alliance-wide; already in wanderer system | Archive: 365d; live cache: 7d | No; zKB handles caching |
| **Member tracking** (roster snapshot) | 100 (1 per member per poll) | 36,500 (daily polls) | 1 row per member per poll; not normally stored (queried live) | Live only; no history needed | Yes; most polls are 304 |
| **Skills** (per-character, optional opt-in) | 20–50 per char × opt-in % | 240–600 (assume 25% opt-in) | Skill list is large (255+ skills/char); rarely changes | Latest only; no history | Yes; very few changes |
| **Structures (owned)** | 3–5 per corp (static) | 3–5 | Metadata only; fuel/timers queried live | Live lookup; no history | No; tiny payload |

### 8.2 Estimated Database Size Growth

```
Month 1:  100 corp wallet rows + 150 contracts + 500 mining rows
          = 750 rows base + overhead → ~5 MB (indexes, PKs)

Month 6:  4,500 wallet + 900 contracts + 3,000 mining
          = 8,400 rows → ~30 MB

Month 12: 9,000 wallet + 1,800 contracts + 6,000 mining + 5k asset snapshots + 60k member tracking
          = 82,800 rows (with member tracking) → ~150–200 MB

With 12–24 months:
          If keeping full member tracking history: 300k–600k rows → 500 MB–1 GB

If purging member tracking live (no history), only asset snapshots + journal:
          ~150 MB at 24 months (sustainable on Hetzner EX44)
```

### 8.3 ESI Polling Cadence & Rate Limit Budget

**Standard approach:**

| Endpoint | Cadence | Calls/Month | Tokens/Call | Total Tokens/Month | Notes |
|---|---|---|---|---|---|
| Corp membertracking | 4 h | 180 | 1 | 180 | 1 page; 100 rows; ETag hits: ~170/180 calls (only 10–15 full fetches with ETag support) |
| Corp wallet journal | 1 h | 720 | 1–3 | 1,440–2,160 | Multi-page during buyback spike; with ETag: ~80% are 304 (reduced to 300–600 effective) |
| Corp structures | 15 min | 2,880 | 1 | 2,880 | Small payloads; low priority; could increase to 1 h safely |
| Corp contracts | 2 h | 360 | 1–2 | 360–720 | Less frequent than journal |
| **TOTAL (All enabled features)** | (mixed) | ~4,140 | (avg 1.2) | ~5,250–6,000 | With ETag (304 support): **effectively 1,500–2,500** (60% reduction) |

**ESI error limit:** 100 non-2xx/min across all tokens → 6,000/hour → 144k/day.
**Our usage:** 6,000/month ÷ 30 days ÷ 1,440 min = **0.14 requests/minute** → plenty of headroom (target <1 req/min).

### 8.4 Recommended Retention & Purge Strategy

**Implement:**

```sql
-- Corp wallet journal: keep 180 days, archive older
SELECT COUNT(*) FROM corp_wallet_transactions 
WHERE created_at < NOW() - INTERVAL '180 days';
-- → monthly DELETE or ARCHIVE to cold storage

-- Asset snapshots: keep latest 3 snapshots only, purge old
DELETE FROM corp_assets_snapshots 
WHERE asset_snapshot_id NOT IN (
  SELECT asset_snapshot_id FROM corp_assets_snapshots 
  ORDER BY snapshot_date DESC LIMIT 3
);

-- Mining ledger: keep 180 days (same as journal)

-- Member tracking: don't store history (query live); use 
-- WandererApp.Esi.get_corporation_member_tracking() as source of truth

-- Contracts: 90 days
```

---

## 9. Being the Auth of Record

**Once this app is the alliance's ONLY auth system, it must handle account lifecycle events no external system can delegate.**

**Source:** Alliance Auth implementation patterns (https://allianceauth.readthedocs.io), SeAT procedures (inferred from GitHub), EVE Online account/character rules (https://support.eveonline.com)

### 9.1 Main Character Linking & Alt Detection

**Why it matters:** State computation is **main-character-only**. If "main character" is wrong, corp membership is wrong.

**Alliance Auth approach:**
- On login, user presents one EVE character.
- That character is marked as the "main character" (FK: `UserProfile.main_character`).
- All other characters the user owns are "alts" (linked via `EVECharacter.user` FK; no special "alt" role).
- State is re-computed based on **main character's corp/alliance only** — alts' corp/alliance is ignored.
- User can manually request a "main character change" (rare); requires HR approval + state recalc.

**Data model implications:**
```
Table: core.UserProfile
  - user_id (FK to User, PK)
  - main_character_id (FK to EVECharacter)  ← **THIS determines state**

Table: esi_client.EVECharacter
  - id (PK)
  - character_id (int, unique)
  - character_name (str)
  - user_id (FK to User)  ← all chars owned by same user
  - is_main (bool, deprecated in favor of UserProfile.main_character_id)
  
Query main character:
  SELECT ec.* FROM esi_client.eve_character ec
  JOIN core.user_profile up ON ec.id = up.main_character_id
  WHERE ec.user_id = ?
```

**What happens if main character is lost:**
- Character deleted in EVE (rare; 30-day delete window, can restore).
- Character transferred to another account (player sells char; extremely rare, ~1/year in most alliances).
- Character biomassed (player quits; deleted permanently).

**This app must handle:**
1. **Detect** the main character is gone (on login, ESI `/characters/{id}/` returns 404 or character_id in SSO no longer matches stored ID).
2. **Cascade delete:**
   - Revoke user's groups (state = Guest).
   - Remove Discord roles (kick from all corp/membership roles).
   - Log the event (audit trail: "main character deleted"; timestamp; admin notified).
3. **Prompt user** to either:
   - Restore the character (within 30-day window via CCP support).
   - **Assign a new main character** (choose from remaining alts; re-compute state).
   - Deactivate account (leave corp; Guest state; lose all access).

**Implementation gaps vs AA/SeAT:**
- Neither has native "character deleted" detection (they poll affiliation on login; 404 is rare so goes unhandled).
- Both require manual admin intervention to re-assign mains.
- **This app should auto-detect + prompt user to choose alt as new main.**

### 9.2 Character Transfers (Player Sells Character)

**Scenario:** Member A sells their character to Member B. Character stays in same corp (buyer may be from another group or external). Account is transferred to new owner.

**What breaks:**
- Character is now in a different user's EVE account.
- On next SSO login, buyer's account owns that character.
- Seller's account still has stale reference to character (FK: `EVECharacter.user_id`).
- Character's tokens are invalidated by CCP (buyer must re-grant consent).
- State of seller's account is wrong (one fewer character; main character may have changed if seller only had 1).

**Alliance Auth approach:**
- Admin manually removes seller's character (DELETE from EVECharacter).
- Buyer logs in with new character (ESI SSO creates new EVECharacter row, linked to buyer's account).
- State auto-recalculates on both accounts.
- Tokens are refreshed by OAuth2 on next login.

**This app must do the same:**
1. **Detect** (on login, if character's EVE account is different from stored):
   - SSO returns `account_id` (deprecated but present in some older tokens; ESI `/verify/` also returns it).
   - If mismatch, character has been transferred.
2. **Remove** character from seller's account (log event; notify seller + admins).
3. **Create** character in buyer's account (if first login by buyer with that character).
4. **Revoke seller's tokens** (if seller was main: cascade delete alts? Or demote to Guest?).
5. **Re-grant buyer's tokens** (OAuth2 refresh flow).

**Gap vs AA/SeAT:**
- Neither checks `account_id` at login (it's not in the public scope; would require a custom token).
- Detection relies on manual admin report or slow ESI membership query showing character in wrong user's list.
- **This app can be more proactive if EVE account ID is captured** (requires separate SSO client with extended scope, or CCP to expose it publicly).

### 9.3 Account Recovery (Lost EVE Account / Password Reset)

**Scenario:** Member loses access to EVE account (forgot password, email compromised, 2FA lost).

**Where auth is tied to EVE account:**
- CCP's official "Account Recovery" https://support.eveonline.com/hc/en-us/articles/204217361 — password reset via email.
- If email is inaccessible: CCP support must verify identity (credit card, registration email, etc.).
- Account recovery can take 1–30 days.

**During this window:**
- Member cannot log into Wanderer (SSO link is dead; character is not accessible).
- Member's tokens are stale (refresh fails when EVE account is in recovery state).
- Corp needs to grant temporary access (e.g., Guest state, or manual admin unlock).

**Alliance Auth approach:**
- **No native recovery flow.** If user can't SSO, they can't access AA either.
- HR admin can manually deactivate / re-activate account (set `User.is_active=False/True`).
- On re-activation: next SSO login with **any character** on that EVE account succeeds; state recomputed.

**This app must:**
1. Provide admin UI to **deactivate account** (disable login, revoke Discord roles, log it).
2. On next login after recovery: **auto-reactivate** (re-restore previous state or prompt user).
3. **Audit log:** "Account recovery initiated 2026-09-27"; "State restored 2026-10-01".
4. **Notify:** User email + admin email on reactivation.

### 9.4 Rejoining Member (Left Corp, Returns)

**Scenario:** Member leaves corp (or is kicked). Later, re-joins the same or different corp in the alliance.

**What happens:**
- On login, ESI affiliation shows new corp.
- State is recalculated (Member if rejoined; Guest if in wrong corp).
- Groups are synced automatically (auto-groups drop old corp group, add new).
- Discord roles synced (old roles revoked, new granted).
- History of old account is **preserved** (login records, activity logs, etc. remain).

**Alliance Auth handles this natively:** State recalc at every login.

**This app must:**
1. **Keep historical record** of corp membership (don't delete `Character.corporation_id` on logout; store in a historical table if needed for audit).
2. **Re-grant access automatically** on re-join (state recalc).
3. **Avoid data duplication** (don't create new user rows; use existing `User`).

### 9.5 Audit Logging of Permission Grants

**Why:** "Who granted X permission to Y?" Must be traceable for compliance + dispute resolution.

**Alliance Auth doesn't have native audit logging** for group/state grants (it's part of Django's admin change log, but not user-facing).

**SeAT has basic role audit** (who assigned role to whom, timestamp) — unclear if exposed to users.

**This app must implement:**
```
Table: audit_logs_v1
  - id (PK)
  - actor_id (FK to User; who did it; NULL = system)
  - target_user_id (FK to User; who was affected)
  - action (enum: 'role_grant', 'role_revoke', 'state_change', 'group_add', 'group_remove', 'character_delete', 'account_recovery')
  - details (jsonb: {role: 'director', reason: 'opsec re-evaluation', ...})
  - timestamp (datetime)
  - ip_address (str; optional, for forensics)

Query: SELECT * FROM audit_logs_v1 WHERE target_user_id = ? ORDER BY timestamp DESC
  → Show user their own change history
Query: SELECT * FROM audit_logs_v1 WHERE actor_id = ? AND timestamp > NOW() - INTERVAL '30 days'
  → Show admin their recent actions (trend analysis, detect misuse)
```

### 9.6 GDPR / PII Deletion Requests

**Scenario:** Member requests "right to be forgotten" (GDPR Article 17) or simply wants account deleted.

**What must be deleted:**
- `User.email`, `User.first_name`, `User.last_name`.
- `UserProfile` row.
- `Character.name`, `Character.scopes` (encrypted tokens).
- `CorpRoleAssignment` rows (role grants).
- `AuditLog` rows mentioning this user (per GDPR, BUT may need to retain redacted rows for liability).
- Discord account link (if tracked separately).

**What must NOT be deleted** (per CCP's terms, AND to avoid financial fraud):
- Killmail references (historical record; deleting them would be fraud).
- Wallet transactions (if user was responsible for corp ISK; audit trail required).
- Structure timer edit history (opsec + liability).

**Alliance Auth approach:**
- aa-gdpr plugin provides framework (doesn't do it automatically).
- Admin must manually execute deletions + audit.

**This app must:**
1. Implement **cascading soft-delete** (mark `User.deleted_at`, don't hard-delete).
2. Scrub PII (anonymize name, email, IP address).
3. Keep audit log referencing the now-deleted user (sanitized; e.g., "User [DELETED] was kicked from Director role").
4. Workflow: User requests → Admin reviews → User confirms → deletion happens → log entry + user notified.

---

## 10. Notification and Ping Sources

**The single operational differentiator:** When a structure is under attack, a member's defense response time is **seconds**, not minutes. This is why notification delivery matters more than feature breadth.

**Source:** ESI `/characters/{id}/notifications/`, https://github.com/esi/eve-glue (canonical notification types), Alliance Auth aa-structures implementation, https://github.com/Redone0001/aa-structuretimers

### 10.1 Structure Attack Notifications

**ESI notification types relevant to structures:**

| Type ID | Type String | Event | Payload | **Critical?** |
|---|---|---|---|---|
| 181 | `StructureFuelAlert` | Structure fuel is low | ListOfTypesAndQty, SolarSystemID, StructureID, StructureTypeID | Medium (gives 1–24h warning) |
| 182 | `StructureAnchoring` | Structure is anchoring (deploying) | StructureTypeID, SolarSystemID, StructureID, TimeLeft | Low (informational) |
| 183 | `StructureUnanchoring` | Structure is unanchoring (removing) | StructureTypeID, SolarSystemID, StructureID, TimeLeft | Low (informational) |
| 184 | `StructureUnderAttack` | **Structure is being attacked** | **AllianceID, AllianceName, ArmorPercent, HullPercent, ShieldPercent, SolarSystemID, StructureID, StructureTypeID, TimeLeft** | **🔴 HIGH — requires immediate response** |
| 185 | `StructureOnline` | Structure came online | StructureID, SolarSystemID, StructureTypeID | Low |
| 186 | `StructureLostShields` | **Structure lost all shields** | **ArmorPercent, HullPercent, SolarSystemID, StructureID, StructureTypeID, TimeLeft** | **🔴 HIGH — armor timer active** |
| 187 | `StructureLostArmor` | **Structure lost all armor** | **HullPercent, SolarSystemID, StructureID, StructureTypeID, TimeLeft** | **🔴 CRITICAL — hull timer active** |
| 188 | `StructureDestroyed` | Structure is destroyed | SolarSystemID, StructureID, StructureTypeID | High (post-mortem; too late for defense) |
| 198 | `StructureServicesOffline` | Structure services went down | SolarSystemID, StructureID, StructureTypeID | Low |
| 199 | `StructureItemsDelivered` | Reinforcement items delivered | SolarSystemID, StructureID, StructureTypeID | Low |
| 204 | `MoonminingExtractionFinished` | **Moon extraction ready** | **AutoFractureTime, MoonID, OreVolumes (by type), SolarSystemID** | Medium (mining deadline) |
| (War-related) | `CorpWarDeclaredMsg` | **Corp is at war** | AgainstID (target corp), Cost (ISK), DeclaredByID (aggressor) | Medium (5-day notice; planning timer) |

**Data flow for structure attack:**

```
1. Attacker warps to structure at time T.
2. Structure takes damage; CCP detects (server-side).
3. Notification sent to corp's characters:
   → ESI `/characters/{char_id}/notifications/` includes new row:
      {
        type: 'StructureUnderAttack',
        timestamp: T+15s,
        text: '…shields: 95%…armor: 100%…',
        data: { StructureID: 1000000, SolarSystemID: 30002053, ... }
      }
4. Polling app sees notification (if checking within 15 min).
5. App sends Discord ping.
6. Member receives Discord notification (depends on Discord client settings).
7. Member responds / FCs prepare defense.

Latency breakdown:
  - ESI polling interval: 30–300s (app's choice)
  - ESI API latency: 100–500ms (CCP's network)
  - Discord webhook latency: 100–1000ms (Discord's network)
  - Member notification latency: instant–30s (depends on Discord app open, muted, etc.)
  - **TOTAL: 30s–5min** (Wanderer can do 30–60s if polling every 30s; AA typically 2–5 min)
```

**zKillboard is inadequate here:** zKB doesn't emit notifications until the kill is logged (after death), which is 5–30+ minutes after attack starts. **ESI is the only source.**

### 10.2 Polling Cadence vs Notification Staleness

**Trade-off: Freshness vs Rate Limits**

| Cadence | ESI Calls/Day | Alerts/Day (typical) | Staleness | Rate Limit Impact | Recommendation |
|---|---|---|---|---|---|
| Every 60s (aggressive) | 1,440 | All <2 min old | ~1 min | High; risky if 100 members polling | **No** — too many calls |
| Every 5 min (medium) | 288 | All <5 min old | ~2–3 min | Moderate; acceptable | **Recommended** (for defense-critical) |
| Every 15 min (lazy) | 96 | All <15 min old | ~8–10 min | Very low; negligible | **Acceptable** (for non-PvP corps) |
| Every 1 hour (very lazy) | 24 | All <1 hour old | ~30–40 min | Negligible | **Too slow** (almost useless for live events) |

**Whose token must be polled:**
- **Any corp director's token** will see corp-level notifications (structures, wars, etc.).
- **Each individual member's token** sees only their own notifications (skills trained, personal mail, etc. — **NOT useful for corp pings**).
- **Best practice:** Use one designated director's token to poll `GET /characters/{director_id}/notifications/`.
- **Fallback:** Poll all members' tokens, filter for structure notifications — expensive, redundant, rarely done.

### 10.3 Alliance Auth's aa-structures Approach

**Source:** https://aa-structures.readthedocs.io/, https://github.com/Redone0001/aa-structuretimers

**How aa-structures delivers structure pings:**

1. **Notification ingest:**
   - Scheduled job polls `/characters/{director_id}/notifications/` every 5 min (configurable).
   - Filter for `type in ['StructureUnderAttack', 'StructureLostShields', 'StructureLostArmor', 'StructureFuelAlert', 'StructureDestroyed']`.
   - For each match: parse `data.StructureID`, `data.TimeLeft` (TTL of timer).

2. **Timer auto-creation:**
   - Lookup structure in DB (corp-owned, manually seeded or synced from ESI).
   - Create or update Timer row:
     ```
     Table: structures.Timer
       - id
       - structure_id (FK)
       - structure_name (joined from Structure)
       - solar_system_id
       - timer_type (enum: 'low_fuel', 'shield_down', 'armor_down', 'hull')
       - date_added (when notification arrived)
       - date_triggered (when timer TTL expires)
       - status (enum: 'pending', 'active', 'completed', 'opsec_failed')
     ```

3. **Discord ping:**
   - Check timer's status + filter config (admin has set "ping on shield down", "don't ping fuel alerts after 22:00", etc.).
   - If match: send webhook to configured Discord channel:
     ```
     {
       "content": "@here — Structure under attack!",
       "embeds": [{
         "title": "Timer: Structure Name",
         "description": "Jita IV-4, Shield Down",
         "color": 15158332,
         "fields": [
           {"name": "Time Left", "value": "2 hours 30 minutes", "inline": false},
           {"name": "Attacker", "value": "None (ESI does not expose)", "inline": false}
         ],
         "timestamp": "2026-09-27T14:30:00Z"
       }]
     }
     ```

4. **Post-notification cleanup:**
   - Timer auto-transitions to "completed" when TTL expires.
   - zKB is monitored separately; if structure kill is logged → timer marked "destroyed".

**Limitations of aa-structures:**
- ESI does **not** expose attacker's ID or name in notifications (only timestamp + shield% — very limited).
- Relies on **manual structure registration** in aa-structures DB (ESI structure list is corp-owned-only; public structures are not queryable).
- **Fuel alerts are passive:** Only fires if corp has a director token and they're logged in during low-fuel window (fuel timer hidden unless polled).

### 10.4 Building Equivalent in Wanderer

**Advantages over aa-structures:**

1. **Already has ESI infrastructure** (client pools, rate-limit handling, token refresh).
2. **Already tracks structures in map** (`MapSystemStructure`; currently manual, could be auto-synced from ESI).
3. **Already has webhook dispatcher** (`external_events/webhook_dispatcher.ex`; can reuse for Discord pings).
4. **Already has zKB integration** (zKB kill data; can correlate with structure notifications for "structure killed" vs "structure survived").

**Minimal implementation sketch:**

```elixir
# File: lib/wanderer_app/corp/notifications_poller.ex
# Polls director's notifications; filters for structure/war events; sends Discord webhooks

defmodule WandererApp.Corp.NotificationsPoller do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(opts) do
    # Poll every 5 min (configurable via env)
    schedule_poll()
    {:ok, opts}
  end
  
  defp do_poll() do
    # 1. Fetch director's character (env var or DB lookup)
    director_char = get_director_character()
    
    # 2. Poll ESI /characters/{id}/notifications/
    notifications = WandererApp.Esi.get_character_notifications(director_char.eve_id, 
      access_token: director_char.access_token)
    
    # 3. Filter for structure/war types
    critical = Enum.filter(notifications, fn notif ->
      notif["type"] in ["StructureUnderAttack", "StructureLostShields", 
                        "StructureLostArmor", "StructureFuelAlert", 
                        "CorpWarDeclaredMsg"]
    end)
    
    # 4. For each critical notification:
    #    - Create/update Timer record
    #    - Send Discord webhook
    #    - Mark as processed (store notification_id to avoid re-pinging)
    Enum.each(critical, &process_notification/1)
  end
  
  defp process_notification(notif) do
    case notif["type"] do
      "StructureUnderAttack" ->
        notify_discord({:structure_attack, notif["data"]})
      "CorpWarDeclaredMsg" ->
        notify_discord({:war_declared, notif["data"]})
      _ -> :ok
    end
  end
  
  defp notify_discord({event_type, data}) do
    # Use webhook_dispatcher to post to Discord channel
    WandererApp.ExternalEvents.WebhookDispatcher.dispatch({
      event: event_type,
      data: data,
      timestamp: DateTime.utc_now()
    })
  end
  
  defp schedule_poll() do
    # Re-schedule every 5 min
    Process.send_after(self(), :poll, 5 * 60 * 1000)
  end
  
  def handle_info(:poll, state) do
    do_poll()
    schedule_poll()
    {:noreply, state}
  end
end
```

---

## Summary: Must-Have Capabilities (Revised for Single-Auth Decision)

### Tier 1 (MANDATORY — no external fallback exists)

1. **SSO + account creation** — EVE OAuth2 + token storage (already built; extend to director scope).
2. **Corp membership sync** — ESI affiliation poll + roster view (Character.corporation_id; UI needed).
3. **Discord integration** — bot role sync on state change (none exists; new).
4. **Structure notifications + pings** — ESI notification polling + Discord webhooks (none exists; new).
5. **Corp wallet visibility** — wallet journal read (already built; UI needed).
6. **Member activity tracking** — last login, location, ship (via membertracking endpoint; UI needed).
7. **State machine** — Member/Blue/Guest auto-assignment from corp/alliance (none exists; new).
8. **Account lifecycle management** — main character linking, character transfer detection, recovery, GDPR deletion (none exists; new).
9. **Audit logging** — who granted what permission to whom (none exists; new).

### Tier 2 (HIGH VALUE — if group uses them)

10. **Fleet scheduling + RSVP** — ops calendar with Discord announcement (if ops-driven group).
11. **SRP tracking & approval** — request/approval/payout workflow (if formalized SRP).
12. **Recruitment pipeline** — application forms + review (if recruiting).
13. **Corp structure sync + timers** — ESI polling + auto-timer creation (if PvP/PvE).
14. **FAT/participation tracking** — fleet attendance logging + stats (if CTA-based).
15. **Corp contracts view** — read-only ledger (if trading/market corp).
16. **Auto-group sync** — auto-create corp/alliance groups (if multi-corp alliance).

### Tier 3 (NICE-TO-HAVE or SKIP)

17. **Doctrine fitter** — skill compliance checker (low priority; external tools used; opt-in scopes only).
18. **Moon extraction tracking** — extraction status UI (if K-space moons relevant).
19. **Corp asset ledger** — snapshots + trending (heavy; defer or use slow polling).
20. **Standings audit** — contact-based diplomacy tracking (low priority; manual tracking sufficient).
21. **Industry/mining ledger** — job/ore tracking (if industrial focus; requires setup).
22. **Bulletin board** — corp wiki/articles (Discord channels + external wiki sufficient).
23. **Mumble/Teamspeak/SMF** — legacy service connectors (Discord replaces all; skip).

---

## Top 5 Highest-Value ESI Scopes (Final)

| Rank | Scope | Payload | Why |
|---|---|---|---|
| 1 | `esi-corporations.track_members.v1` | Medium | **Single call → entire roster + activity (login, location, ship); director-scoped; no per-char token loop** |
| 2 | `esi-wallet.read_corporation_wallets.v1` (journal) | High | Complete ISK audit trail; tax collection; already in wanderer |
| 3 | `esi-corporations.read_structures.v1` | Low | Owned structure status, fuel, timers; ops planning |
| 4 | `esi-location.read_online.v1` (per-char) | Low | Last login timestamp per member; roster health check |
| 5 | `esi-contracts.read_corporation_contracts.v1` | Medium | Trade audit, anti-theft, market ops |

---

## Scope Strings Verified

**Corrected in this revision:**
- ❌ `esi-structures.read_corporation_structures.v1` → ✓ **`esi-corporations.read_structures.v1`** (§5.3, §6 scope list)

**All other scope strings verified against https://esi.evetech.net/ui/ and confirmed correct:**
- ✓ `esi-corporations.track_members.v1`
- ✓ `esi-wallet.read_corporation_wallets.v1`
- ✓ `esi-contracts.read_corporation_contracts.v1`
- ✓ `esi-location.read_online.v1`
- ✓ `esi-characters.read_corporation_roles.v1`
- ✓ `esi-location.read_location.v1`
- ✓ `esi-location.read_ship_type.v1`
- ✓ `esi-characters.read_contacts.v1`
- ✓ `esi-assets.read_assets.v1`
- ✓ `esi-assets.read_corporation_assets.v1`
- ✓ `esi-wallet.read_character_wallet.v1`
- ✓ `esi-skills.read_skills.v1`
- ✓ `esi-industry.read_corporation_jobs.v1`
- ✓ `esi-industry.read_corporation_mining.v1`

**Membertracking endpoint fields verified** against https://skoli.ru/en/apis/eve-online/corporations-corporation-id-membertracking:
- ✓ `character_id`, `start_date`, `logon_date`, `logoff_date`, `location_id`, `ship_type_id`, `base_id` (IDs only, no names)
- ✓ ETag support confirmed (RFC7232 compliant; 304 Not Modified responses do NOT count vs error limit)
- ✗ **Removed** `character_name`, `location_name`, `ship_name` (ESI doesn't return these; requires separate `POST /universe/names/` call)

**Notification types verified** against https://github.com/esi/eve-glue/blob/master/eve_glue/notification_type.py:
- ✓ `StructureFuelAlert` (ID 181)
- ✓ `StructureAnchoring` (ID 182)
- ✓ `StructureUnanchoring` (ID 183)
- ✓ `StructureUnderAttack` (ID 184)
- ✓ `StructureOnline` (ID 185)
- ✓ `StructureLostShields` (ID 186)
- ✓ `StructureLostArmor` (ID 187)
- ✓ `StructureDestroyed` (ID 188)
- ✓ `StructureServicesOffline` (ID 198)
- ✓ `StructureItemsDelivered` (ID 199)
- ✓ `MoonminingExtractionFinished` (ID 204)
- ✓ `CorpWarDeclaredMsg` (war notification)

---

## Sources Cited (Final)

- SeAT: https://github.com/eveseat, https://eveseat.github.io/docs
- SeAT Plugins: https://github.com/eveseat-plugins
- Alliance Auth: https://allianceauth.readthedocs.io
- AA Structures: https://aa-structures.readthedocs.io
- AA FAT/AFAT: https://github.com/ppfeufer/allianceauth-afat
- AA Discord Service: https://allianceauth.readthedocs.io/en/latest/features/services/discord.html
- AA-GDPR: https://pypi.org/project/aa-gdpr/
- EVE ESI: https://esi.evetech.net/ui/, https://developers.eveonline.com/docs
- ESI Scopes & Notification Types: https://skoli.ru/en/apis/eve-online, https://github.com/esi/eve-glue
- ESI ETag Best Practices: https://developers.eveonline.com/blog/esi-etag-best-practices
- ESI Rate Limiting: https://developers.eveonline.com/docs/services/esi/rate-limiting/
- EVE Online Account Recovery: https://support.eveonline.com/hc/en-us/articles/204217361-Account-Recovery
- EVE Corporation Management FAQ: https://evemaps.dotlan.net/blog/corporation-management-tools-faq/
- Wanderer CachedInfo: `lib/wanderer_app/cached_info.ex` (repo-internal, for name resolution)

---

**Document ends.**  
**Next step:** Use this as reference input for expanding the corp-suite-plan.md phases; prioritize implementation order.
