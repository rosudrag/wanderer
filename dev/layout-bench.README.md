# layout-bench

Deterministic quality + stability benchmark for the map-beautifier layout
engine (`assets/js/hooks/Mapper/components/map/layout`). This is the
measuring instrument the improvement work is judged against — it does not
change the engine itself.

## Running it

```sh
node dev/layout-bench.mjs
```

Plain Node, no install step, no Bun. See the comment block at the top of
`dev/layout-bench.mjs` for exactly how it loads the engine's `.ts` sources
without a build step (native Node TypeScript stripping, falling back to a
resolvable `typescript` package, else it fails loudly with the fix).

Flags:

| flag | effect |
|---|---|
| `--scenario <name>` | run only one of `yugen`, `chain`, `kspace-wide`, `mixed`, `occlusion` |
| `--json <path>` | write the full structured result (every metric, every k, every scenario) to `<path>` |
| `--compare <baseline.json>` | diff the current run against a prior `--json` output; prints a delta table and **exits 1** if anything regressed beyond tolerance |

Typical workflow when changing the engine:

```sh
node dev/layout-bench.mjs --json /tmp/before.json      # on main
# ...make changes...
node dev/layout-bench.mjs --json /tmp/after.json --compare /tmp/before.json
```

## Scenarios

- **yugen** — the real 15-system / 17-connection map from
  `lib/wanderer_app/dev/seed.ex`'s `@systems`/`@connections`, parsed out of
  that file at benchmark run time (not copied) so the two can never drift.
- **chain** — a synthetic wormhole chain: a root with three branches (depth
  4, 2, 3), one non-tree "K162" loop-back edge, and one direct k-space exit
  (a highsec-classed leaf hanging off the root).
- **kspace-wide** — 40 real k-space systems, three ~13-14 system clusters
  anchored at Jita (The Forge), Amarr (Domain) and Rens (Heimatar), all ids
  and relative positions read from
  `assets/js/hooks/Mapper/components/map/layout/data/regionLayouts.json`.
  Within each cluster, gates are a minimum-spanning tree over the real
  lattice cells (i.e. literally "connect nearest neighbours") plus two short
  redundant edges; the three clusters are bridged pairwise so the whole
  thing is one connected component, same as adjacent regions in-game.
- **mixed** — `kspace-wide` plus a 10-node wormhole chain hanging off one of
  its systems.
- **occlusion** — regression fixture for the edge-overlap/node-occlusion
  rules below. Four real systems, ids/positions/connection types copied
  verbatim from a real production database row on map `yugen` (a live user
  map — unrelated to the `yugen` *scenario* above, which is `seed.ex`
  dev-seed data): `Ibani` (`30003933`, `-540,675`), `Raihbaka` (`30045315`,
  `-360,675`) and `Irmalin` (`30003935`, `-180,675`) all on the same row,
  plus `Timudan` (`30003932`, `-540,600`) one cell north of `Ibani`.
  Connections: `Irmalin -> Ibani` (gate), `Ibani -> Raihbaka` (wormhole),
  `Ibani -> Timudan` (gate). In this real layout the `Ibani -> Raihbaka`
  wormhole lies entirely inside the `Irmalin -> Ibani` gate segment, and
  `Raihbaka`'s own node sits exactly on that gate segment's midpoint — both
  rules below are violated at once by input that already passed every
  other quality check (it's grid-aligned, has zero `crossings` because the
  offending pair shares the `Ibani` endpoint, and has zero `overlaps`
  because no two nodes share a pixel). A correct engine must resolve both
  to `0`; this scenario exists specifically to fail loudly until it does.

## Quality metrics (computed once per scenario, on `P1` — the from-scratch beautify)

