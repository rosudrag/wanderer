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
|`ScoutSpawnSighting`|`observed_at, solar_system_id, location_name, spawn_name`|
|`ScoutStructureSighting`|`structure_id, observed_at, event`|

Every column in those identities is `NOT NULL` (in Postgres `NULL <> NULL`,
so a nullable identity column silently disables the constraint). Both logs
are append-only: the same structure seen an hour later is a new row, and the
difference between the two rows is the point.

### The observing character is not stored

Neither resource carries submitter attribution: this log answers "what was
there", not "who was parked next to it". A `character` / `character_name`
key in an incoming row is **ignored, not rejected**, so an older client keeps
working unchanged. Two consequences worth knowing: the name is out of
`ScoutSpawnSighting`'s identity, so two pilots reporting the same spawn at
the same second in the same place upsert onto one row — the honest count of
the event — and `character` is not a required field on either endpoint.

### Field names

The TSV's own column names are accepted, as are the resource's
(`observed_at`, `character_name`, `solar_system_id`). Required:

|Endpoint|Required|
|---|---|
|`/scout/spawns`|`utc_timestamp`, `system_id`|
|`/scout/structures`|`utc_timestamp`, `system_id`, `structure_id`|

`utc_timestamp` (`"YYYY-MM-DD HH:MM:SS"`, UTC) is preferred over the local
`timestamp` column, which is only a fallback: the log is shared by clients in
different timezones, so the local column is not comparable across rows.

## Two traps in `structures.tsv`

Both are in the writer (`core/obj_StructureWatch.iss`), not here, and both
cost a wrong column mapping if you parse that file positionally.

