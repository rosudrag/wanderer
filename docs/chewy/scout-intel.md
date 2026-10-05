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
dead_family/0       : Abandoned, NoFuel
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
|`:abandoned`|`status in Status.dead_family()`|

All four feed a dedicated `/scout` structures-tab table, latest sighting
per `structure_id` — the same `Ash.Query.distinct([:structure_id]) |>
Ash.Query.distinct_sort(observed_at: :desc)` fold the ingest log applies on
top of `:search`:

- **Unanchored** — floating undeployed. See "The unanchored alert".
- **Anchoring** — no fitting, no services, a live vulnerability window: the
  cheapest kills in the game.
- **Unanchoring** — a structure being pulled out of the ground: a one-shot
  opportunity with a hard deadline nobody reports. See "Predicted max out".
- **Abandoned** — asset safety off (`Abandoned`) or unfuelled (`NoFuel`).
  Neither carries a timer, so neither can appear in the timer table, and
  before this board both were visible only as one muted row somewhere in the
  flat log.

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

- A status leaving the family **clears** the anchor. A cancelled
  decommission restarts the 7 days, so a surviving anchor would
  under-predict — the one error direction that makes the column dangerous.
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

## The page

`/scout` is two tabs over the same two tables, and one `WANDERER_SCOUT_INTEL`
flag covers all of it.

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
|`sys/1`|Name, then **one** qualifier: the class title in w-space and Pochven, the security status everywhere else. `map_solar_system_v2` titles nullsec `0.0` and lowsec `L`, so showing both rendered `1DQ1-A 0.0 -0.4` and `J110145 C5 -1.0`. Falls back to the static map's `security` when the client logged no truesec|
|`status/1`|Coloured by family, and **quiet** for the steady tier: when every row shouts, the reinforced one stops standing out|
|`seen/1`, `countdown_cell/1`|Age first (what you act on), timestamp under it (what you paste in fleet chat)|
|`empty/1`|One empty state, so every table says nothing the same way|

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

### The filters are sticky

Tab, window, search and space selection survive a reload, a new tab and a
browser restart. They live in **localStorage**, not on the server: a
per-user server cache would be wiped by every deploy, and on this fork that
is often. No JavaScript was written for it — upstream's generic
`LocalStorageSetting` hook (`assets/js/hooks/localStorageSetting.ts`) pushes
`ls_restore_<key>` once on mount and listens for `ls_update_<key>`, so the
page mounts a hidden `#scout-filter-store` div and the LiveView answers
`"ls_restore_scout_filters"` / emits `"ls_update_scout_filters"` after every
filter event.

localStorage is user-writable, so every restored field is validated exactly
as a click on the same control would be: an unknown window keeps the
default, a `tab` that is not an existing atom never reaches
`String.to_existing_atom/1`, the search is truncated, and a non-empty space
list that parses to nothing falls back to every bucket rather than
rendering a blank page. An explicitly empty space list IS restored — every
chip unticked is a state a reader can choose.

`limit` is deliberately not persisted: "Load more" is about the page you are
on, not about how you like to read the log.

### The space filter

Six chips — High, Low, Null, W-Space, Pochven, Other — all on by default,
each one click to drop. "Everything except highsec" is the filter the page
exists for, so it is one click and it holds across tab switches.

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
**Copy for Discord** for the whole tab. Both open one modal holding a
preformatted message; a `CopyToClipboard` button puts it on the clipboard and
the reader pastes it into a channel. Nothing is posted from the server: there
is no webhook, no stored URL and no outbound call, so the feature cannot leak
intel to a channel nobody remembered configuring.

`WandererAppWeb.ScoutDiscord` owns the format. It reads the rows the socket
**already holds**, which is what makes the paste match the screen — same
window, same search, same system chip, same space chips, same sort.

Three things decide the format:

- **Discord's own timestamp markup is the whole point.** `<t:1760000000:R>`
  renders as a live relative countdown and `<t:…:f>` as an absolute instant,
  both in each *reader's* timezone and re-rendered on every view. A timer
  board pasted once keeps counting down in the channel; our own "2h 14m" would
  be wrong by the time anyone read it, and "22:41" is wrong for everyone not on
  UTC. Boards with a deadline emit both styles (the countdown is what a reader
  acts on, the instant is what a fleet forms on); boards without one emit the
  relative "seen" time only.
- **2000 characters, and Discord rejects an over-long message rather than
  cutting it.** Each board is fitted to the budget and, when rows are dropped,
  says so in the message itself — "_… 37 more not shown_" — because a reader
  cannot otherwise tell a quiet night from a truncated list. The digest shares
  the budget **fairly with carry-forward** (`remaining / boards left`, unused
  room rolls to the next board) rather than greedily: greedy filling let a
  50-row Unanchored board eat the whole message and leave the timers out.
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

## Files

|What|Where|
|---|---|
|Ingest + coercion|`lib/wanderer_app/scout/ingest.ex`|
|Status families (`unanchored_family/0`, `anchoring_family/0`, ...)|`lib/wanderer_app/scout/status.ex`|
|Unanchored alert (reads + cached badge count)|`lib/wanderer_app/scout/alerts.ex`|
|Aggregates (group-by, freshness, totals)|`lib/wanderer_app/scout/stats.ex`|
|Space-type filter (class subquery)|`lib/wanderer_app/scout/space.ex`|
|Resources|`lib/wanderer_app/api/scout_{spawn,structure}_sighting.ex`|
|Ingest controller|`lib/wanderer_app_web/controllers/scout_intel_api_controller.ex`|
|CSV export|`lib/wanderer_app_web/controllers/scout_export_controller.ex`|
|Flag plug|`lib/wanderer_app_web/controllers/plugs/check_scout_intel_disabled.ex`|
|Permission tier|`lib/wanderer_app/identity/scout_access.ex`|
|Pages|`lib/wanderer_app_web/live/scout/scout_{intel,access}_live.ex`|
|Panels, cells, formatters|`lib/wanderer_app_web/components/scout_components.ex`|
|Discord message format|`lib/wanderer_app_web/components/scout_discord.ex`|
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
