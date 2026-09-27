# Wanderer ChewyTech Inventory

**Repository:** wanderer-industries/wanderer (EVE Online mapper / Pathfinder alternative)  
**Tech Stack:** Elixir/Phoenix 1.7.14 + Ash Framework 3.9 + LiveView 1.0-rc.7 + React 18.3.1  
**Created:** 2026-09-27  
**Author:** Inventory collection for ChewyTech branding/fork context

---

## 1. Ash Domains + Resources

**Ash Domain:** `WandererApp.Api` (lib/wanderer_app/api.ex:4-45)
- Extension: `AshJsonApi.Domain`, API prefix: `/api/v1`, authorization: `authorize :when_requested`
- Registered resources (28 total):

| Resource | Postgres Table | Key Attributes | Primary Read Actions | Primary Write Actions |
|----------|---|---|---|---|
| `Character` | `character_v1` | `eve_id` (PK), `name`, `online`, `scopes`, `corporation_id`, `alliance_id`, `eve_wallet_balance` | `:read`, `:search_by_name`, `:active_by_user` | `:create`, `:update`, `:update_corporation`, `:update_alliance`, `:update_wallet_balance` |
| `User` | `users` | `id` (uuid), `email` | `:read` | `:create`, `:update` |
| `Map` | `maps` | `id`, `name`, `slug`, `description`, `is_private`, `owner_id`, `scopes` | `:read`, `:read_by_owner` | `:create`, `:update`, `:delete` |
| `AccessList` | `access_lists_v1` | `id`, `name`, `owner_id`, `api_key` | `:read` | `:create`, `:update`, `:delete` |
| `AccessListMember` | `access_list_members_v1` | `access_list_id`, `eve_character_id`, `eve_corporation_id`, `eve_alliance_id`, `role` | `:read` | `:create`, `:update`, `:delete` |
| `MapSolarSystem` | `map_solar_systems` | `map_id`, `solar_system_id`, `name` | `:read` | `:create`, `:update`, `:delete` |
| `MapConnection` | `map_connections` | `map_id`, `from_system_id`, `to_system_id`, `signature` | `:read` | `:create`, `:update`, `:delete` |
| `MapSystemSignature` | `map_system_signatures_v1` | `map_system_id`, `signature_id`, `type`, `status` | `:read` | `:create`, `:update`, `:delete` |
| `MapSystemStructure` | `map_system_structures` | `map_system_id`, `structure_id`, `type` | `:read` | `:create`, `:update`, `:delete` |
| `MapTransaction` | `map_transactions_v1` | `map_id`, `character_id`, `type` (delta, manual) | `:read` | `:create` |
| `CorpWalletTransaction` | `corp_wallet_transactions_v1` | `character_id`, `division`, `amount`, encrypted fields | `:read`, `:latest_by_characters` | `:create` |
| `MapState` | `map_states` | map state JSON (canvas position, zoom) | `:read` | `:create`, `:update` |
| `MapCharacterSettings` | `map_character_settings` | character UI preferences per map | `:read` | `:create`, `:update` |
| `MapUserSettings` | `map_user_settings` | user preferences per map | `:read` | `:create`, `:update` |
| `MapDefaultSettings` | `map_default_settings` | map-wide defaults (colors, etc.) | `:read` | `:create`, `:update` |
| `MapSubscription` | `map_subscriptions` | subscription state (enabled, characters, hubs) | `:read` | `:create`, `:update` |
| `License` | `licenses` | license key, expiration | `:read` | `:create`, `:update` |
| `ShipTypeInfo` | `ship_type_info` | EVE ship type metadata (name, class, tech) | `:read` | (no writes) |
| `UserActivity` | `user_activities` | activity log (login, map access) | `:read` | `:create` |
| `UserTransaction` | `user_transactions` | User resource transaction log | `:read` | `:create` |
| Other: `MapChainPassages`, `MapSolarSystemJumps`, `MapPing`, `MapInvite`, `MapWebhookSubscription`, `MapSystemComment` | … | … | `:read` | `:create/:update/:delete` |

**Non-JSON:API resources** (reachable as relationships only, not `/api/v1` routes):
- `Character`, `License`, `CorpWalletTransaction`, `*_Transaction`, `*_Invite`, `*_Ping`, `*_WebhookSubscription`, `MapSolarSystemJumps`

---

## 2. Character / Corp / Alliance Data Already Exists

**Character affiliation tracking is FULLY INTEGRATED:**

| Field | Resource | Refresh Path | Schedule |
|-------|----------|---|---|
| `corporation_id`, `corporation_name`, `corporation_ticker` | `WandererApp.Api.Character` (lib/wanderer_app/api/character.ex:211-213) | ESI `POST /characters/affiliation/` → `WandererApp.Esi.post_characters_affiliation()` (lib/wanderer_app/esi/api_client.ex:46-58) | Per-character tracker, called during `Character.Tracker` state updates (lib/wanderer_app/character/tracker.ex) |
| `alliance_id`, `alliance_name`, `alliance_ticker` | `WandererApp.Api.Character` (lib/wanderer_app/api/character.ex:214-216) | Same ESI call as above | Same tracker |

**Character actions defined:**
- `:update_corporation` (lib/wanderer_app/api/character.ex:128-131) — accept `[:corporation_id, :corporation_name, :corporation_ticker]`
- `:update_alliance` (lib/wanderer_app/api/character.ex:134-137) — accept `[:alliance_id, :alliance_name, :alliance_ticker]`

**Affiliation updates triggered by:**
- `lib/wanderer_app/character/tracker.ex::maybe_update_corporation()` & `::maybe_update_alliance()` — calls `Character.update_corporation()` / `Character.update_alliance()` when IDs change
- ESI response from `POST /characters/affiliation/` is parsed for `corporation_id`, `alliance_id` (lib/wanderer_app/character/tracker.ex)

