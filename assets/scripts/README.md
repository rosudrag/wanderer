# assets/scripts

## generate-region-layouts.mjs

Generates `assets/js/hooks/Mapper/components/map/layout/data/regionLayouts.json`,
a precomputed Dotlan-like 2D grid layout (per k-space region, in `CELL_W=180 x
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

Column -> cell mapping, per region:

- `col = round((position2Dx - regionMinX) / stepX)`
- `row = round((regionMaxY - position2Dy) / stepY * (CELL_W / CELL_H))`

Row uses `regionMaxY - position2Dy` (not `position2Dx`'s min-relative form)
because higher `position2Dy` is further *north*, verified against Dotlan's
own rendered SVG for The Forge: Perimeter (lower `position2Dy` than Jita)
sits south of Jita on-screen, New Caldari (higher `position2Dy`) sits north
of it. Subtracting from the region's max flips that into "row grows
downward," matching on-screen/SVG coordinates. The `CELL_W / CELL_H = 2.4`
factor corrects for the grid's non-square cells: a lattice step covers the
same physical (pixel) distance on both axes only once the Y term is
stretched by that ratio, since each row is drawn shorter than it is wide.
The region `centroid` is computed the same way (mean lattice position, sign
and aspect handled identically) so it stays in the same "row grows downward"
space as the per-region local cells it's later summed with.

Collisions (two systems rounding to the same cell) are resolved with a
deterministic spiral search, exactly as before. The ~1-2% of k-space systems
whose `position2Dx`/`position2Dy` fall off the detected lattice (a handful of
genuine outliers in the SDE data, e.g. C-DHON in Vale of the Silent) are still
placed — they just round to their nearest lattice cell instead of landing on
it exactly. Any k-space system with no `position2D` at all (none currently;
those columns are only empty for the ~3000 wormhole/abyssal systems, which
the k-space region filter already excludes) falls back to a `position2D`
value synthesized by least-squares-fitting an affine transform from that
system's `x`/`z` onto its region's other, known-good `position2D` points.

Re-run with:

```sh
node assets/scripts/generate-region-layouts.mjs
```

The output is committed (not generated at build/runtime) because it depends
on a third-party network fetch and EVE's static universe geometry barely
ever changes — regenerating it is a rare, deliberate, reviewable diff.