"Final positions" = every input node's `(x, y)`, overridden by whatever
`beautifyLayout` returned for the nodes it actually moved (locked nodes and
nodes that didn't need to move keep their input position — this mirrors
exactly what the engine's own contract promises).

- **crossings** — number of edge pairs that properly intersect (including
  collinear overlap), ignoring any pair that shares an endpoint node.
- **overlaps** — node pairs occupying the exact same pixel position. Must
  always be 0; a nonzero value is treated as a hard failure independent of
  any `--compare` baseline.
- **spanCols / spanRows** — bounding box of the final layout, in grid cells.
- **gateEdgeCells / wormholeEdgeCells** (`mean`/`max`) — edge length in grid
  cells (Euclidean distance in `(col, row)` space), reported separately for
  gate (`type === 1`) and wormhole (`type === 0`) edges.
- **offGrid** — count of final positions that aren't an exact multiple of
  `CELL_W`/`CELL_H`. Must always be 0; same hard-failure treatment as
  `overlaps`.
- **edgeOverlapPairs** — unordered edge pairs whose segments are
  **collinear** (same line, not merely crossing) and share a
  **positive-length stretch** of that line, worked out in CELL space
  (`col = x / CELL_W`, `row = y / CELL_H`) rather than pixels. Two edges
  meeting at a shared node endpoint at an *angle* project to zero-length
  overlap on the shared line and are fine (that's an ordinary fan-out, not
  a hidden connection); two edges sharing that endpoint but continuing
  **in the same direction past it** — like the fixture below, where
  `Ibani -> Raihbaka` continues in the same direction as `Irmalin ->
  Ibani` past their shared `Ibani` endpoint — share more than that single
  point and count. A duplicate edge between the same two nodes is the
  degenerate case of "one edge is a subset of the other": it shares its
  *entire* length and always counts as a full overlap. Zero-length edges
  (both endpoints landing on the same cell) are excluded from both rules
  below entirely — a point can't have a "positive-length stretch" with
  anything. Must always be `0`; same hard-failure treatment as `overlaps`.
- **nodeOcclusions** — nodes whose **rendered box** (130x34px, the size the
  map actually draws a system at) is crossed by an edge they are not one of
  the endpoints of, in CELL space. Being an endpoint doesn't count (that's
  just another edge legitimately ending at that node); anything else does,
  gate or wormhole, regardless of whether that node is also connected to one
  of the edge's endpoints by some other edge. Must always be `0`; same
  hard-failure treatment as `overlaps`.

  This rule used to be "the node's CENTRE lies strictly between the edge's
  endpoints", which only fires when a node lands exactly on the line.
  Measured on the live production map `yugen` (2026-09-25, 32 systems): that
  rule reported **zero** occlusions while **six** connections ran under a
  foreign node box — `Toon` swallowing 102px of `Auga -> Siseide` and 62px of
  `Dal -> Amamake`, `Dal` 43px of `Auga -> Kourmonen`. `DotlanEdge` draws one
  straight centre-to-centre line clipped only to the two ENDPOINT boxes, so
  every one of those is a link the user genuinely cannot see. The engine
  (`layout/geometry.ts`, shared by `anchor.ts` and `pack.ts`) and this
  benchmark now use the same box test; the old centre rule is a strict subset
  of it, so nothing it caught is lost.

  Tightening it costs crossings, by design — hiding a link is weighted far
  above crossing one (`pack.ts`, 1000:1). On the same code, old rule vs new:
  `yugen` went from 4 hidden links / 0 crossings / 47.0 cells of edge to
  **0 hidden links** / 4 crossings / 43.8 cells, and `occlusion` from 6 / 5 /
  90.1 to **0** / 6 / 84.4. Both scenarios come out with shorter total edge.
- **totalEdgeCells** (`edgeLen` column) — total drawn edge length in cells.
  Not a pass/fail gate; it is the repair pass's tie-breaker
  (`pack.ts` `candidateCompare`), so it is tracked to catch "cleared an
  occlusion by flinging a node across the map".
- **determinism** — the scenario is laid out twice from identical input;
  `true` iff the two `JSON.stringify`d results are byte-identical. A `false`
  here is also a hard failure.
- **idempotent** — `P1`'s own output is fed straight back in, unchanged, as
  a second beautify call with default options (`mode: 'auto'`); the
  `movedFraction` of that call must be exactly `0` (pressing "beautify" on
  an untouched, already-tidy map must move nothing). Same hard-failure
  treatment as `overlaps`/`offGrid`/`determinism`.

## Stability metrics (the actual point of the exercise)

`P1` = a from-scratch beautify of the raw scenario (`mode: 'auto'`, which
always and correctly resolves `'full'` for raw, never-laid-out scenario
coordinates — there is nothing "already tidy" about them yet).

For each scenario, for `k` in `[1, 3, 5]`, repeated 10 times with a seeded
`mulberry32` PRNG, **two independent measurements are taken**:

### Round-trip (`stability.roundTrip` — THE number this work is judged on)

This is the thing the user actually does: *I have a tidy map, I add a
system, I press beautify again.* It is also the only scenario that can ever
exercise `BeautifyOptions.mode: 'incremental'` — `'auto'` decides based on
the *input* positions, and only a map that already looks laid out can
trigger it.