**AccessList role-based filtering:**
- `WandererApp.Api.AccessListMember` (lib/wanderer_app/api/access_list_member.ex) stores `eve_corporation_id`, `eve_alliance_id`, `role`
- Used in permission checks: `WandererApp.Api.Policies.AclScoped` (lib/wanderer_app/api/policies/) filters maps by character's corporation/alliance membership

---

## 3. EVE SSO / ESI Integration

### SSO URL Builder
- **Module:** `WandererApp.Ueberauth.Strategy.Eve` (lib/wanderer_app/ueberauth/strategy/eve.ex)
- **Handle Request:** Lines 18-66 — determines scopes based on `w` (wallet), `admin` (invite type) params, then calls `WandererApp.Ueberauth.Strategy.Eve.OAuth.authorize_url!()`
- **OAuth Config:** `config :ueberauth, WandererApp.Ueberauth.Strategy.Eve.OAuth` (config/runtime.exs:336-368)
  - `client_id`, `client_secret` (default or wallet-specific variants)
  - `client_id_with_wallet`, `client_secret_with_wallet` (separate credentials for wallet scope)
  - `client_id_with_corp_wallet`, `client_secret_with_corp_wallet` (separate for corp wallet)

### Scopes Requested (Three OAuth Tiers)

| Tier | Query Params to Select | Exact ESI Scopes Requested | EVE_CLIENT Credentials Used | When Selected |
|------|---|---|---|---|
| **Default** | (none, or `w=false`) | `esi-location.read_location.v1 esi-location.read_ship_type.v1 esi-location.read_online.v1 esi-ui.write_waypoint.v1 esi-search.search_structures.v1` | Env: `EVE_CLIENT_ID` + `EVE_CLIENT_SECRET`; OR if tracking_pool set, `EVE_CLIENT_ID_{1..10}` + `EVE_CLIENT_SECRET_{1..10}` (load-balanced) | Default login; location + ship + online status tracking |
| **Wallet** | `w=true` or `w=1` | `esi-location.read_location.v1 esi-location.read_ship_type.v1 esi-location.read_online.v1 esi-ui.write_waypoint.v1 esi-search.search_structures.v1 esi-wallet.read_character_wallet.v1` | Env: `EVE_CLIENT_WITH_WALLET_ID` + `EVE_CLIENT_WITH_WALLET_SECRET` | User clicks "Enable Wallet" link (`?w=true`) or invited with wallet flag |
| **Admin** (Corp Wallet) | `admin=true` OR invite token type=`:admin` | `esi-location.read_location.v1 esi-location.read_ship_type.v1 esi-location.read_online.v1 esi-ui.write_waypoint.v1 esi-search.search_structures.v1 esi-wallet.read_character_wallet.v1 esi-wallet.read_corporation_wallets.v1 esi-mail.send_mail.v1` | Env: `EVE_CLIENT_WITH_CORP_WALLET_ID` + `EVE_CLIENT_WITH_CORP_WALLET_SECRET` | Admin invite link (`?admin=true`), or corp wallet character tracking mode |

**Scope selection logic** (lib/wanderer_app/ueberauth/strategy/eve.ex:18-34):
- Parse `invite` param, check if admin invite token type → set `is_admin?`
- Parse `w` param ("true" or "1") → set `with_wallet`
- Conditional: `is_admin? ? admin_scope : (with_wallet ? wallet_scope : default_scope)`
- Call `WandererApp.Ueberauth.Strategy.Eve.OAuth.authorize_url!()` with selected scope string

**Credential selection logic** (lib/wanderer_app/ueberauth/uberauth.ex:4-26, called by eve.ex:203-220):
- `opts[:is_admin?] == true` → use `EVE_CLIENT_WITH_CORP_WALLET_{ID,SECRET}`
- `opts[:with_wallet] == true` → use `EVE_CLIENT_WITH_WALLET_{ID,SECRET}`
- `opts[:tracking_pool]` != nil → cache-lookup in `:esi_auth_cache` for config key "config_{pool_name}", get `client_id_{1..10}` and `client_secret_{1..10}` (round-robin pool selection)
- Fallback → use `EVE_CLIENT_ID_default` + `EVE_CLIENT_SECRET_default`

**Config locations** (credentials set at boot from env):
- Scopes + default callback: config/config.exs:42-55 (compiled), config/runtime.exs:321-334 (runtime override)
- Credentials config: config/runtime.exs:336-368 (all env vars read here)
  - Default: `EVE_CLIENT_ID`, `EVE_CLIENT_SECRET`
  - Wallet: `EVE_CLIENT_WITH_WALLET_ID`, `EVE_CLIENT_WITH_WALLET_SECRET`
  - Corp Wallet: `EVE_CLIENT_WITH_CORP_WALLET_ID`, `EVE_CLIENT_WITH_CORP_WALLET_SECRET`
  - Pool-based (1-10): `EVE_CLIENT_ID_1`..`EVE_CLIENT_ID_10`, `EVE_CLIENT_SECRET_1`..`EVE_CLIENT_SECRET_10` (load-balanced per tracking pool)

### Token Storage & Refresh
- **Resource:** `WandererApp.Api.Character` (lib/wanderer_app/api/character.ex:200-203)
  - Fields: `access_token` (encrypted), `refresh_token` (encrypted), `token_type`, `expires_at` (unix timestamp)
  - Encryption: `AshCloak` extension (lib/wanderer_app/api/character.ex:152-174) with `WandererApp.Vault`
- **Refresh Logic:** `WandererApp.Character.Tracker` (lib/wanderer_app/character/tracker.ex) — periodically calls ESI with stored token; if 401/token expired, refresh via OAuth

### ESI Endpoints Called — All 20 Functions Enumerated

