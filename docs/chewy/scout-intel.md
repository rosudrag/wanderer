# Scout Intel Log

`WANDERER_SCOUT_INTEL`. A log of what scanner clients (eveknob) found while
scouting: special NPC spawns, and the state and reinforcement timers of
player-owned Upwell structures.

Two halves:

| | |
|---|---|
|**Ingest**|`POST /api/maps/:map_identifier/scout/spawns`, `POST .../scout/structures`. Bot auth, map API key.|
|**Read**|`/scout`, gated on the `:scout_intel_view` permission, which **only the bootstrap admin can grant** (`/scout/access`).|

`/scout` is a **top-level** route with its own sidebar icon, not a page
under `/corp`. It is not part of the corp suite: its permission is granted
by the instance owner rather than by a corp admin, so nesting it under the
corp management page would have made it reachable only by knowing the URL.

Not one of the phases in `corp-suite-plan.md`. Phase 6 ("Structure timers")
is ESI-synced data about structures *we own*; this is scouted observation of
structures we do not own, and it arrives from a game client, not from ESI.

## Why the routes hang off `/api/maps/:map_identifier`

The stored log is **not** map-scoped — it is fleet intel, queried globally,
and the authenticating map is recorded on each row only as provenance.

The route is map-scoped because `:api_map` is the pipeline that already
authenticates a bot with a map's `public_api_key`, which is the exact
credential eveknob already holds and already sends for
`POST /signatures/sync` (`obj_MapSync.iss` sets one `Authorization: Bearer`
header profile). A dedicated scout token would have to be minted, deployed
and rotated to buy nothing: any holder of a map API key on this deployment is
already trusted with map writes.

## Request shape

Both endpoints take `{"rows": [ ... ]}`, max 1000 rows per request. Each row
is one TSV line as an object. Responses:

```json
{"data": {"received": 12, "stored": 12, "failed": 0, "errors": []}}
```

`failed` is exact; `errors` is a sample of at most 20
`{"index": 0, "error": "missing or unparseable utc_timestamp"}` entries.
**One malformed row never rejects the batch** — a client tailing a file must
not lose 199 good lines to one bad one.

### Everything may be a string

LavishScript has no JSON types: `${Entity.IsStructureVulnerable}` stringifies
to `"TRUE"`, an absent field to `""`. Integers, floats, decimals and booleans
are all coerced from text, and an unparseable *optional* value becomes `null`
rather than failing the row. Only the required fields are strict.

### Idempotence is assumed, not exceptional

A client that restarts and re-posts the tail of its file must not duplicate
rows, so writes upsert on a natural identity:

|Resource|Identity|
|---|---|
|`ScoutSpawnSighting`|`character_name, observed_at, solar_system_id, location_name, spawn_name`|
|`ScoutStructureSighting`|`structure_id, observed_at, event`|

Every column in those identities is `NOT NULL` (in Postgres `NULL <> NULL`,
so a nullable identity column silently disables the constraint). Both logs
are append-only: the same structure seen an hour later is a new row, and the
difference between the two rows is the point.

### Field names

The TSV's own column names are accepted, as are the resource's
(`observed_at`, `character_name`, `solar_system_id`). Required:

|Endpoint|Required|
|---|---|
|`/scout/spawns`|`utc_timestamp`, `character`, `system_id`|
|`/scout/structures`|`utc_timestamp`, `character`, `system_id`, `structure_id`|

`utc_timestamp` (`"YYYY-MM-DD HH:MM:SS"`, UTC) is preferred over the local
`timestamp` column, which is only a fallback: the log is shared by clients in
different timezones, so the local column is not comparable across rows.

## Two traps in `structures.tsv`

Both are in the writer (`core/obj_StructureWatch.iss`), not here, and both
cost a wrong column mapping if you parse that file positionally.

1. **The on-disk header is stale.** It names 24 columns; the writer emits
   **26**. `anchoring` and `unanchoring` were added between `vulnerable` and
   `timer_seconds` and the header row — written once, on file creation — was
   never rewritten. Rows written before that change really do have 24 fields,
   so a parser should switch on the field count, not trust the header.

   Real order: `timestamp, character, event, system_id, system_name,
   system_truesec, structure_id, type_id, type_name, group_name, owner_id,
   owner_name, alliance_id, upkeep_state, upkeep_label, structure_state,
   state_label, vulnerable, anchoring, unanchoring, timer_seconds, shield_pct,
   armor_pct, hull_pct, distance_m, utc_timestamp`.