1. Take `P1`'s own OUTPUT positions and apply them to the existing nodes —
   exactly what the app does: the server persists what `P1` returned, the
   client re-reads it as the new "current position" of every system.
2. Attach `k` new, still-unbeautified systems to `k` randomly-chosen
   *existing* nodes (seed = FNV-1a hash of
   `"<scenario>:<k>:<repeatIndex>:roundtrip"`). If the chosen base node
   resolves to a real system in `regionLayouts.json`, the new node is that
   base's nearest not-yet-used real neighbour on the lattice (gate edge,
   type 1) — this is how "yugen" and "kspace-wide" grow. Otherwise (a
   synthetic chain node) the new node extends that branch one hop further
   (wormhole edge, type 0, random class 1-6) — this is how "chain" grows,
   and how "mixed"'s attached chain grows. Every new node gets a small
   deterministic pixel jitter off its parent as a stand-in "just dropped it
   near the discovery" position — i.e. it deliberately does NOT look
   already-laid-out.
3. Beautify the enlarged graph with default options (`mode: 'auto'`) →
   `P2`. The mode the engine actually resolved (`'incremental'` or
   `'full'`) is recorded per repeat.
4. Over the *original* scenario's nodes only (never the `k` new ones):
   - **movedFraction** — share whose position changed at all between `P1`
     and `P2`.
   - **meanShiftCells / maxShiftCells** — displacement between `P1` and
     `P2`, in cells (`hypot(dCol, dRow)`).
   - **rankInversions** — number of node pairs whose left/right (`x`) or
     above/below (`y`) relative order flipped between `P1` and `P2`. This
     is what catches "the map got reshuffled" even when every individual
     displacement is small.
   - **incremental%** — share of the 10 repeats that resolved `'incremental'`
     rather than `'full'`. A scenario silently falling back to `'full'`
     must be visible here, not inferred from the shift numbers alone.

   And over the `k` NEWLY ADDED nodes themselves (this is where a placement
   defect can hide behind a perfect score above — see the yugen/`30002538`
   incident that motivated these three metrics: a real k-space system,
   gate-attached to an already-placed neighbour, left at its exact raw drop
   coordinates, off-grid, far from the rest of the map, while every metric
   above still read a clean `0`):
   - **newOffGrid** — count, summed over all 10 repeats, of newly added
     nodes whose final position is not an exact multiple of
     `CELL_W`/`CELL_H`. Hard invariant, same treatment as `overlaps`/
     `offGrid`: must always be `0`, independent of `--compare` tolerance.
   - **newUnplaced** — count, summed over all 10 repeats, of newly added
     nodes whose final position is byte-identical to their raw drop
     position, i.e. the engine left them exactly where they fell instead
     of placing them at all. Same hard-invariant treatment as `newOffGrid`.
   - **newAnchorCells** (`mean`/`max`) — grid distance from each newly
     added node's final position to the final position of the
     already-placed graph neighbour it was attached to (every synthetic
     new node has exactly one edge, to the pre-existing node it grew
     from). A newly added system should land NEXT to what it connects to;
     pooled over every new node across all 10 repeats. Not a hard
     invariant — judged against a threshold in the verdict table below.

   And over the *whole* post-insertion graph (existing nodes/edges plus
   the `k` new ones), the same two rules as the QUALITY section above,
   re-checked because inserting new nodes/edges must not create a new
   violation even when `P1` itself was clean — the exact defect class
   that motivated these two metrics: a wormhole edge to a newly-added
   system lying entirely inside an existing gate edge, or a newly-added
   node landing exactly on top of an existing connection:
   - **edgeOverlapPairs** — count, summed over all 10 repeats, of edge
     pairs in `P2` that collinear-overlap (see the QUALITY definition
     above). Hard invariant, same treatment as `newOffGrid`: must always
     be `0`, independent of `--compare` tolerance.
   - **nodeOcclusions** — count, summed over all 10 repeats, of nodes in
     `P2` sitting strictly on an edge they aren't an endpoint of. Same
     hard-invariant treatment as `edgeOverlapPairs`.

A nonzero round-trip `movedFraction`/`rankInversions` while `mode` reads
`'incremental'` is NOT a harness bug: `classifyNodes`/`placeIncrementalNodes`
can legitimately re-place a handful of existing k-space members when a new
lattice-neighbour's insertion causes a genuine cell collision — that is
real engine behaviour this measurement is specifically designed to surface.

### Cold (`stability.cold` — still meaningful, NOT the primary number)