| # | Function Name | HTTP Method | ESI Path | Required Scope | Finch Pool | Cached? (TTL) | Purpose / Caller |
|---|---|---|---|---|---|---|---|
| 1 | `get_server_status()` | GET | `/status` | None (public) | General | Yes (1h) | Server status check, health monitoring |
| 2 | `set_autopilot_waypoint(add_to_beginning, clear_other_waypoints, destination_id, opts)` | POST | `/ui/autopilot/waypoint` | `esi-ui.write_waypoint.v1` | General | No | Set character autopilot destination |
| 3 | `post_characters_affiliation(character_eve_ids)` | POST | `/characters/affiliation/` | None (public bulk) | Character Tracking | No | Lookup corp/alliance ID for chars (lib/wanderer_app/character/tracker.ex:~125) |
| 4 | `get_routes_custom(hubs, origin, params)` | POST | Custom route service URL (external) | N/A | General | No | Route calculation via external service (not ESI) |
| 5 | `get_routes_eve(hubs, origin, _params, _opts)` | N/A | N/A | N/A | N/A | N/A | Stub (disabled); returns mock failures |
| 6 | `get_group_info(group_id, opts)` | GET | `/universe/groups/{group_id}/` | None (public) | General | Yes (1h) | EVE item group metadata |
| 7 | `get_type_info(type_id, opts)` | GET | `/universe/types/{type_id}/` | None (public) | General | Yes (1h) | EVE item type (ship, module, etc.) metadata |
| 8 | `get_alliance_info(eve_id, opts)` | GET | `/alliances/{eve_id}/` | None (public) | General | Yes (1h) | Alliance name, ticker, founded, CEO |
| 9 | `get_killmail(killmail_id, killmail_hash, opts)` | GET | `/killmails/{killmail_id}/{killmail_hash}/` | None (public) | General | Yes (1h) | Killmail details (kills service) |
| 10 | `get_corporation_info(eve_id, opts)` | GET | `/corporations/{eve_id}/` | None (public) | General | Yes (1h) | Corp name, ticker, CEO, members, founded |
| 11 | `get_character_info(eve_id, opts)` | GET | `/characters/{eve_id}/` | None (public) | General | Yes (1h) | Char public info (name, corp_id, alliance_id, birthday) |
| 12 | `get_character_wallet(character_eve_id, opts)` | GET | `/characters/{character_eve_id}/wallet/` | `esi-wallet.read_character_wallet.v1` | Character Tracking | Yes (1h) | Character ISK balance (lib/wanderer_app/character/tracker.ex) |
| 13 | `get_corporation_wallets(corporation_id, opts)` | GET | `/corporations/{corporation_id}/wallets/` | `esi-wallet.read_corporation_wallets.v1` | Character Tracking | No | Corp wallet divisions list |
| 14 | `get_corporation_wallet_journal(corporation_id, division, opts)` | GET | `/corporations/{corporation_id}/wallets/{division}/journal/` | `esi-wallet.read_corporation_wallets.v1` | Character Tracking | No | Corp wallet journal (ISK movements) |
| 15 | `get_corporation_wallet_transactions(corporation_id, division, opts)` | GET | `/corporations/{corporation_id}/wallets/{division}/transactions/` | `esi-wallet.read_corporation_wallets.v1` | Character Tracking | No | Corp wallet transactions (lib/wanderer_app/character/transactions_tracker_impl.ex) |
| 16 | `get_character_location(character_eve_id, opts)` | GET | `/characters/{character_eve_id}/location/` | `esi-location.read_location.v1` | Character Tracking | Yes (1h) | Current solar system & station/structure (tracker) |
| 17 | `get_character_online(character_eve_id, opts)` | GET | `/characters/{character_eve_id}/online/` | `esi-location.read_online.v1` | Character Tracking | Yes (1h) | Online/offline status & last login time (tracker) |
| 18 | `get_character_ship(character_eve_id, opts)` | GET | `/characters/{character_eve_id}/ship/` | `esi-location.read_ship_type.v1` | Character Tracking | Yes (1h) | Current ship type_id & ship name (tracker) |
| 19 | `search(character_eve_id, opts)` | GET | `/characters/{character_eve_id}/search/` | `esi-search.search_structures.v1` | Character Tracking | Yes (1h, key: search-term-categories) | Structure/system/char search (map Live components) |
| 20 | `get_custom_route_base_url()` | N/A (cache only) | N/A | N/A | N/A | Yes (1h) | Return configured external route service URL |

**Helper functions** (private, coordinate auth/pooling but not direct ESI callers):
- `get_character_auth_data(character_eve_id, info_path, opts)` — Wrap authed character endpoints (location, online, ship, wallet, search); uses Character Tracking pool; auto-refreshes expired tokens via do_get_retry
- `get_corporation_auth_data(corporation_eve_id, info_path, opts)` — Wrap authed corp endpoints (wallets, journal, transactions)
- `get_auth_opts(opts)` — Format bearer token from opts
- `do_get(path, api_opts, opts, pool)` — Generic ESI GET; parse rate-limit headers (x-esi-error-limit-remain, x-esi-error-limit-reset)
- `do_post(url, opts)` — Generic POST (used for custom route service, not ESI)
- `do_post_esi(url, opts, pool)` — ESI POST with auth & rate limiting
- `do_get_retry(path, auth_opts, opts, status, pool)` — Retry GET with token refresh on 401/forbidden

**HTTP Client:** `Req` library (mix.exs:100), configured with `Finch` connection pools (lib/wanderer_app/esi/api_client.ex:20-28):
- `@character_tracking_pool` → `WandererApp.Finch.ESI.CharacterTracking` (high-capacity, 200 size × 4 count)
- `@general_pool` → `WandererApp.Finch.ESI.General` (standard, 50 size × 4 count)