2. **`type_name` is not a type name.** The writer fills it from
   `Entity.Name`, i.e. the player-set structure name ("Sirekur - Happy MC
   TIMES"). The type is `type_id`; `group_name` carries "Citadel"/"Refinery".
   Stored as `structure_name`; `type_name` is accepted as an input alias.

`system_name` is also frequently just the system ID as a string — the client
caches the resolved name and logs the ID until it has one.

## Timers

`timer_seconds` is a countdown **relative to the observation**, with `-1`
meaning "no timer". Stored as sent, and also resolved at ingest to an
absolute `timer_expires_at = observed_at + timer_seconds`: a relative
countdown is meaningless in a log read hours later. Verified on real data —
two observations of the same Egmar citadel seven hours apart, with
`timer_seconds` of 32405 and 7278, resolve to the same expiry.

## Permissions

| | |
|---|---|
|`:scout_intel_view`|Read `/scout`. An ordinary `GroupPermission` row on a managed "Scout Intel Viewers" group, so `PermissionCache.has_permission?/2` answers for it like any other.|
|Who can grant it|**Only** `ScoutAccess.superadmin?/1`: the single user owning `WANDERER_BOOTSTRAP_ADMIN_CHARACTER`. A `:corp_suite_admin` cannot grant it, cannot revoke it, and cannot grant it to themselves.|
|With the env var unset|Nobody is superadmin and the permission cannot be granted through the UI at all — an unset bootstrap character means the deployment has no declared owner.|

The superadmin can always read the log without holding an explicit grant, and
is deliberately not listed on the access page: showing an implicit grant as a
revokable row would be a lie.

`grant_by_character_name/2` and `revoke/2` re-check the tier themselves, so a
socket that was authorized at mount and is not any more still cannot write.

### The sidebar entry

`/scout` is the one permission-gated icon in the sidebar
(`WandererAppWeb.ScoutNav`). Every other entry is gated on a flag or a
role already in the socket, because `Nav.on_mount/4` runs on EVERY
LiveView mount — the map canvas included — and AGENTS.md forbids a
database round trip there. `CorpNav` links no admin-only page for exactly
that reason.

This one is affordable because `ScoutAccess.can_view_cached?/1` answers
from `WandererApp.Cache`, and `grant_*`/`revoke/2` invalidate the entry,
so the icon appears and disappears on the next page load rather than on a
TTL. The 5-minute TTL is only a backstop for a write that bypassed the
module. The page's own `mount/3` calls the **uncached** `can_view?/1`: a
stale cache may cost a wrong icon, never a wrong page.

## Files

|What|Where|
|---|---|
|Ingest + coercion|`lib/wanderer_app/scout/ingest.ex`|
|Resources|`lib/wanderer_app/api/scout_{spawn,structure}_sighting.ex`|
|Controller|`lib/wanderer_app_web/controllers/scout_intel_api_controller.ex`|
|Flag plug|`lib/wanderer_app_web/controllers/plugs/check_scout_intel_disabled.ex`|
|Permission tier|`lib/wanderer_app/identity/scout_access.ex`|
|Pages|`lib/wanderer_app_web/live/scout/scout_{intel,access}_live.ex`|
|Sidebar entry|`lib/wanderer_app_web/components/scout_nav.ex`|
|Tests|`test/integration/scout_intel_test.exs`|

## Verified

Against a booted server and the real TSV files (80 spawn rows, 14 structure
rows), 2026-09-29:

- flag off ⇒ both ingest routes 404; flag on ⇒ 200
- missing/wrong bearer token ⇒ 401
- 80/80 and 14/14 stored, 0 failed; posting both files twice left exactly
  80 and 14 rows in the database
- a row with no timestamp failed alone, the good row in the same batch stored
- `/scout` renders the timer and last-seen tables for the bootstrap
  admin; a logged-in non-grantee is redirected to `/maps` and sees neither