The original measurement, renamed honestly: attach `k` new systems (same
construction as above, seed = `"<scenario>:<k>:<repeatIndex>"`, no
`:roundtrip` suffix) to the **raw**, never-beautified scenario nodes, then
beautify with default options. `'auto'` always resolves `'full'` here —
raw scenario coordinates never look laid out — so this measures "what does
a full re-solve of a slightly bigger messy map cost", which is a real cost
worth tracking but is NOT "beautify after adding one system to a tidy map".
Same four metrics as round-trip, minus the mode column (it is always
`'full'` by construction) and minus the new-node placement metrics
(`newOffGrid`/`newUnplaced`/`newAnchorCells` are round-trip-only: cold's
new nodes are added to a never-laid-out map, so "landed near its
already-placed neighbour" isn't a meaningful question there) and minus
`edgeOverlapPairs`/`nodeOcclusions` (also round-trip-only, for the same
reason: cold's `P1` reference doesn't correspond to a tidy map the user
ever actually saw, so "did adding a system break it" isn't a meaningful
question there either — QUALITY already checks the raw beautify for both
rules).

The printed/JSON stability numbers are the mean over the 10 repeats (plus
`max` for `rankInversions`, since one bad repeat matters even if the
average looks fine).

## Round-trip stability verdict

Printed as its own table: for each scenario, the **worst** (`max`) value
over `k = 1, 3, 5` of each round-trip metric is checked against:

| check | threshold |
|---|---|
| `movedFrac` | `<= 0.15` |
| `meanShift` | `<= 0.5` cells |
| `rankInv(mean)` | `<= 2` |
| `idempotent movedFrac` | `== 0` |
| `newOffGrid` (summed over 10 repeats) | `== 0` |
| `newUnplaced` (summed over 10 repeats) | `== 0` |
| `newAnchorCells mean` / `max` | `<= 2.0` / `<= 4` cells |
| `edgeOverlapPairs` (summed over 10 repeats) | `== 0` |
| `nodeOcclusions` (summed over 10 repeats) | `== 0` |

A scenario `PASS`es only if all nine hold. This is the pass/fail line the
whole effort is judged against, independent of `--compare`/tolerances.

## `--compare` tolerances

Every "lower is better" metric is compared as
`current - baseline > max(abs, baseline * rel)`; every "higher is better"
metric (currently only `stability.roundTrip.incrementalShare`) flips the
direction: `baseline - current > max(abs, baseline * rel)`.

| metric | rel | abs |
|---|---|---|
| `crossings` | 0 | 0 (any increase regresses) |
| `spanCols` / `spanRows` | 5% | 1 cell |
| `gateEdgeCells.mean` / `wormholeEdgeCells.mean` | 5% | 0.05 cells |
| `gateEdgeCells.max` / `wormholeEdgeCells.max` | 5% | 0.1 cells |
| `stability.roundTrip.movedFraction` (per k) | 5% | 0.03 |
| `stability.roundTrip.meanShiftCells` (per k) | 5% | 0.05 cells |
| `stability.roundTrip.maxShiftCells` (per k) | 5% | 0.1 cells |
| `stability.roundTrip.rankInversions` (per k) | 5% | 1 pair |
| `stability.roundTrip.incrementalShare` (per k, **higher is better**) | 5% | 0.05 |
| `stability.roundTrip.newAnchorCells.mean` (per k) | 5% | 0.1 cells |
| `stability.roundTrip.newAnchorCells.max` (per k) | 5% | 0.2 cells |
| `stability.cold.movedFraction` (per k) | 5% | 0.03 |
| `stability.cold.meanShiftCells` (per k) | 5% | 0.05 cells |
| `stability.cold.maxShiftCells` (per k) | 5% | 0.1 cells |
| `stability.cold.rankInversions` (per k) | 5% | 1 pair |

`overlaps`, `offGrid`, `determinism`, `idempotent.movedFraction`,
`edgeOverlapPairs`, `nodeOcclusions`, and (per k)
`stability.roundTrip.newOffGrid`/`stability.roundTrip.newUnplaced`/
`stability.roundTrip.edgeOverlapPairs`/`stability.roundTrip.nodeOcclusions`
are hard invariants: any violation in the *current* run fails the whole
comparison (and even a plain run with no `--compare` at all), independent
of tolerance or baseline. A metric that improved is marked `better`;
anything inside tolerance but not exactly equal is still listed so you can
eyeball drift even when it doesn't fail the build.

The process exit code is `0` only if no hard invariant was violated and (if
`--compare` was given) nothing regressed beyond tolerance.