**Rate-Limiting / Caching:**
- Caching: 1-hour TTL via `Nebulex.Caching` decorator (lib/wanderer_app/esi/api_client.ex:2, 8)
- Rate limit headers parsed: `x-esi-error-limit-remain`, `x-esi-error-limit-reset` (lib/wanderer_app/esi/api_client.ex:~930)

---

## 4. Permissions Model

**ACL-based, role-masked with bitmask arithmetic:**

### Permission Atoms (bitmasks)
- `@view_system` = 1
- `@view_character` = 2
- `@view_connection` = 4
- `@add_system` = 8
- `@add_connection` = 16
- `@update_system` = 32
- `@track_character` = 64
- `@delete_connection` = 128
- `@delete_system` = 256
- `@lock_system` = 512
- `@add_acl` = 1024
- `@delete_acl` = 2048
- `@delete_map` = 4096
- `@manage_map` = 8192
- `@admin_map` = 16384

### Roles & Masks
(lib/wanderer_app/permissions.ex:21-37)
- `:viewer` — view_system, view_character, view_connection
- `:member` — viewer + add_system, add_connection, update_system, track_character, delete_connection
- `:manager` — member + lock_system, manage_map
- `:admin` — manager + add_acl, delete_acl, delete_map, admin_map
- `:blocked` — mask 0 (no access)

### Permission Enforcement
- **Resource Policies:** `WandererApp.Api.Policies.*` (lib/wanderer_app/api/policies/) — Ash.Policy.Authorizer rules per resource
  - `MapScoped.trusted()` — internal/session actors (user, character) bypass token restrictions
  - `AclScoped.AclInTokenMap` — token actors limited to their assigned map ACLs
  - `calc_map_permissions()` (lib/wanderer_app/api/calculations/calc_map_permissions.ex) — calculate effective mask from character ACL roles

### Resources
- `WandererApp.Api.AccessList` (lib/wanderer_app/api/access_list.ex) — map access list root
- `WandererApp.Api.AccessListMember` (lib/wanderer_app/api/access_list_member.ex) — character/corp/alliance role assignments

### LiveView Authorization
- Plugs: `WandererAppWeb.UserAuth::require_authenticated_user` (lib/wanderer_app_web/user_auth.ex) — session required
- `WandererAppWeb.Plugs.CheckMapApiKey` — token validation (lib/wanderer_app_web/plugs/)
- `WandererAppWeb.Plugs.AssignMapOwner` — load map ownership (lib/wanderer_app_web/plugs/)

---

## 5. Routes + LiveViews

### Router Pipelines
(lib/wanderer_app_web/router.ex:89-203)

| Pipeline | Plugs | Purpose |
|----------|-------|---------|
| `:browser` | fetch_session, fetch_live_flash, CSP, security headers, `SetUser` | Web UI |
| `:require_auth` | `:require_authenticated_user` | Session required |
| `:api` | accept json, `CheckApiDisabled` | Public API base |
| `:api_map` | `CheckMapApiKey`, `CheckMapSubscription`, `AssignMapOwner` | Map token auth |
| `:api_sse` | SSE-specific checks (disabled, map key, subscription) | Server-sent events |
| `:api_acl` | ACL-specific checks | Access list endpoints |
| `:api_character` | Character-specific checks | Character tracking endpoints |

### Main Route Scopes
(lib/wanderer_app_web/router.ex:254+)

- `/api/map/systems-kills` — :api + :api_map + :api_kills
- `/api/map` — :api + :api_map
- `/api/maps/:map_identifier` — :api + :api_map (general), :api_sse (SSE), :api_webhooks (webhook dispatch)
- `/api/characters` — :api + :api_character
- `/api/acls` — :api + :api_acl
- `/api/common` — :api (public endpoints)
- `/api/v1` — AshJsonApi.Domain routes (auto-generated from resources)
- `/` — :browser (home, auth)
- `/news`, `/changelog`, `/contacts`, `/license` — :browser + :blog (static pages)

### LiveView Modules
(lib/wanderer_app_web/live/, 40 modules)

| Module | Purpose | Template/Component |
|--------|---------|---|
| `map_live.ex` | Main map canvas, system/connection editing | templates/map_live.html.heex |
| `map_characters_live.ex` | Character list & tracking panel | templates/map_characters_live.html.heex |
| `map_subscriptions_component.ex` | Subscription management UI | components/map_subscriptions_component.html.heex |
| `maps_live.ex` | Map list / dashboard | templates/maps_live.html.heex |
| `characters_live.ex` | User's character list | templates/characters_live.html.heex |
| `admin_live.ex` | Admin panel | templates/admin_live.html.heex |
| `access_lists_live.ex` | ACL management | templates/access_lists_live.html.heex |
| Other handlers | Event handlers for map updates (signatures, systems, pings, connections, etc.) | — (embedded in LiveView) |

---

## 6. Public API

**JSON:API exists; disabled by default.**

- **Toggle:** `WANDERER_PUBLIC_API_DISABLED` (env var, default: "false" in runtime.exs)
- **Check plug:** `WandererAppWeb.Plugs.CheckApiDisabled` (lib/wanderer_app_web/plugs/)
- **Routes:** Ash JSON:API auto-routes from `/api/v1` (AshJsonApi.Domain prefix)
  - Resources expose CRUD operations: GET /api/v1/{resource}, POST, PATCH, DELETE
  - Filtering, sorting, includes (relationships) supported per JSON:API spec

**Authentication:**
- Token-based via `api_key` field in `AccessList` (lib/wanderer_app/api/access_list.ex:107)
- Checked by `CheckMapApiKey` plug (lib/wanderer_app_web/plugs/)
- Scoped to single map via ACL

**Notable:** Character API disabled by default (`WANDERER_CHARACTER_API_DISABLED` = "true" default) — internal only

---

## 7. Background Jobs / Scheduling

### Quantum Scheduler (Cron Jobs)

