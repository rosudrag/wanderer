# assets/scripts

## generate-region-layouts.mjs

Generates `assets/js/hooks/Mapper/components/map/layout/data/regionLayouts.json`,
a precomputed Dotlan-like 2D grid layout (v2 schema, in `CELL_W=180 x
CELL_H=75` px cell units) used by the map beautifier to place k-space systems.

It fetches `mapSolarSystems.csv` and `mapRegions.csv` from the Fuzzwork SDE
CSV dump (the SDE mirror bundled with the app has no `x`/`y`/`z`/`position2D*`
columns) and projects each system from `position2Dx`/`position2Dy` — the
SDE's own pre-baked 2D map projection, i.e. the same coordinates Dotlan-style
region maps are drawn from — instead of approximating one from the raw 3D
`x`/`y`/`z`. Those two columns are quantized onto a regular lattice (empirically
~2.0545e15 units/step, detected at generation time rather than hardcoded);
dividing by that step turns them directly into integer grid cells, with no
further per-region distance-based rescaling needed.

### CHEWY PATCH: one global lattice, not per-region boxes

v1 of this file stored a separate local cell grid *per region* (each
starting at its own `[0,0]`) plus a region `centroid`, and the beautifier
placed a system at `centroid + localCell`. That broke down on real maps in
two ways:

1. Region-local cells and centroids live on completely different scales
   (the centroid was scaled to fit a ~1200-cell target bbox; the local
   cells were native lattice-step integers), so a system's on-screen
   position relative to a gate neighbour in *another* region was
   meaningless. Concretely: Amamake (Heimatar) gate-connects directly to
   Auga, Dal and Siseide (Metropolis), but v1 rendered it at the top of a
   stack of unrelated Metropolis systems, with all three of those gates
   drawn running the full height of the map.
2. Each region box compressed its own empty rows/columns independently, so
   two region boxes ended up at different effective scales — a region
   whose systems happen to share almost the same column (e.g. Metropolis,
   cols 3/5/5/5/5 in v1) collapsed into a single-pixel-wide vertical
   "stick" instead of a readable 2D shape.

v2 fixes both by using **one lattice, shared by every k-space system in
New Eden**, and compressing it exactly once, globally. `col`/`row` are
computed directly against a single global origin (global min
`position2Dx`, global max `position2Dy`), collisions are resolved with one
global deterministic pass (not per region), and the whole lattice is
translated so its global min col/row is `[0,0]`. There is no more
`centroid`, no more per-region `size`, and no more addition step at
render time — `systems[id]` is already the system's final cell.

Cell mapping (global, not per-region):

- `col = round((position2Dx - globalMinX) / stepX)`
- `row = round((globalMaxY - position2Dy) / stepY * (CELL_W / CELL_H))`

Row uses `globalMaxY - position2Dy` (not `position2Dx`'s min-relative form)
because higher `position2Dy` is further *north*, verified against Dotlan's
own rendered SVG for The Forge: Perimeter (lower `position2Dy` than Jita)
sits south of Jita on-screen, New Caldari (higher `position2Dy`) sits north
of it. Subtracting from the global max flips that into "row grows
downward," matching on-screen/SVG coordinates. The `CELL_W / CELL_H = 2.4`
factor corrects for the grid's non-square cells: a lattice step covers the
same physical (pixel) distance on both axes only once the Y term is
stretched by that ratio, since each row is drawn shorter than it is wide.

Collisions (two systems rounding to the same cell) are resolved with a
deterministic spiral search in ascending-`solarSystemID` order, applied
once across *all* k-space systems (not per region), so no two systems in
New Eden share a cell — asserted after the fact by comparing the resolved
cell count to the total system count. The ~1-2% of k-space systems whose
`position2Dx`/`position2Dy` fall off the detected lattice (a handful of
genuine outliers in the SDE data, e.g. C-DHON in Vale of the Silent) are
still placed — they just round to their nearest lattice cell instead of
landing on it exactly. Any k-space system with no `position2D` at all
(none currently; those columns are only empty for the ~3000
wormhole/abyssal systems, which the k-space region filter already
excludes) falls back to a `position2D` value synthesized by
least-squares-fitting an affine transform from that system's `x`/`z` onto
its region's other, known-good `position2D` points.

### Output shape (v2)

```json
{
  "version": 2,
  "generatedAt": "2026-09-25",
  "source": "fuzzwork SDE mapSolarSystems.csv position2Dx/position2Dy",
  "regions": { "10000042": "Metropolis" },
  "systems": { "30002537": [306, 713] }
}
```

`regions` is now just `regionID -> regionName`; per-region grids, `size`
and `centroid` are gone. `systems[solarSystemID] = [col, row]` are GLOBAL
integer cell coordinates on the one shared lattice, with `[0, 0]` at the
global min. `regions`/`systems` keys are emitted sorted ascending
numerically, and the file is minified. Re-running the generator against
unchanged SDE data reproduces byte-identical output.

Re-run with:

```sh
node assets/scripts/generate-region-layouts.mjs
```

The output is committed (not generated at build/runtime) because it depends
on a third-party network fetch and EVE's static universe geometry barely
ever changes — regenerating it is a rare, deliberate, reviewable diff.