1. **The on-disk header is stale, and the width keeps moving.** The header is
   written once, on file creation, and never rewritten — so a long-lived log
   carries whatever header was current when it was created while its rows
   carry whatever the writer emits today. Historic widths observed on disk:
   24, 26, 27 and 29 columns. The writer now emits **28** —
   `upkeep_label`/`state_label` merged into one `status` column (see "Merged
   status" below), which narrows the just-widened 29-column file by one
   rather than growing it further. **Switch on the field count; never trust
   the header.**

   Current order (28), from `obj_StructureWatch:RecordRow`: `timestamp,
   character, event, system_id, system_name, system_truesec, structure_id,
   type_id, type_name, group_name, owner_id, owner_name, alliance_id,
   upkeep_state, structure_state, status, vulnerable, anchoring,
   unanchoring, timer_seconds, shield_pct, armor_pct, hull_pct, distance_m,
   utc_timestamp, timer_utc, nearest_celestial, nearest_celestial_m`.

   `anchoring`/`unanchoring` were inserted before `timer_seconds` (24 → 26),
   `timer_utc` appended (26 → 27), `nearest_celestial`/`nearest_celestial_m`
   appended (27 → 29), and `upkeep_label`/`state_label` merged into the
   single `status` column (29 → 28). `timer_utc` is the absolute instant
   the timer expires, computed client-side; this endpoint ignores it and
   derives `timer_expires_at` from `observed_at + timer_seconds` itself, so
   the two are cross-checkable rather than redundant.

2. **`type_name` is not a type name.** The writer fills it from
   `Entity.Name`, i.e. the player-set structure name ("Sirekur - Happy MC
   TIMES"). The type is `type_id`; `group_name` carries "Citadel"/"Refinery".
   Stored as `structure_name`; `type_name` is accepted as an input alias.

`system_name` is also frequently just the system ID as a string — the client
caches the resolved name and logs the ID until it has one.

## Merged status

`upkeep_state` (power) and `structure_state` (lifecycle/combat) describe ONE
verdict with two labels, and the pair lies on its own: a structure that never
finished deploying has no service module **by construction**, so the server
drives it to `LowPower` immediately and `Abandoned` ~7 days later
(`structures/structure.py:586-608`, `ABANDONING_TIME_MIN`). Live data showed
5 rows of `Abandoned + Onlining` that were half-finished drops, not abandoned
hulls.

One column replaces both: **`status`** (string, PascalCase, no spaces).
Computed client-side by eveknob and stored verbatim — this server never
re-derives it. Upwell structures (categoryID 65), first match wins:

| # | Condition | `status` |
|---|---|---|
| 1 | `unanchoring` bool is TRUE | `Unanchoring` |
| 2 | `structure_state` == 1 (STATE_UNANCHORED) | `Unanchored` |
| 3 | `structure_state` == 2 (STATE_ANCHORING) | `Anchoring` |
| 4 | `structure_state` == 115 (STATE_ANCHOR_VULNERABLE) | `AnchorVulnerable` |
| 5 | `structure_state` == 116 (STATE_DEPLOY_VULNERABLE) | `Deploying` |
| 6 | `structure_state` == 101 (STATE_FITTING_INVULNERABLE) | `Fitting` |
| 7 | `structure_state` == 102 (STATE_ONLINING_VULNERABLE) | `Onlining` |
| 8 | `upkeep_state` == 3 (UPKEEP_STATE_ABANDONED) | `Abandoned` |
| 9 | `structure_state` == 111 (STATE_ARMOR_REINFORCE) | `ArmorReinforced` |
| 10 | `structure_state` == 113 (STATE_HULL_REINFORCE) | `HullReinforced` |
| 11 | `structure_state` == 112 (STATE_ARMOR_VULNERABLE) | `ArmorVulnerable` |
| 12 | `structure_state` == 114 (STATE_HULL_VULNERABLE) | `HullVulnerable` |
| 13 | `upkeep_state` == 2 (UPKEEP_STATE_LOW_POWER) | `NoFuel` |
| 14 | `structure_state` == 118 (STATE_FOB_INVULNERABLE) | `FobInvulnerable` |
| 15 | `upkeep_state` == 1 and `structure_state` == 110 | `FullPower` |
| 16 | anything else | `Unknown` |

Three rulings baked into that order:

- **Rows 1-7 (the deployment family) outrank upkeep entirely.** Upkeep is
  meaningless during deployment — this is what turns the 5 live
  `Abandoned + Onlining` rows above into honest `Onlining`.
- **Row 8 outranks rows 9-12.** `Abandoned` means asset safety is off and the
  hull drops its contents — the rarest, highest-value finding, and a
  reinforcement timer does not change that. `timer_utc`/`timer_seconds`
  still carry the timer and `vulnerable` still carries "shootable right
  now", so nothing is lost by `status` alone reading `Abandoned`.
- **Rows 9-10 outrank row 13**: "a Low Power and Reinforced just means
  Reinforced." Armor vs hull is kept distinct in storage (hull reinforce is
  the final timer, armor is not); the UI may group both under one
  "Reinforced" filter.

Orbitals (categoryID 46: POCO groupID 1025, Orbital Skyhook groupID 4736)
have no upkeep concept — `upkeep_state` stays EMPTY for every orbital row.
`unanchoring` TRUE still wins (`Unanchoring`); otherwise `status` is the
existing family label verbatim, from `obj_StructureLabels.PocoStateLabel` /
`.SkyhookStateLabel` (POCO: `Anchoring | Onlining | ShieldReinforced |
Anchored | Unknown`; Skyhook: `ShieldVulnerable | ArmorReinforced |
ArmorVulnerable | HullReinforced | HullVulnerable | Unknown`).

### Status families

`WandererApp.Scout.Status` (`lib/wanderer_app/scout/status.ex`) defines each
group ONCE so every reader (resource read actions, `/scout`, any future
export) groups the same way:

```
unanchored_family/0 : Unanchored
anchoring_family/0  : Anchoring, AnchorVulnerable, Deploying, Fitting, Onlining
unanchoring_family/0: Unanchoring
reinforced_family/0 : ArmorReinforced, HullReinforced, ShieldReinforced
vulnerable_family/0 : ArmorVulnerable, HullVulnerable
abandoned_family/0  : Abandoned
no_fuel_family/0    : NoFuel
dead_family/0       : Abandoned, NoFuel (the two above, for grouping only)
steady_family/0     : FullPower, Anchored, ShieldVulnerable, FobInvulnerable
```

`steady_family` is the boring state and is still not journalled by the
eveknob writer (unchanged behaviour).

`Unanchored` left `anchoring_family` in 1.103.4-chewy.54. It is not "being
built": it is a structure floating in space fully undeployed, with no
fitting, no services and no timer to wait out — the highest-value thing
this log ever reports — and inside the anchoring family it was one row
among half-built Astrahuses. It now has its own family, its own read
action, and the alert described below.

### Four scoped read actions

`WandererApp.Api.ScoutStructureSighting` gains `:unanchored`, `:anchoring`,
`:unanchoring` and `:abandoned`, same argument shape as `:search` (`since`,
`system_id`, `q`) and NOT exposed through `code_interface` either, matching
`:search`:

|Action|Filter|
|---|---|
|`:unanchored`|`status in Status.unanchored_family()`|
|`:anchoring`|`status in Status.anchoring_family()`|
|`:unanchoring`|`status in Status.unanchoring_family()`|
|`:abandoned`|`status in Status.abandoned_family()`|
|`:no_fuel`|`status in Status.no_fuel_family()`|

All four feed a dedicated `/scout` structures-tab table, latest sighting
per `structure_id` — the same `Ash.Query.distinct([:structure_id]) |>
Ash.Query.distinct_sort(observed_at: :desc)` fold the ingest log applies on
top of `:search`:

- **Unanchored** — floating undeployed. See "The unanchored alert".
- **Anchoring** — no fitting, no services, a live vulnerability window: the
  cheapest kills in the game.
- **Unanchoring** — a structure being pulled out of the ground: a one-shot
  opportunity with a hard deadline nobody reports. See "Predicted max out".
- **Abandoned** — asset safety off: everything inside drops.
- **No fuel** — low power, no tether, no services. Its own board since
  1.103.4-chewy.86; it shared one with Abandoned through `dead_family/0`,
  and "this is loot now" and "this owner stopped paying" are different
  errands. Neither carries a timer, so neither can appear in the timer
  table, and before these boards both were visible only as one muted row
  somewhere in the flat log.

Every one of them honours the search / system filter / window except
`:unanchored`, which deliberately does not — see below.

## Predicted max out — the Unanchoring board's deadline

`WandererApp.Scout.Unanchor` owns it; `ScoutComponents.predicted_out_cell/1`
renders it.

The board's first column used to be **Comes out**, a `countdown_cell/1` over
`timer_expires_at`, and it could never show anything but an em dash: a
decommission reports no countdown on the wire. `timer_seconds` carries
reinforcement timers only, so that column was structurally empty and the
board — the one whose whole point is a deadline — had no deadline at all.
Worse, `by_deadline/1` sorted it on that nil, i.e. not at all.

The mechanic supplies what the wire does not. Decommissioning an Upwell
structure takes a **fixed 7 days**, and cancelling it restarts the full 7
([CCP support][decom]), so the only unknown is when the owner started. The
feed bounds that from one side: `unanchoring_since` on
`WandererApp.Api.ScoutStructure` is the first sweep that saw the structure
in `Status.unanchoring_family/0`. Therefore

```
predicted max out = unanchoring_since + 7 days
```

is the **latest** the hull can still be in space — the true completion is at
or before it, never after, because an unanchor may have been running for
days before a scout first flew past but cannot have started after we saw it.
That is why the cell renders `≤ 3d 4h` and the column says *max*: it is a
bound, not a timer, and the error direction is the safe one (you may arrive
early, never too late).

Three rules keep the bound honest, all in `Unanchor.transition/4` and
applied by `Scout.Snapshot` on the appeared / changed / unchanged paths:

- A status leaving the family **ends the run** rather than clearing the
  anchor (it used to null it): `unanchor_ended_at` / `unanchor_outcome` are
  written, the anchor stays to date the run on the resolved board, and
  `predicted_max_at/1` refuses to answer for an ended run — so no board can
  read a dead anchor as a live deadline. A **restart** re-anchors on the
  restart, because a cancelled decommission restarts the full 7 days.
- A later sweep confirming the **same** run never moves the anchor forward;
  the anchor is the first sighting of that run.
- A row that is unanchoring with no anchor stored (a backfilled one) takes
  the current sweep, the earliest start the feed can still prove.

Orbitals are **excluded rather than predicted**: a customs office gantry
unanchors in seconds and a POCO in minutes, a different mechanic entirely,
so `predicted_max_at/1` returns nil for any `group_name` matching
`orbital|customs` and the cell stays an em dash with a title saying why. An
unknown or absent group is treated as Upwell — that is what the
overwhelming majority of rows are.

The board sorts on this (`by_predicted_out/1` in `scout_intel_live.ex`,
soonest first, anchorless rows last), and `unanchoring_since` is a stored
column, so it is in the CSV export like every other one. The backfill
migration (`20261004185858`) seeds existing runs from the event log: the
LATEST `status_after = 'Unanchoring'` transition per structure, falling back
to `last_changed_at` — both upper bounds on the real start.

[decom]: https://support.eveonline.com/hc/en-us/articles/208289335-Upwell-Structure-Deployment-and-Unanchoring

## Someone else sorted it — how an unanchoring run ENDS

`WandererApp.Scout.Unanchor` owns the vocabulary;
`ScoutStructure`'s `:unanchor_resolved` read and the **Someone else sorted
it** board render it.

A decommission is the only finding on this page with a fixed lifetime, and
until 1.103.4-chewy.110 it left the Unanchoring board by *disappearing*. The
row went `:gone`, or a `steady_ids` entry cleared it, or its 7 days quietly
ran out — and the page said nothing. "Nobody got it and it is over" and "we
are still waiting" looked identical, and the one thing a fleet wants to know
about a hull it has been watching for a week is which of those it is.

Measured on the live database 2026-10-14: **41** rows sitting at
`status='Unanchoring'` / `presence='gone'` and 2 more re-sighted in another
status — 43 endings nobody could see, against 30 rows the Unanchoring board
was still offering. Two of those 30 were already past their 7 days: listed
as hulls to fly to, and in the `now_rows/1` lead as well, which took
anything inside 48h of the bound *including a bound already passed*.

Four endings, one derived:

|Outcome|Observed by|Means|
|---|---|---|
|`:unanchored`|a sighting in `Status.unanchored_family/0`|the hull came out and is loose — **not** on this board, it is on the red alert|
|`:stopped`|a sighting in any other status, or a `steady_ids` clear|the decommission is not running any more and the structure is still there|
|`:vanished`|the absence pipeline promoting it to `:gone`|it finished and was collected (or killed) between two of our visits|
|`:expired`|**nothing** — derived at read time|`unanchoring_since + 7d` has passed with nothing to contradict it, so it cannot still be in the ground|

`:expired` is never stored, on purpose: nothing observed it, and a write
would turn an inference into a record. `Unanchor.outcome/2` resolves stored
and derived endings through one function, so the board does not care which
it is reading, and `ended_cell/1` renders a stored ending like every other
observation on the page but an expired one as `≥` the bound it passed.

Three loads of the rule, each a place it would otherwise be wrong:

- A `steady_ids` clear carries **no status**, so `status` stays
  `"Unanchoring"` on that row forever. That is exactly why the ending is its
  own column rather than inferred from `status` later — and why the
  `:unanchoring` board filters `is_nil(unanchor_outcome)` as well as
  `presence == :seen`.
- The `:unanchor_resolved` read is the one board on this page that does
  **not** filter `presence == :seen`: `:vanished` *is* `:gone`, so filtering
  presence would empty the board of the rows it exists for. `archived ==
  false` still applies — a reader's dismissal outranks every board here.
- An absence only ends a run at `:gone`, never at `:missing`. One quiet
  d-scan proves nothing; `Snapshot.gone?/5` (two absences 30 minutes apart,
  or an expired wire timer) is where that judgement already lives.

Migration `20261014162500` backfills those 43 endings from the append-only
event log — the `:gone` / `cleared` / `changed` event that observed each
one, falling back to `missing_since` where the event write had failed.
`presence='missing'` rows are deliberately left alone: they are not endings
yet.

The board is copyable to Discord (`🪦 Unanchoring runs that ended`) but is
**not** in the digest: the digest is the next hour's errand list, and a
post-mortem belongs in neither its first message nor the extra ones it would
add.

## Flying to a row: the `⤳` button and the pilot picker

Every board on this page is a list of places to go, and the step between
reading one and flying it used to be: read the system name, alt-tab, type it
into the game's own search, set destination. `ScoutComponents.sys/1` now
carries a `⤳` that sets that system as the selected character's autopilot
destination, and the page header carries the one control that says **which
character** (`pilot_picker/1`).

Four decisions:

- **The button lives inside the system cell**, not in a column of its own.
  There are fifteen tables on this page and none has width for another column
  — and a waypoint is an action on a system, so it belongs beside the system.
  One edit to `sys/1` gave every board the button, including spawns, with no
  risk of a header and a body row disagreeing about column count.
- **The pilot is picked once, in the header.** Repeating the control per board
  is how two boards end up flying two different pilots. The selection is
  validated against the user's OWN characters on every change: that id decides
  whose in-game route gets rewritten and the `<select>` is user-writable.
- **It reuses `WandererApp.Scout.PlanWaypoints`** as a one-stop plan, so it
  inherits the three things the planner's `Set route` learned the hard way —
  the preflight GET that refreshes an expired token, reading ESI's real answer
  (204 is the only success `/ui/autopilot/waypoint` documents), and noticing
  that EVE accepts a waypoint for a logged-out client and discards it.
  `clear_other_waypoints` is true: "fly me there" replaces the route rather
  than appending to yesterday's.
- **The wording is shared, in `WandererAppWeb.ScoutWaypoint`.** The planner's
  `push_status/3` and `esi_reason/1` moved there and both pages call it. A
  second copy of those clauses would drift, and they ARE the feature: the push
  lands in a game client, which is invisible from the browser, so a button
  with no sentence beside it is indistinguishable from a button that did
  nothing. That was the 2026-10-05 report, and this button would have
  re-opened it.

## The unanchored alert

`WandererApp.Scout.Alerts` owns it. One finding, four surfaces, because a
log you have to be reading is not an alert:

|Surface|What|
|---|---|
|Sidebar badge|A red count on the `/scout` eye icon, drawn on **every** page including the map canvas — the only part of this visible without opening the log. `count_cached/0` answers from `WandererApp.Cache` (`Nav.on_mount/4` runs per LiveView mount; a query there is forbidden), `Ingest.announce/1` invalidates it on every structure batch, and the 5-minute TTL is only a backstop. Never computed for a user without `:scout_intel_view`|
|Banner|A red bar above the toolbar on **both** tabs, with one click-to-filter chip per system and the age of each sighting|
|Panel|Its own table at the top of the structures tab, above Live timers, with a red border. Rendered only when non-empty|
|Card + badge|The first summary card, and the only solid-red status badge on the page|

Two filter rules, both deliberate and both tested:

- **Its own horizon** (`Alerts.horizon_days/0`, 7 days), not the window
  selector — an unanchored structure stays unanchored until somebody moves
  it, so "24 hours or 90 days" is the wrong question, and the live timer
  table and the spawns tab's 24h list already ignore that selector for the same
  reason.
- **The search box does not narrow it**, though the system and space
  filters do. The search is tab vocabulary — on the spawns tab it is belt
  and spawn names — and an alert a search box can hide is not an alert.

## Archiving a finding by hand

The feed says what a bot saw; `archived_at` on `WandererApp.Api.ScoutStructure`
is the one thing a *reader* can assert — "I flew there, it is not there, stop
shouting at me". Every structure board carries a `✕` in its last column
(`ScoutComponents.archive_cell/1` → `"archive_structure"`), and the row leaves
every opportunity board, the red banner, the summary card and the sidebar
badge at once.

It is **not** a delete and not a presence:

- the row stays in the ingest log, in the drill-down, and in the CSV export
  (which gained an `archived_at` column);
- it appears on its own **Archived** board — rendered only when non-empty,
  deliberately NOT bounded by the window selector, since an archive that aged
  out of the window would be impossible to undo from the page — with a `↺`
  that restores it (`"restore_structure"`);
- `presence` is untouched. The two are orthogonal: `presence` is derived
  from the diff, `archived_at` is a human's judgement about it.

**The expiry rule is `last_changed_at`, not `last_confirmed_at`**, and that
is the whole design. A sweep re-confirming the same unanchored hull every few
minutes moves `last_confirmed_at` constantly; if that un-hid the row, the
button would be useless in exactly the case it exists for. An actual state
change (status, owner, timer, …) moves `last_changed_at`, and that is new
information, so the finding comes straight back. One `:archived` expr
calculation holds the predicate —
`archived_at is not null and (last_changed_at is null or last_changed_at <= archived_at)`
— and every board filters `archived == false` next to its `presence == :seen`.
A tie goes to the human: a change recorded in the same second as the click
stays archived.

`:search` (the ingest log) again shows everything, archived included: it is
the "what do we know" table, not a target list.

## Timers

`timer_seconds` is a countdown **relative to the observation**, with `-1`
meaning "no timer". Stored as sent, and also resolved at ingest to an
absolute `timer_expires_at = observed_at + timer_seconds`: a relative
countdown is meaningless in a log read hours later. Verified on real data —
two observations of the same Egmar citadel seven hours apart, with
`timer_seconds` of 32405 and 7278, resolve to the same expiry.

## Repeat observations are merged at ingest

The client re-reports every structure on grid on **every pass**. The table
is append-only, so a Fortizar sitting in armor reinforcement for 36 hours
used to produce one row per pass — hundreds saying the same thing, and the
page showed three identical "Dal - Nothing to see here part 2" lines in the
timer table.

Two independent fixes, both needed:

1. **The read folds.** Every structure board on the page is
   `DISTINCT ON (structure_id) ORDER BY observed_at DESC`. The live timer
   table was the one that was not, which is the duplication that showed.
   Fixing the write alone would not have helped: the rows already stored
   stay stored.
2. **The write merges** (`WandererApp.Scout.Merge`). An incoming `SEEN`
   that repeats the previous sighting of the same structure moves that
   row's `observed_at` forward (`:touch`) instead of inserting. So "Seen
   4m ago" stays honest while the history keeps only the changes — which
   is what a per-structure history is for.

What counts as a repeat: both rows are `SEEN`, the incoming row is not
older than the stored one, and every field in `Merge.changed_fields/0`
(status, ownership, name, the vulnerability flags, the HP readings, the
system) is equal. `event: :change` is never merged in either direction —
the writer already decided it is news.

**Timers compare with a tolerance.** `timer_expires_at` is derived from the
client's relative `timer_seconds`, re-read each pass, so two readings of
one running timer differ by seconds. Equality would make every pass "a
change" and defeat the module; two expiries within 120s are the same timer.

The merge costs one indexed lookup per ingested row —
`index([:structure_id, :observed_at])`, added for it and used by the
history drill-down too.

## Leaving the watchlist: two absence witnesses

A finding has to be able to STOP being one. `presence` is that signal
(`:seen → :missing → :gone`, reset by any sighting), every opportunity board
filters `presence == :seen`, and nothing is ever deleted — the flat log, the
per-structure event history and the CSV export keep a retired row.

Deriving it needs evidence of an absence, and there are exactly two sources:

1. **A complete snapshot blob** (`WandererApp.Scout.Snapshot`,
   `POST .../scout/structures/snapshot`). A structure the blob should have
   seen and did not gets an absence tick; two ticks from distinct visits 30
   minutes apart promote it to `:gone`.
2. **A dwell in the coverage ledger** (`WandererApp.Scout.Absence`, run from
   `WandererApp.Scout.Coverage`'s ingest). Because the client only posts a
   blob when it has something to list, the LAST structure in a system can
   never be retired by (1): the system empties, the blobs stop, and the row
   shouts forever. Measured 2026-10-08: five of the seven stale `Unanchoring`
   rows sat in systems whose newest coverage row was days newer than any
   structure confirmation there. The scout flew the route, saw nothing, and
   had no way to say so.

Coverage is weaker evidence than a blob, so (2) is fenced three ways and each
fence has a test in `test/integration/scout_absence_test.exs`:

|Fence|Why|
|---|---|
|`anoms \| sigs \| grid` only|A `visit` is a gate-to-gate pass and proves nothing about what is on d-scan|
|Structure must be stale by ≥ 2h|The blob lands on ARRIVAL, the coverage row when the work ends; measured dwells (147 visit→grid pairs) run mean 5 min, p95 11 min, max 16.3 min, so a shorter grace would let a visit retire what it just confirmed|
|`Absence.feed_live?/1`|Some structure, anywhere, confirmed within 6h of this observation. A client with no structure watch keeps posting coverage, and reading that as "nothing is out there" would wipe the watchlist|

Both witnesses share one tick (`Snapshot.absent/4`), so the promotion rule,
the event row and the "never drag a structure backwards" guard are defined
once. The event's `changed_fields` carries `"coverage:<kind>"` when the
ledger was the witness, so the drill-down says which one retired it.

Two related fixes landed with it:

* **A positionless row is diffable.** `in_scope?/2` used to require a stored
  position, which the retired per-row feed never wrote — so 33 rows (7 of
  them `Unanchoring`) were immortal, sitting on the boards while blobs
  cleared their neighbours in the same systems. A complete blob is the only
  evidence such a row will ever get, so it counts; one absence takes it off
  the boards, `:gone` still needs two, and a sighting both restores it and
  finally stores a position.
* **An empty blob is sayable.** `structures: []` plus `steady_ids: []` is
  refused by default (a client bug must not read as "the system is empty"),
  but accepted with `allow_empty: true` — the same convention as the
  signature-sync endpoint. A client that posts it retires an emptied
  system's last structure directly, without waiting for the coverage witness.

## The page

`/scout` is **three categories over one LiveView** — Structures, Spawns and
Planner — and one `WANDERER_SCOUT_INTEL` flag covers all of it (the Planner
category additionally needs `WANDERER_SCOUT_PLANNER`).

### One page, three categories

`WandererAppWeb.ScoutIntelLive` is the only routed view under
`live_session :scout`: `/scout` and `/scout/structures` are `:structures`,
`/scout/spawns` is `:spawns`, `/scout/planner` is `:planner`. The category
is therefore in the **URL**, switching it is a `<.link patch>` handled by
`handle_params/3`, and the consequences are the point: no remount, so no
`opacity-0 → duration-500` fade from the live layout, no scroll reset, no
chrome rebuilt; browser back/forward works; and every category is
bookmarkable.

It used to be `phx-click="select_tab"` with the chosen tab restored from
localStorage *after* first paint, which meant landing on `/scout` with
"spawns" saved painted the structures boards (six queries) and then flipped
to spawns (two more) — the visible jank that this shape removes. There is
no "last category" memory any more, by design: the URL replaces it.

`WandererAppWeb.ScoutPlannerLive` is no longer routed. It is a **nested
LiveView** (`live_render/3`, id `scout-planner-live`) inside a shell-owned
`#scout-planner-pane` div, mounted lazily the first time a reader opens the
Planner category and then NEVER unmounted — the pane just gains `hidden`.
A sweep costs seconds to compute, and a routed page threw that away on
every glance at the log. Two rules follow: the child does not go through
`live_session`'s `on_mount` chain, so it resolves `current_user` from the
session itself (`UserAuth.on_mount(:ensure_authenticated, …)`) and re-checks
`ScoutAccess.can_view?/1` and the planner flag independently of its parent;
and it must never `push_patch` — a child does not own the URL.

The page chrome is one shape for every category, so nothing moves when you
switch: `<.scout_header>` (title, live dot, the three tab links, per-category
actions) → optional unanchored alert → `<.scout_toolbar>` (that category's
own controls) → body. All four live in `ScoutComponents`; the planner child
renders its own `<.scout_toolbar>` holding the rank/sweep mode switch and
Refresh.

|Tab|What it leads with|
|---|---|
|Structures|**Unanchored**, then live reinforcement timers (soonest first, colour-coded: red under an hour, amber under six), then **Unanchoring**, **Anchoring** and **Abandoned** (latest sighting per structure whose `status` is in that family — see "Merged status" above), and last, at the bottom and deliberately quiet, the ingest log: the latest observation **per structure** folded by Postgres `DISTINCT ON (structure_id)`. Any row drills down into that structure's full history on click|
|Spawns|"Seen in the last 24h" — the latest sighting **per system + location + spawn name** within the last 24 hours, folded by Postgres `DISTINCT ON (solar_system_id, location_name, spawn_name)`, same trick as the structures tab's fold — then the flat reverse-chronological ingest log, and every sighting of *that* spawn at *that* location on click. There is no aggregate between the two: a hotspot table ("this belt has had 7 spawns in 30 days") shipped once and never changed what anyone did next, while costing a `GROUP BY` on every read of the tab|

**Boards are findings; the log is the tape.** Everything above the ingest
log answers "what should a fleet do right now"; the flat log answers "what
has the client sent". They are not rendered with the same weight — see
`log_panel/1` below — and the log sits at the bottom of both tabs.

**Order is assigned, never inherited from the query.** Every structure board
runs through a `DISTINCT ON` whose `ORDER BY` exists to pick the surviving
row per structure, not to order the result, so `ScoutIntelLive` sorts each
list in the BEAM over the page it already holds: `by_deadline/1` (soonest
`timer_expires_at` first, rows without one last) for the timer and
unanchoring boards, `by_recent/1` (newest `observed_at` first) for every
other board and both spawn lists.

Seven properties that are deliberate, not incidental:

- **It ticks.** `now` is re-assigned every 30s and timers that ran out drop
  out of the live table. No query: a 30s poll per open page would be a
  database round trip to display arithmetic.
- **The 24h list ticks too, the same way.** It is independent of the
  window selector above it — a spawn seen 20 minutes ago inside a 24-hour
  window and a spawn seen 20 minutes ago inside a 90-day window are the same
  "probably still there" — and it ages out on the 30s `:tick` with no
  query, exactly like an expired reinforcement timer: rows older than
  `@fresh_seconds` (24 hours) are dropped from the already-loaded list
  rather than re-queried.
- **A spawn has no id.** `{solar_system_id, location_name, spawn_name}`
  is its identity — the same triple `ScoutSpawnSighting`'s
  `:uniq_sighting` upserts the ingest on — so both the 24h list and the
  ingest log drill down on click into every sighting of that spawn at that
  location (`ScoutSpawnSighting.history/4`), passed as three values
  rather than one id. This is the one asymmetry with structures, which
  do carry a `structure_id` and drill down on that single value.
- **It is pushed to.** `Ingest` broadcasts `{:scout_intel_ingested, :spawns |
  :structures}` on the `"scout_intel"` topic whenever a batch stored
  anything; the page reloads only the tab that kind affects.
- **It never silently truncates.** Reads ask for `limit + 1` rows and the
  extra row *is* the "there are more" banner — cheaper than a `count(*)` over
  the window, and exactly as honest. "Load more" raises the limit by a page
  (250).
- **It resolves system names itself.** The client logs the raw system ID
  until it has cached a name, so the page asks `CachedInfo.
  get_system_static_info/1` (Cachex-backed) rather than printing "30002386".
- **An empty table says which kind of empty it is.** `Stats.totals/0` is
  queried *only* when a table came back empty, so "nothing in this window"
  and "nothing has ever been reported" are different sentences. `count(*)` on
  an append-only table is a sequential scan; that is why it is conditional.

Filtering is one search box (an ILIKE in Postgres over the four strings a
reader would type), a space-type chip row, and a system filter set by clicking
any system cell and cleared by the chip in the toolbar. All three apply to
every table on the tab, including the timer table and the 24h spawn list —
`since` deliberately does not: a running timer is running however old the
sighting that found it.

### How it is rendered

`WandererAppWeb.ScoutComponents` owns the page's vocabulary; the template is
markup and the LiveView is reads. It exists because nine tables spelled the
same five cells out inline and drifted: "Last seen" showed a truesec "Live
timers" did not, two of the four structure tables showed the nearest celestial
and two did not, and an empty table was a bare `<td>` in one place and a
sentence in another.

|Component|What it fixes|
|---|---|
|`panel/1`|A section is a bordered card with a title, a **row count**, and a one-line hint — not an `<h2>` over a paragraph of prose over a full-bleed table, which is what made the page read as a wall|
|`log_panel/1`|The flat ingest log at the bottom of a tab, rendered as what it is: dashed border, monospace label, muted body. It is NOT a `panel/1` — giving the tape the same weight as a finding ended the page on its least actionable table|
|`stat/1`|The strip under the toolbar: timers running (and how many inside the hour), anchoring, unanchoring, rows in the window. Counted from the rows the page already holds — never a second query — and capped reads say `250+`, the same string the panel chip shows|
|`sys/1`|Name, then **one** qualifier: the class title in w-space and Pochven, the security status everywhere else. `map_solar_system_v2` titles nullsec `0.0` and lowsec `L`, so showing both rendered `1DQ1-A 0.0 -0.4` and `J110145 C5 -1.0`. Falls back to the static map's `security` when the client logged no truesec. Under that line, muted, the **region** — see below|
|`status/1`|Coloured by family, and **quiet** for the steady tier: when every row shouts, the reinforced one stops standing out|
|`seen/1`, `countdown_cell/1`|Age first (what you act on), timestamp under it (what you paste in fleet chat)|
|`empty/1`|One empty state, so every table says nothing the same way|

Every row on this page has a system, and therefore a region: `sys/1` renders
it as a muted second line (`ScoutComponents.region/2`), and the toolbar's
system chip and the unanchored alert's tooltips render the one-line form
`Jita, The Forge` (`system_region/2`). It costs no query — `assign_systems/2`
already resolves each `solar_system_id` through `CachedInfo.get_system_static_info!/1`,
whose struct carries `region_name` beside the name and class title this page
was already reading. Nothing is stored and no static table was added: the
region is derived from the system every time, so a row logged before the
static map knew the system still renders a region once it does. It is NOT a
column of its own — every table here already has a System column and none has
width to spare, and the region is context for the name above it rather than
something a reader scans down. `/scout/planner`'s tables keep their separate
`Region` column: those rows come from `Planner`/`Sweep`, which select
`region_name` in the query itself.

One column is deliberately absent: **shield / armor / hull**. It is stored,
exported in the CSV and used by `Merge.changed_fields/0` to decide whether a
re-report is news, but it is not rendered. A percentage triple read hours
after the observation says nothing a fleet can act on — the status badge and
the timer already carry the verdict.

Two more are absent as of 1.103.4-chewy.65: **both distances**. `distance_m`
is the range from whichever character happened to run the sweep — it locates
the scout, not the structure, and is meaningless once that session ends — and
`nearest_celestial_m` is real but unactionable: a reader acts on "it is on
moon 4", never on "it is 12.5 km off moon 4". The `Where` column
(`ScoutComponents.where/1`) is now the celestial's NAME or an em dash, with
no distance fallback, and the duplicate copy of it under the structure name
is gone from the tables that have a `Where` column. `nearest_celestial_m` is
still stored, still merge-significant and still in the CSV export.

Three fixes worth remembering because each was invisible until the page was
rendered in a browser: daisyUI's `select-sm` sets `line-height: 2rem` while
`@tailwindcss/forms` sets `padding: 0.5rem`, so the window selector clipped
its own text until `py-0` (the same pair is live on every other `select-sm`
in this app); `.modal:not(dialog:not(.modal-open))` outranks a `bg-black/70`
utility, so dimming the backdrop needs `!bg-black/70`; and `ScoutNav` used
`hero-viewfinder-circle-solid`, which is the Map entry's icon two rows above
it — the sidebar carried the same glyph twice, and the entry never drew the
orange active bar every upstream entry draws.

### Triage: the Now board, soloing, and what an empty board costs

Added in 1.103.4-chewy.92. The structures tab was eight tables stacked
vertically — Unanchored, Live timers, Anchoring, Unanchoring, Abandoned, No
fuel, Archived, the ingest log — and six of them share the same column set,
differing only in the leading time column. The boards themselves are right
(splitting No fuel out of Abandoned fixed a real reading problem); the
**stack** was not, and it cost in three ways at once.

**An empty board used to cost a fifth of a screen.** A header, a seven-column
`<thead>` and a padded "Nothing anchoring right now." row, six times over on
a quiet evening, which pushed the one board that DID have rows below the
fold. `panel/1` now takes `empty` and `empty_text`: with no rows it collapses
to a single muted header line carrying the sentence, and renders no table at
all. The distinction between "this board is empty" and "this board is not on
the page" stays explicit — that is why the sentence survives rather than the
board disappearing.

**The summary strip is now the board index.** It already carried exactly the
seven counts a reader would click; it just was not clickable, so reaching
Abandoned from the card reading `Abandoned 4` meant scrolling past four other
tables. A `stat/1` with `board` set renders as a button: clicking solos that
board, clicking the active one restores them all, and the toolbar grows an
`Only <board> ✕` chip so a soloed page is never a mode with no way out. It is
a render-time filter and nothing else — no read runs, and it is deliberately
NOT persisted, because soloing a board is what a reader does for the next
thirty seconds, not a preference.

**`Now` is the one board that is not a read.** Everything else reports state,
one status family per board, each on its own clock; none of them answered the
question a scout opens the page with, which is "what do I undock for in the
next hour" — that answer was spread across three tables, two of which are
usually empty and therefore several screens down. `ScoutIntelLive.now_rows/1`
folds the three time-critical families out of rows the socket ALREADY holds:
every unanchored hull (no deadline of its own — it is loot for as long as
nobody else finds it, so it sorts first), every running timer inside 6h, and
every unanchoring run whose predicted bound is inside 48h (a wider horizon
because by the time that bound is inside six hours the hull may already be
gone). Ten rows, deadline order, each badged with its family. No query, so it
can never disagree with the boards below — and every row it shows is still on
its own board, deliberately: it is a lead, not a replacement. It is assigned
in `load/1` and recomputed on the 30s tick rather than called from the
template, which cannot bind an intermediate value.

**The toolbar sticks.** `/scout`'s scroll container is the page's own
`<main class="overflow-auto">`; by the time a reader reached Abandoned the
window selector, the search box and the space chips were all off-screen, so
narrowing meant scrolling back up and losing the row being read. Sticky needs
an opaque background — the resting `bg-neutral-900/30` let table rows show
through — and no `overflow-hidden` between `scout_toolbar/1` and `<main>`,
which is why it is a direct child of it on both the intel page and the
planner.

### The filters are sticky, and they are PER CATEGORY

Window, search, system chip and space selection survive a reload, a new tab
and a browser restart. They live in **localStorage**, not on the server: a
per-user server cache would be wiped by every deploy, and on this fork that
is often. No JavaScript was written for it — upstream's generic
`LocalStorageSetting` hook (`assets/js/hooks/localStorageSetting.ts`) pushes
`ls_restore_<key>` once on mount and listens for `ls_update_<key>`, so the
page mounts a hidden `#scout-filter-store` div and the LiveView answers
`"ls_restore_scout_filters"` / emits `"ls_update_scout_filters"` after every
filter event.

The stored value is keyed by category, because the one blob it used to be
was a reported bug — narrowing structures to highsec silently narrowed the
spawns tab too:

```json
{"structures": {"days": 7, "q": "", "system_id": null, "space": ["hs","ls","ns","wh","pochven","other"]},
 "spawns":     {"days": 1, "q": "ore", "system_id": 30000142, "space": ["ns"]}}
```

There is no `tab` key any more — the URL owns which category is showing.
A legacy flat blob (the old `{"tab": …, "days": …, …}` shape) is migrated
onto the category its `tab` key names, and the other category starts at
defaults. The planner keeps its own key, `scout_planner_filters`, for the
same reason: a category's filters are that category's.

localStorage is user-writable, so every restored field is validated exactly
as a click on the same control would be: an unknown window keeps the
default, the search is truncated, a `system_id` that is not a positive
integer is dropped, and a non-empty space list that parses to nothing falls
back to every bucket rather than rendering a blank page. An explicitly empty
space list IS restored — every chip unticked is a state a reader can choose.
A restore only re-runs the reads when the ACTIVE category's values actually
changed; the unconditional second round of six queries on every page load
was the other half of the jank.

`limit` is deliberately not persisted: "Load more" is about the page you are
on, not about how you like to read the log.


### Every column sorts, and every column filters

The page-wide search box narrows a WINDOW of rows across every board at once
(it is an ILIKE in the read). Per-column sort and filter are the other
question — "only unanchoring hulls on THIS board", "the sweep by jumps",
"spawns with more than five in local" — and they run entirely in the BEAM,
over rows the socket already holds. No query, no read action, no second copy
of the data.

Three modules, one mechanism, shared by all 22 tables on `/scout` and
`/scout/planner`:

|Module|What it owns|
|---|---|
|`WandererAppWeb.ScoutTable`|the column spec (`col/3`), the state (`toggle_sort/3`, `put_filter/4`, `clear/2`) and `apply/5`, which filters, sorts, and reports|
|`WandererAppWeb.ScoutIntelColumns` / `ScoutPlannerColumns`|one spec list per table: label, `<th>` class, and the ONE value function both the sort and the filter read|
|`ScoutComponents.table_head/1`|the whole `<thead>`: a sort button per label, a filter control per column, and the `✕` that clears the table|

A column's `value` returns what the CELL SHOWS, through the same public
helper the cell calls (`ScoutComponents.system/2`, `where/1`,
`Unanchor.predicted_max_at/1`, …). That is the load-bearing rule: "filter by
what I can read" only holds while the two cannot drift.

What a filter string means is decided by the value's TYPE, never configured:

|Type|Filter|
|---|---|
|text|case-insensitive substring|
|number|`>10`, `<=3`, `=0` — or a bare string, which falls back to a substring on the rendered number|
|`DateTime`|an AGE against the page's `now`: `<2h` inside two hours, `>7d` older than a week. A reinforcement timer is in the FUTURE, so its age is negative and `<0m` means "still running"|

Sorting cycles ascending → descending → **the page's own order**, which is
the only way back to `by_deadline/1` / `by_recent/1` / the route order: a
dropdown cannot offer "whatever this board decided". Nils sort last in BOTH
directions — a structure with no deadline is not the most urgent thing on the
board because somebody flipped the arrow.

A column renders a `<select>` only when its spec DECLARES `select?: true`
(status, the asset-safety trigger, how a run ended, a spawn's outcome, an
event kind, a planner stop's reason/leg/WP). Everything else is a box, at any
row count. Inferring it from cardinality was tried and reverted: a filter box
that turns into a dropdown because today's window holds eight rows, and back
tomorrow, is a control nobody can learn — and it put every structure name
into the DOM twice.

Two deliberate limits. The state is **per table**, so filtering the log does
not touch the Unanchored board above it; and it is **not persisted** — not in
the sticky filter blob, not in a planner preset. A sort is "for the next
thirty seconds", the same judgement the soloed-board chip makes, and a preset
names a QUERY, not a table shape.

The one structural risk is that the spec list and the template's `<td>` list
are different files: a spec one column short renders a header offset by one
cell from its data, and every value a reader then sorts on is the
neighbouring column's. `test/integration/scout_table_live_test.exs` walks the
rendered DOM of every table on every category and asserts header-cell count
against each body row — the check no unit test over the spec lists can make.

### The boards collapse, and they move

Every panel on every scout page — the log's twelve structure boards and its
two spawn boards, the planner's rank/sweep/targets panels, even the access
page's two — carries three controls in its own header:

|Control|What it does|
|---|---|
|`▾` / `▸` (left of the title)|collapses the board to its header line. The count chip stays, so a collapsed board still answers "is there anything in it"|
|`▲` / `▼` (right)|moves it one place up or down|
|`⠿` (right)|drags it to any position in the same stack|

Plus `⊖` / `⊕` / `↺` in the toolbar: collapse everything, expand everything,
and put the page back the way it ships. `↺` renders only once something IS
stored, so the toolbar never carries a dead button.

Four decisions are load-bearing, and `WandererAppWeb.ScoutLayout` is where
they live:

  * **The server owns the order.** It renders `style="order:N"` on each
    panel and the drag hook (`assets/js/hooks/scoutPanelStack.ts`) only
    reports the drop. LiveView re-sorts a container's children to match the
    server's markup on the next patch, and these pages tick every 30s, so a
    client-side move would snap back within half a minute.

  * **Order is per STACK — one flex column of sibling panels** (the
    structures tab, the sweep's result pane, …). `order:` cannot move a node
    into another container, so a cross-stack drag is refused rather than
    pretended: the arrows stop at the ends of their own stack, and a stack
    of one (the planner's `Region heat`) renders no arrows at all, only the
    chevron.

  * **Anything in a stack that is not a panel carries its panel's `order:`
    too** — the sweep's `Set full route` row. An unstyled child of a flex
    container sorts to the top, which is how a note ends up above the board it
    annotates. A one-line annotation belongs in `panel/1`'s `note` slot
    instead: it renders as a footer inside the panel box, inherits its
    padding, background and position, and stays visible when the board is
    collapsed or empty — which is exactly when a "nobody is watching" note
    matters. The asset-safety and seeding watcher notes were hand-styled
    siblings (`-mt-3`, flush with the page gutter) until 1.103.4-chewy.113.

  * **It is stored in localStorage, under its own key** (`scout_layout`,
    `scout_planner_layout`, `scout_access_layout`), beside the filters and
    never inside them: a filter narrows what is on the page, this decides
    what the page looks like, and clearing one is no reason to lose the
    other. A planner PRESET deliberately does not carry it either — a preset
    names a query, not a page shape.

Restoring re-validates like a click, for the same reason the filters do. A
board this build no longer renders is dropped; a board this build ADDED is
re-inserted at the position the template gives it, after its default-order
neighbour, never appended under a 250-row log where nobody would find it.

### The space filter

Six chips — High, Low, Null, W-Space, Pochven, Other — all on by default,
each one click to drop. "Everything except highsec" is the filter the page
exists for, so it is one click — and it holds across every table of THAT
category, including the two that ignore the window selector, but never
leaks into another category.

`WandererApp.Scout.Space` owns it, and three things about it are load-bearing:

- **It classifies on `map_solar_system_v2.system_class`, not on the row's
  stored `system_truesec`.** Truesec cannot tell J-space, Pochven and
  nullsec apart (all ≤ 0.0) and the client may not have filled it in at all.
  The class is authoritative: 7 = HS, 8 = LS, 9 = NS, 25 = Pochven, and
  `WandererApp.SystemClass.wormhole_classes/0` (C1–C6, C13, Thera, the five
  drifter holes) for W-space.
- **It is a subquery, not an Elixir filter.** One `solar_system_id IN (SELECT
  … WHERE system_class = ANY($1))` per read, applied to the `Ash.Query` rather
  than carried as an action argument, so both resources and the CSV export
  share one implementation and the page's
  `limit` still bounds what reaches the BEAM.
- **`:other` is the complement, so the selection is total.** Abyssal/Zarzakh
  classes and any system missing from the static table live there, expressed
  as `NOT IN` the classes the five named buckets claim. All six selected ⇒ no
  SQL filter at all, and no row can vanish unless the reader unticked the
  bucket it lives in. Unticking everything shows nothing — the empty subquery
  says so with no special case.

`GET /scout/export.csv?tab=&days=&q=&system_id=&space=` takes the same filters
(`space` being the comma-separated chip keys, absent meaning all) and emits
**every** stored column (the CSV exists for the fields the HTML has no room
for), capped at 50k rows. It is a plain controller, so it re-checks the login
and the permission itself — the `/scout` `live_session` gate does not cover it.

`WandererApp.Scout.Stats` holds the three reads Ash cannot express
(`GROUP BY`, `max(observed_at)`, `count(*)`) as schemaless Ecto. It hard-codes
the two table names; renaming a table means editing it too.

### Pasting a board into Discord

Every board header carries a **Discord** button, and the toolbar carries
**Discord report** for the whole tab. Both open one modal holding the message
**as read-only text boxes, one per Discord-sized message**; the reader clicks a
box (it selects itself), copies it and pastes it into a channel. Nothing is put
on the clipboard on the reader's behalf, and nothing is posted from the server:
there is no webhook, no stored URL and no outbound call, so the feature cannot
leak intel to a channel nobody remembered configuring.

`WandererAppWeb.ScoutDiscord` owns the format. It reads the rows the socket
**already holds**, which is what makes the paste match the screen — same
window, same search, same system chip, same space chips, same sort.

Four things decide the format:

- **Discord's own timestamp markup is the whole point.** `<t:1760000000:R>`
  renders as a live relative countdown and `<t:…:f>` as an absolute instant,
  both in each *reader's* timezone and re-rendered on every view. A timer
  board pasted once keeps counting down in the channel; our own "2h 14m" would
  be wrong by the time anyone read it, and "22:41" is wrong for everyone not on
  UTC. Boards with a deadline emit both styles (the countdown is what a reader
  acts on, the instant is what a fleet forms on); boards without one emit the
  relative "seen" time only.
- **2000 characters, and Discord rejects an over-long message rather than
  cutting it — so the budget decides how MANY messages, never how much is left
  out.** `message/3` returns `:parts`, a list, and the modal renders one box
  per part; a board that spans a split repeats its header marked `_(cont.)_`.
  Until 1.103.4-chewy.111 the opposite was true: each board was fitted to one
  message, the overflow was dropped with a "_… 37 more not shown_" line, and
  the digest shared the budget fairly across boards to stop a 50-row
  Unanchored board eating the timers. Both mechanisms are gone — the digest
  keeps its urgency order instead, so a reader who pastes only the first box
  still gets the boards that matter most, and the rest is still there.
- **No link back to this deployment.** It is a private tool and the channel is
  not: a URL in every paste is an invitation to an SSO login nobody reading it
  can use. The paste carries rows and headers, nothing else.
- **No code fences, everything escaped.** Timestamps do not render inside a
  code block, which kills the one feature this exists for, so the message is
  plain markdown — and therefore every value off the wire is escaped. An EVE
  structure called `*** |LOOT PINATA| ***` would otherwise italicise half the
  line and spoiler-tag the rest, and a newline in a name would split one
  finding into two bullets.

The unanchoring board pastes the derived 7-day bound with its `≤`, and an
orbital pastes "no estimate" rather than a prediction it is not entitled to —
the same ruling as the column (see "Predicted max out").

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

## The asset-safety trigger: EVE telling us a hull came loose

Everything else on this page is a sweep reporting what it SAW. This one is
EVE reporting what HAPPENED, at the instant it happened.

The mechanic is a deliberate act, not a passive feed. Put **one item** into a
structure that is unanchoring. When the decommission completes, EVE moves that
item to asset safety and notifies the item's owner —
`StructureItemsMovedToSafety`, naming `structureID` and `solarSystemID`. The
hull is floating, unanchored and scoopable at exactly that moment, and nothing
else this app has can say so: `WandererApp.Scout.Unanchor` only derives a
**7-day upper bound** from the first sweep that saw the run, and the absence
pipeline only notices the hull is gone on the next sweep through that system,
which may be a day later. Seeding a structure converts "sometime in the next
week" into "now".

Gated on `WANDERER_SCOUT_ASSET_SAFETY`, independent of every other scout flag.

### The scope is the whole opt-in, and it can only be granted at login

`GET /characters/{id}/notifications/` needs `esi-characters.read_notifications.v1`,
and **EVE SSO only grants what was requested**: a refresh never widens an
existing token. So every character has to log in once after the flag goes on.
`/scout`'s **Watch notifications** button does exactly that — it mints the
short-lived invite token `/auth/eve` demands on an invite-only deployment (a
plain link there is dead; same trap `CorpManagementLive` documents) and sends
the browser to SSO.

With the flag off, `config/runtime.exs` appends nothing and all four scope
strings are byte-identical to upstream's.

`WandererApp.Scout.AssetSafety.watching_characters/0` is a **filter, not a
try-and-see**: it polls only characters whose stored `scopes` column actually
carries the scope. Polling everyone would 403 for every pre-existing character
on the deployment, every ten minutes, against ESI's error budget. One trap
found doing this: `access_token` is **AshCloak-encrypted at rest**, so a SQL
predicate on it matches nothing and takes the whole read with it — the filter
is on `scopes` alone, and a dead token surfaces as the feed's own `:stalled`.

### It rides the Phase 2 sync framework

`WandererApp.Sync.Feeds.AssetSafetyFeed` is one scope **per character** (the
corp roster feed is one per corp, because a director token answers for a whole
corp; this notification is delivered to an individual pilot and nothing can
read it for them). Each character therefore gets its own `sync_runs_v1` row,
its own ETag, its own backoff and its own `:stalled` verdict — which is the
granularity a revoked consent needs. Cadence is **600s**, the endpoint's own
ESI cache — and also what its rate-limit budget allows.

### A rate-limited poll used to crash the scheduler

Measured 2026-10-11, after a structure in **Eurgrana** fired
`StructureItemsMovedToSafety` in game and this app never showed it. Two
defects, compounding:

1. The feed polled at **60s**, not the 600s this document already claimed.
   ESI meters per-endpoint **rate-limit groups**, and this endpoint's is
   `char-notification` at **15 requests / 15 minutes**
   (`x-ratelimit-group` / `x-ratelimit-limit` on the 429). A 60s cadence
   spends exactly that, with zero headroom. A `304` is still a request
   against this limit — threading the ETag protects the ERROR limit, not
   this one.
2. `api_client.ex` answers a 420/429 with the three-tuple
   `{:error, :error_limited, headers}`, and `WandererApp.Sync.Scheduler`'s
   `dispatch!/3` had no clause for it. Every rate-limited fetch raised
   `CaseClauseError` into the rescue, which logged and returned **without
   writing the heartbeat row** — so `next_run_at` stayed in the past,
   `due?/1` stayed true, and the scope was re-dispatched on every 30s tick.
   One 429 therefore became a permanent 2-requests-per-minute loop that
   kept the feed limited: `last_success_at` froze at 07:16 and five hours
   of notifications were never read, while `status` still said `:ok`.

The fix is both halves: cadence 600s, and the scheduler now treats
`:error_limited` as a backoff of `retry-after` floored at the feed's own
cadence, records the group and the limit in `last_error`, and stalls the
scope after five consecutive ones. Any unrecognised fetch result is an
error rather than a raise, and a raise now advances `next_run_at` too — a
heartbeat row that is never written is a hot loop with nothing to read.
Regression: `test/integration/sync_scheduler_test.exs`.

### Three wire traps, all load-bearing

The notification body is flat YAML and is parsed **line-wise** — this app has
no YAML dependency and a notification is not worth one. Only scalar
`key: value` lines are read, list items (`- showinfo`) are dropped, and the
split is on the FIRST colon so `structureLink`'s HTML survives intact.

1. **Keys are matched case-insensitively.** Published field lists disagree
   about case (`StructureID` in the Go bindings' struct names, `structureID`
   on the wire), and a trigger that silently stops firing because CCP changed
   a capital is the worst failure this feature has.
2. **The in-body timestamps are Windows FILETIME** — 100-nanosecond intervals
   since **1601-01-01**, not unix seconds and *not* the .NET year-1 ticks the
   field is usually mislabelled with. Read the year-1 way, a real value lands
   in the year 423 and the whole row is discarded. (The notification's own
   `timestamp` field is ordinary ISO8601; only the asset-safety deadlines are
   ticks.) `to_datetime/1` accepts either form by magnitude and refuses
   anything outside 2003..2100.
3. **The body uses YAML anchors, and that one defect made the feature
   fire zero times.** EVE writes the structure id once with an anchor and
   refers back to it from the list below:

   ```yaml
   structureID: &id001 1042709327956
   structureShowInfoData:
   - showinfo
   - 35832
   - *id001
   ```

   Read line-wise without resolving that, `structureID` is the string
   `"&id001 1042709327956"`, which is not an integer — so every single
   `StructureItemsMovedToSafety` was skipped, by the same `:skip` that
   drops 48 mining-ledger rows, and nothing said so. Measured 2026-10-11
   on live ESI: **36 of 36** notifications across five characters,
   including the Eurgrana hull that started the investigation.
   `parse_text/1` now strips an anchor from the value it decorates,
   remembers it, and resolves a bare `*alias`. The test fixture carried
   no anchor until that day, which is exactly why the suite was green
   while production parsed nothing — it now mirrors the live body.

### Half the feature is knowing which hulls are NOT armed

The trigger only fires for a structure somebody put an item into. So an
unseeded hull finishes unanchoring in **silence**, and on every other board it
looks exactly like one that will report the instant it pops. That is a
watchlist lying by omission, and it is the one failure a reader cannot find by
looking harder.

So the Unanchoring board carries a **Trigger** column (`armed` / `seed it`,
`ScoutComponents.armed_cell/1`) and there is a **Needs seeding** board —
the same rows, the same 7-day predicted bound, minus the ones already armed —
with its own summary card and its own Discord paste (`📥 Unanchoring, nothing
seeded`), because it is an errand list, not a finding.

"Armed" is **read from ESI, never ticked by hand**:
`GET /characters/{id}/assets/` reports an item's `location_id`, and an item
inside an Upwell structure carries that structure's id, so armed is the join
`location_id == structure_id` against `WandererApp.Api.ScoutAssetLocation`.
A checkbox would be wrong the day somebody hauls the item back out, and nobody
would ever notice. For the same reason the table is **latest-wins with
deletes**: `WandererApp.Sync.Feeds.AssetLocationsFeed` destroys every row a
poll did not see.

Four things about that feed:

- It stores an **id, not an inventory** — no type, no quantity, no flag. It is
  a membership set, and keeping anyone's hangar contents would be a privacy
  cost with no reader. Ids below 10^12 (NPC stations, solar systems) are
  dropped; above it the set also holds ships and containers, which is harmless
  because lookups are always keyed on a `structure_id` the sweep reported and
  EVE item ids are globally unique.
- **Paging is the implementation.** ESI serves 1000 assets per page, so it
  walks until a page comes back short, capped at 20 pages and logged when it
  hits that. The ETag is threaded on page 1 only: an untouched hangar costs one
  conditional request instead of a full walk.
- Cadence 3600s, the endpoint's own cache.
- **It shares `WANDERER_SCOUT_ASSET_SAFETY` with the notification feed, and
  one consent.** The scope string carries both
  `esi-characters.read_notifications.v1` and `esi-assets.read_assets.v1`,
  because shipping the trigger without the arming check is the omission above.

What it gets wrong, and in which direction: a hull seeded by a character this
app does not track reads as **not armed**. The cost is dropping a second item.
The opposite error — claiming armed when nothing will ever report — is the
failure this exists to remove, so the bias is deliberate. `armed_cell/1` names
who armed it, which is how a reader tells a real arming from a stale one.

### How it renders

A banner on **both** tabs, above the unanchored one, plus its own board and
its own summary card on the structures tab, and its own Discord board
(`💣 Asset safety fired`, first in the digest). Horizon is 7 days — `Alerts`'
horizon, not the window selector — and the sidebar badge counts these next to
unanchored hulls, because to a reader they mean the same thing.

Four deliberate shapes:

- **It is not folded into `Now`.** These rows are an event, not a structure's
  current state: no `last_confirmed_at`, no `presence`, no `status` to put in
  that table's columns.
- **It can report a structure no sweep has ever visited**, which is why a row
  may show a bare `structure_id` where every other board shows a name.
  `structure_name`/`group_name`/`owner_name`/`nearest_celestial` are copied off
  the matching `ScoutStructure` row at ingest when there is one, and
  `group_name` otherwise falls back to the structure TYPE name; they are a
  snapshot, never refreshed.
- **Two characters' notifications about one hull are one finding.** Reads fold
  `DISTINCT ON (structure_id)`, the same trick the spawns tab uses; writes are
  idempotent on `notification_id`, because ESI re-serves the same ~50
  notifications on every poll forever.
- **A reader can dismiss one** (`✕`, `dismiss_asset_safety`), and the
  dismissal is keyed on the **structure**, not on the notification clicked:
  the board folds `DISTINCT ON (structure_id)`, so dismissing the folded row
  alone would just promote its sibling and the hull would never leave.
  `WandererApp.Scout.AssetSafety.dismiss/2` writes `dismissed_at` on every row
  for that structure; `recent/1` (and therefore the banner, the summary card
  and the sidebar badge) filters them out, and they move to a **Dismissed
  asset safety** board — rendered only when non-empty, deliberately NOT
  window-bounded, with `↺` to undo. Unlike `ScoutStructure`'s archive it never
  expires on its own: nothing can contradict a notification, so there is no
  later fact that should bring the row back. It is never a delete — the row
  stays in the table, in the retention purge's reach and in the history.

The board says **who is watching** in its own footer (`panel/1`'s `note` slot,
`watcher_note/1`): an empty board because nobody consented and an empty board
because nothing unanchored look identical, and only one of them is a bug the
reader can fix. It is a footer rather than a sibling `<div>` so it survives the
board being collapsed or empty, which is the only state it ever matters in.

## Files

|What|Where|
|---|---|
|Ingest + coercion|`lib/wanderer_app/scout/ingest.ex`|
|Status families (`unanchored_family/0`, `anchoring_family/0`, ...)|`lib/wanderer_app/scout/status.ex`|
|Unanchored alert (reads + cached badge count)|`lib/wanderer_app/scout/alerts.ex`|
|Decommission bound + how a run ended (`outcome/2`, `transition/4`)|`lib/wanderer_app/scout/unanchor.ex`|
|Aggregates (group-by, freshness, totals)|`lib/wanderer_app/scout/stats.ex`|
|Space-type filter (class subquery)|`lib/wanderer_app/scout/space.ex`|
|Resources|`lib/wanderer_app/api/scout_{spawn,structure}_sighting.ex`|
|Ingest controller|`lib/wanderer_app_web/controllers/scout_intel_api_controller.ex`|
|CSV export|`lib/wanderer_app_web/controllers/scout_export_controller.ex`|
|Flag plug|`lib/wanderer_app_web/controllers/plugs/check_scout_intel_disabled.ex`|
|Permission tier|`lib/wanderer_app/identity/scout_access.ex`|
|Pages (shell + access)|`lib/wanderer_app_web/live/scout/scout_{intel,access}_live.ex`|
|Planner, as a nested child of the shell|`lib/wanderer_app_web/live/scout/scout_planner_live.ex`|
|Page shell (header, tab strip, toolbar, pane), panels, cells, formatters|`lib/wanderer_app_web/components/scout_components.ex`|
|Panel order + collapsed set (per page, localStorage)|`lib/wanderer_app_web/live/scout/scout_layout.ex`, `assets/js/hooks/scoutPanelStack.ts`|
|Per-column sort/filter (spec, state, apply)|`lib/wanderer_app_web/scout_table.ex`|
|Column specs per table|`lib/wanderer_app_web/live/scout/scout_{intel,planner}_columns.ex`|
|Asset-safety trigger (parse, reads, watchers)|`lib/wanderer_app/scout/asset_safety.ex`|
|Asset-safety notification feed|`lib/wanderer_app/sync/feeds/asset_safety_feed.ex`|
|Asset-safety resource|`lib/wanderer_app/api/scout_asset_safety.ex`|
|Armed check (ESI assets join)|`lib/wanderer_app/scout/seeding.ex`|
|Asset locations feed|`lib/wanderer_app/sync/feeds/asset_locations_feed.ex`|
|Asset location resource|`lib/wanderer_app/api/scout_asset_location.ex`|
|Discord message format|`lib/wanderer_app_web/components/scout_discord.ex`|
|Waypoint push wording (shared with the planner)|`lib/wanderer_app_web/scout_waypoint.ex`|
|Sidebar entry|`lib/wanderer_app_web/components/scout_nav.ex`|
|Tests|`test/integration/scout_intel_test.exs`, `test/integration/scout_{intel,planner}_live_test.exs`, `test/integration/scout_table_live_test.exs`, `test/unit/scout/scout_table_test.exs`|

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