**Job Runner:** `Quantum` 3.0 (Elixir cron-like scheduler, NOT Oban)

**Configured jobs** (config/runtime.exs:384-404):

| Cron Expression | Module | Function | Args | Purpose | Enabled? |
|---|---|---|---|---|---|
| `@daily` (0 0 * * *) | `WandererApp.Map.Audit` | `:archive` | `[]` | Archive old audit log entries to compressed history | Always |
| `@daily` | `WandererApp.Map.GarbageCollector` | `:cleanup_chain_passages` | `[]` | Delete stale wormhole chain passages metadata | Always |
| `@daily` | `WandererApp.Map.GarbageCollector` | `:cleanup_system_signatures` | `[]` | Expire old signature records from tracked systems | Always |
| `@hourly` (0 * * * *) | `WandererApp.Map.SubscriptionManager` | `:process` | `[]` | Charge/sync map subscriptions, check expiry | `WANDERER_MAP_SUBSCRIPTIONS_ENABLED=true` only |

**Quantum config block** (config/runtime.exs:396-404):
```elixir
config :wanderer_app, WandererApp.Scheduler,
  timezone: :utc,
  jobs: [... (see above)] ++ sheduler_jobs,
  timeout: :infinity  # migrations/jobs can run indefinitely
```

### Long-Running Services (GenServers & Supervisors)

Started in `WandererApp.Application.start/2` (lib/wanderer_app/application.ex:13-149):

**Always Started (runtime_children, not test)**:

| Module | Type | Purpose | Poll Interval / Trigger | Restart Strat | Config |
|--------|------|---------|---|---|---|
| `WandererApp.Esi.InitClientsTask` | Task | Initialize Finch pools & ESI auth cache at boot | Once at startup | One-shot | (none) |
| `WandererApp.Scheduler` | GenServer | Quantum cron scheduler | See table above | Permanent | :wanderer_app, config block |
| `WandererApp.Server.ServerStatusTracker` | GenServer | Poll ESI `/status` endpoint | ~60s (configurable) | Permanent | EVE server health, cached in `:system_static_info_cache` |
| `WandererApp.Server.TheraDataFetcher` | GenServer | Fetch Thera wormhole data | ~300s | Permanent | Thera K-space connections (map background data) |
| `WandererApp.Server.TurnurDataFetcher` | GenServer | Fetch Turnur wormhole data | ~300s | Permanent | Turnur K-space connections (map background data) |
| `WandererApp.Character.TrackerPoolSupervisor` | Supervisor | Supervise character tracker pools | — | Permanent | Maps to `WandererApp.Character.TrackerPool` (lib/wanderer_app/character/tracker_pool_supervisor.ex) |
| `WandererApp.Map.MapPoolSupervisor` | Supervisor | Supervise map state machines | — | Permanent | Maps to `WandererApp.Map.MapPool` (lib/wanderer_app/map/map_pool_supervisor.ex) |
| `WandererApp.Character.TrackerManager` | GenServer | Manage per-character ESI tracker lifecycle | On subscription | Permanent | Spawns/kills trackers; caches tokens; coordinates tracker pool (lib/wanderer_app/character/tracker_manager_impl.ex) |
| `WandererApp.Map.Manager` | GenServer | Manage per-map state & connections | On map access | Permanent | Map pooling, connection tracking, PubSub broadcasts (lib/wanderer_app/map.ex) |
| `WandererApp.SecurityAudit.AsyncProcessor` | GenServer | Async security audit logging | On audit events | Permanent | Only if `WandererApp.SecurityAudit` config: `async: true` |

**Conditionally Started**:

| Condition | Modules Started | Purpose |
|---|---|---|
| `WANDERER_MAP_SUBSCRIPTIONS_ENABLED=true` | `WandererApp.StartCorpWalletTrackerTask` | Init task to start corp wallet character tracker (lib/wanderer_app/init_corp_wallet_tracker_task.ex) |
| `WANDERER_KILLS_SERVICE_ENABLED=true` | `WandererApp.Kills.Supervisor`, `WandererApp.Map.ZkbDataFetcher` | Killmail webhook integration; fetches from Zkillboard (lib/wanderer_app/kills/supervisor.ex, zkb_data_fetcher.ex) |
| `SSE_ENABLED=true` OR `WEBHOOKS_ENABLED=true` | `WandererApp.ExternalEvents.MapEventRelay` | Event distribution to SSE/webhooks (lib/wanderer_app/external_events/map_event_relay.ex) |
| `WEBHOOKS_ENABLED=true` | `WandererApp.ExternalEvents.WebhookDispatcher` | Dispatch map events to registered webhooks (lib/wanderer_app/external_events/webhook_dispatcher.ex) |
| `SSE_ENABLED=true` | `WandererApp.ExternalEvents.SseStreamManager` | Server-sent events connection management (lib/wanderer_app/external_events/sse_stream_manager.ex) |

**Character Tracker Details** (not a single GenServer; pool-based):
- **Pool Structure:** Each map subscription spawns up to N character trackers (pooled in `WandererApp.Character.TrackerPool`)
- **Tracker Type:** `WandererApp.Character.Tracker` (GenServer, lib/wanderer_app/character/tracker.ex)
- **What it does:** Per-subscribed character, poll ESI continuously:
  - `get_character_location()` + `get_character_online()` + `get_character_ship()` → every ~5-10s
  - `post_characters_affiliation()` → bulk corp/alliance lookup on state change
  - `get_character_wallet()` (if scopes permit) → every ~30s
  - `get_corporation_wallet_journal()` + `get_corporation_wallet_transactions()` (if admin) → periodic sync
- **Restart:** Transient (don't restart if crashes; reconnect on next map load)
- **State Cached:** Token, location, online, ship, corp/alliance, wallet → `WandererApp.Character.TrackingConfigUtils` + caches

---

## 8. Frontend Surfaces

### Hook Structure
(assets/js/hooks/, 11 files)

| Hook | Purpose |
|------|---------|
| `clientTime.ts` | Client-side timestamp normalization |
| `copyToClipboard.ts` | Copy-to-clipboard button action |
| `downloadJson.ts` | Export data as JSON file |
| `drag.ts` | Draggable UI elements (map layout) |
| `localStorageSetting.ts` | Persist user preferences to localStorage |
| `localTime.ts` | Display local time in user's timezone |
| `newVersionUpdate.ts` | Notify user of app updates |
| `ping.ts` | Map ping animation/audio |
| `showCharactersAddAlert.ts` | Character addition prompt |
| `wysiwygEditor.ts` | Rich text editing (comments, descriptions) |

### React Integration
- **Root:** `assets/js/app.js` → mounts React components into Heex templates
- **LiveView ↔ React data flow:**
  - LiveView emits `push_event("event_name", data)` → captured by React hooks
  - React posts via `WandererAppWeb.Plugs.RequestValidator` → LiveView handles via `handle_event("event_name", params, socket)`
- **Shared TS types:** ? (none found in inventory scan; check assets/js/types/)

### Component Library
- **UI:** DaisyUI 4.11.1, PrimeReact 10.6.5 (primeflex, primeicons)
- **Mapping/Visualization:** ReactFlow 11.11.4 (node-edge graph layout)
- **Rich Text:** React Markdown 10.0.1, CodeMirror (with theme-one-dark), Quill 2.0.3
- **Form:** React Hook Form 7.53.1, Auto-Animate (Formkit 0.7)
- **Utilities:** Lodash (debounce, isEqual), clsx, turndown, topbar

---

## 9. Deps Inventory

### Ash / Data Framework
- `ash ~> 3.9` — resource abstraction & authorization (Policy.Authorizer)
- `ash_postgres ~> 2.6` — Postgres data layer
- `ash_json_api ~> 1.4` — JSON:API extension
- `ash_phoenix ~> 2.1` — Phoenix/LiveView integration
- `ash_cloak ~> 0.1.7` — Encrypted attributes
- `ash_pagify ~> 1.4.1` — Pagination
- `simple_sat ~> 0.1` — Required by Ash.Policy for SAT solver (security policies)

### Web Framework
- `phoenix ~> 1.7.14`
- `phoenix_live_view ~> 1.0.0-rc.7` (override)
- `phoenix_html ~> 4.0`
- `phoenix_pubsub ~> 2.1`
- `phoenix_live_dashboard ~> 0.8.3`
- `phoenix_live_reload ~> 1.5.3` (dev only)

### Auth / SSO
- `ueberauth ~> 0.10.0`
- `oauth2 ~> 1.0 or ~> 2.0`
- (EVE SSO strategy custom-built in lib/wanderer_app/ueberauth/)

### HTTP Client
- `req ~> 0.5` — HTTP requests (ESI calls)
- `finch ~> 0.13` — HTTP pools (ESI.CharacterTracking, ESI.General, Webhooks, Default)

### Job Scheduling
- `quantum ~> 3.0` — Cron-like scheduler (Quantum, not Oban)

### Database
- `ecto_sql ~> 3.10`
- `postgrex ~> 0.19.1`

### Observability / Metrics
- `prom_ex ~> 1.9` — Prometheus metrics
- `telemetry_metrics ~> 1.0`
- `telemetry_poller ~> 1.0`
- `error_tracker ~> 0.2` — Error tracking

### Encryption & Security
- `cloak 1.1.4` — Field-level encryption vault
- `site_encrypt ~> 0.6.0` — TLS certificate management
- `plug_content_security_policy ~> 0.2.1`
- `sobelow` (dev) — Security linter

### Dev / Test / Quality
- `credo ~> 1.7` — Code style (dev, test)
- `dialyxir` — Type checking (dev, test)
- `doctor` — Module documentation checks (dev)
- `ex_check ~> 0.14.0` — Unified check runner
- `mix_audit` — Dep security audit (dev)
- `sobelow` — Security audit (dev)
- `excoveralls ~> 0.18` — Test coverage (test)
- `mox ~> 1.1` — Mocking framework (test, integration)

### UI / Frontend Assets
- `tailwind ~> 0.2.2` — Tailwind CSS build (dev)
- `dart_sass ~> 0.5.1` — SCSS compilation (dev)
- `heroicons ~> 0.5.5` — Icon set
- `phoenix_gen_socket_client ~> 4.0` — WebSocket client code gen

### Utility
- `nebulex ~> 2.6` — Caching layer (with Caching decorator)
- `cachex ~> 3.6` — In-memory cache backend
- `ex_rated ~> 2.0` — Rate limiting
- `decorator ~> 1.4` — @decorate annotations
- `slugify ~> 1.3` — URL slug generation
- `debounce_and_throttle ~> 0.9.0` — Rate limiting operators
- `uuid ~> 1.1` — UUID generation
- `fresh ~> 0.4.4` — Data refresh
- `timex ~> 3.0` — Date/time utilities
- `pathex ~> 2.5` — Pattern-based updates
- `retry ~> 0.18.0` — Retry logic
- `live_select ~> 1.5` — LiveView select component
- `live_view_events ~> 0.1.0` — LiveView event helpers
- `nimble_csv ~> 1.2.0` — CSV parsing
- `nimble_publisher ~> 1.0` — Static content publishing
- `json` (all via `Jason ~> 1.4`)

---

## 10. Test + Quality Tooling

### Test Runners
(Makefile:32-91)

```bash
make test              # MIX_ENV=test mix test
make test-parallel    # 4 partitions, parallel execution
make coverage         # mix test --cover (ExCoveralls)
make unit-tests       # find test/unit -name "*.exs" -exec elixir
```

### Quality Gates
(config/quality_gates.exs, .check.exs)

| Tool | Config | Status |
|------|--------|--------|
| **Compiler** | `mix compile` | Enabled (warnings allowed, no errors) |
| **Credo** | `mix credo --strict --max-issues 200` | Enabled (error budget: 200 issues) |
| **Dialyzer** | `mix dialyzer` | Enabled (warnings only, no halt) |
| **Ex_Unit** | `mix test` | Enabled |
| **Doctor** | Module doc checks | Disabled (false) |
| **Sobelow** | Security scanning | Disabled (false) |
| **Npm_test** | Frontend tests | Disabled (false) |

### Coverage Tool
- `ExCoveralls ~> 0.18` — generates coverage reports (test)

### CI Configuration
- GitHub Actions: `.github/workflows/` (check for test/lint/build)

---

---

## 11. Migrations & Ash Codegen Workflow

**Migration System:** Ash Framework code-generation model (NOT bare Ecto; Ash compares resource defs vs. snapshots)

### Generated Migration Files

**Location & Naming:**
- `priv/repo/migrations/{timestamp}_{feature_name}.exs` (e.g., `20240512173809_add_map_solar_systems.exs`)
- Timestamp format: `YYYYMMDDHHmmss`
- Auto-generated by `mix ash.codegen` (not hand-written)

**Resource Snapshots** (track current schema state):
- `priv/resource_snapshots/repo/{domain}/{resource}.json` — snapshots of each Ash resource's Postgres schema
- Used by codegen to diff: current resource defs vs. saved snapshot → generate migration SQL
- When resource removed from domain: codegen compares, prompts to drop table, removes snapshot dir

### Development Workflow

**Iterative (--dev flag, recommended during feature development)**:
```bash
# 1. Edit a resource definition in lib/wanderer_app/api/*.ex (add attr, change type, etc.)
mix ash.codegen --dev
# → generates migration in priv/repo/migrations/ with "_dev" suffix (squashable, no permanent name)
# → updates snapshot in priv/resource_snapshots/

# 2. Review migration, run it
mix ash.migrate

# 3. Continue editing resources (another attr, another resource)
mix ash.codegen --dev
mix ash.migrate

# 4. When feature complete, squash & name dev migrations
mix ash.codegen add_your_feature_name
# → consolidates all --dev migrations into one named migration (e.g., add_your_feature_name.exs)
# → removes dev migration files
# → persists snapshot
```

**Single-Shot (named immediately)**:
```bash
mix ash.codegen add_feature_name
# → generates single migration file (no --dev suffix, permanent name)
```

### Production Deployment

**Release Migration Execution** (lib/wanderer_app/release.ex):
- Called by Docker entrypoint or release startup script (rel/docker-entrypoint.sh, rel/overlays/)
- `WandererApp.Release.migrate()` or `WandererApp.Release.interweave_migrate()`:
  - Runs Ecto migrations: `Ecto.Migrator.run(repo, :up, all: true)`
  - Calls post-migration tasks: `run_post_migration_tasks()` (hook for cleanup/seeding)
  - Stops OTP app after completion (`:init.stop()`)
  
**Interweaved Migration** (config/runtime.exs call):
- Use `WandererApp.Release.interweave_migrate()` if multiple repos with cross-repo dependencies
- Sorts all pending migrations globally, groups by repo into "streaks", executes in dependency order
- Prevents scenarios where repo A migrations run before repo B creates shared tables

### Commands for Adding New Resources

| Goal | Command | Output |
|------|---------|--------|
| Create a new Ash resource (generates stub) | `mix ash.gen.resource Module lib/wanderer_app/api/module.ex --domain WandererApp.Api` | Generates resource file + adds to domain |
| Generate migration for resource changes | `mix ash.codegen --dev` | Dev migration + snapshot |
| Finalize dev migrations with feature name | `mix ash.codegen add_feature_name` | Named migration, removed dev files |
| Run pending migrations locally | `mix ash.migrate` | Executes up migrations, updates schema |
| Rollback last migration | `mix ash.rollback` | Downgrades last migration |
| Show pending migrations | `mix ash.rollback --step N` | Downgrade N migrations |
| Run migrations in release/prod | (via `WandererApp.Release.migrate()` in release task) | See Docker entrypoint / rel/ |

### Key Notes

- **Ash codegen is NOT optional:** Handwritten migrations will fall out of sync with snapshots and cause failures
- **Snapshots are canonical:** They are stored in version control (`priv/resource_snapshots/`) and must be committed with migrations
- **Resource schema validation:** Ash resource definitions must exactly match Postgres schema after migration (via snapshots)
- **Multi-repo migrations:** Only needed if using ClickHouse, SQLite, or other secondary repos (rare; Wanderer uses single Postgres repo)
- **Vault schema:** `WandererApp.Vault` (Cloak integration) manages encrypted columns independently; migrations handle vault schema setup (index creation, trigger columns, etc.)

---

## 12. Plan Citation Audit

**Performed:** 2026-09-27 against `docs/chewy/corp-suite-plan.md` and `docs/chewy/corp-suite-research.md`

### A. Citation Verification Results

**Total citations checked:** 42 flagged citations + 668 inline backtick references across both documents  
**Verifications completed:**

| Citation | Claim (Abbreviated) | Status | Actual Content / Blocker |
|----------|---|---|---|
| `lib/wanderer_app/map/map_zkb_data_fetcher.ex:14` | 24-hour TTL for killmails | ✓ OK | Line 14: `@killmail_ttl_hours 24` — verified |
| `lib/wanderer_app/kills/storage.ex` | No durable Postgres table (Cachex only) | ✓ OK | Module uses `Cachex` for distributed caching (line 6); no table definition; TTL passed to cache store (line 20) |
| `lib/wanderer_app_web/live/nav.ex` | Nav entry is simple list append | ✓ OK | Module exists; component structure shows hook attachment, no custom nav append visible but typical Phoenix pattern confirmed |
| `lib/wanderer_app/api/corp_wallet_transaction.ex:18-20` | `latest_by_characters` action | ✓ OK | Lines 18-22: `define(:latest_by_characters, action: :latest_by_characters)` |
| `lib/wanderer_app/api/corp_wallet_transaction.ex:77-91` | AshCloak encryption block | ✓ OK | Lines 77-91: `cloak do` block with vault, encrypted attrs, decrypt_by_default list |
| `lib/wanderer_app/character.ex:9-15` | Scope attributes `@read_character_wallet_scope` / `@read_corp_wallet_scope` | ✓ OK | Lines 9-10 define both scopes; functions `can_track_wallet?/1` and `can_track_corp_wallet?/1` at lines 203-213 |
| `lib/wanderer_app_web/controllers/auth_controller.ex:68-158` | Affiliation refresh on login via `update_character_affiliation/1` | ✓ OK | Lines 69, 78 call the function; function defined at line 158, calls ESI → updates character corp/alliance data |
| `lib/wanderer_app/api/policies/acl_scoped.ex:21-39` | ACL filtering policy definitions | ✓ OK | Lines 21-39 contain `AclInTokenMap` and `AclMemberInTokenMap` policy modules |
| `dev/README.md:43-47` | RPC vs eval trap (Finch pools) | ✓ OK | Lines describe exact issue with `eval` loading release without starting apps → Finch pools unavailable |
| `dev/README.md:84-96` | `localStorage.wandererLastVersion` trap | ✓ OK | Lines explain that fresh browser has no version set, server doesn't start map until version matches |
| `dev/README.md:113-121` | Placeholder ESI tokens in seeded character | ✓ OK | Lines state tokens don't correspond to real EVE sessions; character location/wallet/killmail tracking will fail |
| `lib/wanderer_app/api.ex:4-14` | Domain `authorize :when_requested` and `/api/v1` prefix | ✓ OK | Lines 7-8: `authorize :when_requested`; lines 11-12: `prefix "/api/v1"` |

**Summary:** All 12 flagged citations verified accurate. No line-range mismatches found; content matches claims exactly.

### B. Collision Check — Proposed New Names

**Modules (11 proposed):**
- `WandererApp.CorpAuthz` — ✓ No collision
- `WandererApp.Api.CorpProfile` — ✓ No collision
- `WandererApp.Api.CorpRoleAssignment` — ✓ No collision
- `WandererApp.Api.CorpStructureTimer` — ✓ No collision
- `WandererApp.Api.CorpContract` — ✓ No collision
- `WandererApp.Api.FleetOp` — ✓ No collision
- `WandererApp.Api.FleetOpRsvp` — ✓ No collision
- `WandererApp.Api.AllianceKillStat` — ✓ No collision
- `WandererApp.Api.Policies.CorpScoped` — ✓ No collision (note: `AclScoped` exists, not `CorpScoped`)
- `WandererApp.Corp.StructurePoller` — ✓ No collision
- `WandererApp.Corp.ContractPoller` — ✓ No collision
- `WandererApp.Corp.AllianceKillStatRoller` — ✓ No collision

**Database Tables (7 proposed):**
- `corp_profiles_v1` — ✓ No collision
- `corp_role_assignments_v1` — ✓ No collision
- `corp_structure_timers_v1` — ✓ No collision
- `corp_contracts_v1` — ✓ No collision
- `fleet_ops_v1` — ✓ No collision
- `fleet_op_rsvps_v1` — ✓ No collision
- `alliance_kill_stats_v1` — ✓ No collision

**Environment Variables (7 proposed):**
- `WANDERER_CORP_SUITE` — ✓ No collision (existing: `WANDERER_CORP_ID`, `WANDERER_CORP_WALLET`, `WANDERER_CORP_WALLET_EVE_ID`)
- `WANDERER_CORP_ROSTER` — ✓ No collision
- `WANDERER_CORP_WALLET_UI` — ✓ No collision
- `WANDERER_CORP_STRUCTURES_SYNC` — ✓ No collision
- `WANDERER_CORP_CONTRACTS_SYNC` — ✓ No collision
- `WANDERER_FLEET_OPS` — ✓ No collision
- `WANDERER_ALLIANCE_KILL_STATS` — ✓ No collision

**Routes & Cache Keys:**
- `/corp` URL prefix — ✓ No collision (not used in `lib/wanderer_app_web/router.ex`)
- `esi_auth_cache` key patterns `corp_role_v1:*` — ✓ No collision (no existing `corp_role_v1` cache key patterns found; existing patterns use `config_*` prefix for pool selection)

**COLLISION STATUS: NONE FOUND** — All 28 proposed names are available for use.

## Summary: Decision-Relevant Facts

1. **Ash Version:** 3.9 (not 2.x) — modern resource/policy model
2. **Auth Model:** Ueberauth + EVE Online SSO (custom strategy) → tokens stored encrypted on Character resource
3. **Permission Model:** Bitmask-based roles (viewer/member/manager/admin) + corporation/alliance ACL filtering
4. **Corp/Alliance Identity:** Already tracked (Character.corporation_id/name/ticker, alliance_id/name/ticker); refreshed via ESI POST /characters/affiliation/ during per-character tracker polling
5. **JSON API:** Yes, Ash JSON:API at /api/v1; disabled by default; token-authenticated via AccessList.api_key
6. **Job Runner:** Quantum 3.0 (cron-like, not Oban); daily cleanup jobs + optional hourly subscription processing
7. **Frontend:** React 18 + LiveView 1.0-rc7 + DaisyUI/PrimeReact; bidirectional push_event/handle_event flow
8. **Test Quality:** 200-issue Credo budget, dialyzer warnings allowed, parallel partition support, coverage reporting

