# assets/scripts

## generate-region-layouts.mjs

Generates `assets/js/hooks/Mapper/components/map/layout/data/regionLayouts.json`,
a precomputed 2D grid layout (v3 schema, in `CELL_W=180 x CELL_H=75` px cell
units) used by the map beautifier to place k-space systems.

### Dotlan's own maps, not a synthesized projection

v2 of this file derived every system's position by projecting the SDE's own
`position2Dx`/`position2Dy` columns onto a detected lattice. That worked, but
it threw away something better: [Dotlan](https://evemaps.dotlan.net) already
publishes a hand-tuned, genuinely readable 2D layout for every region — the
same maps EVE players actually navigate by. v3 uses that layout directly
instead of re-deriving one.

The SDE is still fetched (`mapRegions.csv` and `mapSolarSystems.csv` from the
Fuzzwork CSV dump) but only as the authority for **which regions/systems are
k-space** and **which region owns each system**. All _geometry_ — where a
system sits relative to its neighbours — now comes from Dotlan's region SVGs
at `https://evemaps.dotlan.net/svg/<Region_Name>.svg` (spaces become
underscores, e.g. `The_Forge.svg`). Each system is a
`<use id="sys<solarSystemID>" x="…" y="…" … />` element in that region's own
local pixel space; SVG y already grows downward, matching screen/grid
orientation.

### Stitching 70 separate drawings into one frame

Every region SVG is drawn at the same physical scale, so combining two
regions only requires finding the right **translation** between them — no
per-region rescaling. The trick is that a region's SVG isn't just its own
systems: Dotlan also draws a chunk of each neighbouring region's systems for
context (e.g. `Heimatar.svg` includes Kourmonen from The Bleak Lands and
Eszur from Metropolis). Wherever the same system ID appears in two different
regions' SVGs, that's a **stitching anchor**: comparing its local pixel
position in each SVG tells you the translation between those two regions'
frames.

The generator:

1. Fetches and caches all 70 k-space region SVGs (polite: at most 4 requests
   in flight, cached under `<os.tmpdir()>/wanderer-dotlan-svg-cache/` so
   re-runs never re-hit dotlan.net for unchanged regions). A region whose SVG
   404s or parses to zero systems is skipped with a loud `ABORT region "…"`
   line on stderr and reported in the final summary — it does not stop the
   other ~69 from being placed.
2. Builds a graph of regions, with an edge between any two regions whose SVGs
   share at least one system ID.
3. Picks the region with the most total shared systems as the anchor of the
   whole map (placed at a local offset of `[0, 0]`), then walks the graph
   breadth-first. Each newly-reached region's offset is the **median**, over
   every system it shares with something already placed, of
   `(already-placed global position − this region's local position)`. The
   median is robust to the handful of anchors that turn out to be
   schematic/compressed "just for context" icons rather than true-to-scale
   placements (a real, measured effect — some anchors land over 1000px off
   the consensus; see the stitch report below). The **residual** (max
   deviation from the median offset, in Dotlan pixels) is reported per region
   so a bad stitch is visible rather than silent.
4. If a region shares no system anywhere with what's already placed (true in
   EVE today for `UUA-F4`, `J7HZ-F`, `A821-A` and `Pochven` — none of them
   render any foreign-region context, and none of their own systems are
   rendered as context by anyone else), it's placed last: its direction from
   the placed set's centroid is estimated from the SDE's own
   `position2Dx`/`position2Dy` columns (fetched already for this purpose,
   used only for this fallback's direction, never for geometry), and it's
   translated just outside the current global bounding box along that
   direction. This is flagged explicitly in the stderr report.
5. A system's own region always wins: if a system appears in several SVGs
   (its own region's, plus one or more neighbours' context renderings), its
   final position comes only from its own region's rendering, translated by
   that region's offset. Foreign-context appearances are used solely as
   anchors for computing _other_ regions' offsets.

### Pixels to grid cells

Cells are non-square (`CELL_W=180 x CELL_H=75`), so converting Dotlan pixels
to grid cells uses different divisors per axis to keep on-screen shapes
proportional:

```
col = round(x / 15)
row = round(y / 6.25)
```

`15 / 6.25 = 2.4 = CELL_W / CELL_H`: for the same pixel distance on either
axis, `cols * CELL_W` and `rows * CELL_H` come out equal, so a shape drawn on
Dotlan keeps its proportions once rendered through the grid.

Two systems that round to the same cell are resolved deterministically with a
square-spiral search in ascending-`solarSystemID` order (global, across every
placed system, not per region), and every system is asserted to land on a
distinct cell afterward. A nudged system is one drawn somewhere Dotlan did not
put it, so the divisors are a fidelity knob, measured rather than guessed
(agreement = share of system pairs whose east/west and north/south order
matches Dotlan's own SVG, own-region systems only, over 5 sampled regions):

| divisors      | nudged   | Dotlan agreement | 15-system map                  |
| ------------- | -------- | ---------------- | ------------------------------ |
| 30 / 12.5     | 12.4%    | 98.18%           | 14x12 cells, mean edge 4.7     |
| **15 / 6.25** | **3.0%** | **99.35%**       | **14x21 cells, mean edge 6.7** |
| 7.5 / 3.125   | 0.9%     | 99.83%           | 17x21 cells, mean edge 7.6     |

Finer divisors mean fewer systems share a column, so the engine's rank-based
compression spreads the map out more. 15 / 6.25 is the chosen balance.

Finally the whole grid is translated so the global minimum col/row is
`[0, 0]`.

### Output shape (v3)

```json
{
  "version": 3,
  "generatedAt": "2026-09-25",
  "source": "evemaps.dotlan.net region SVGs, stitched into one global frame",
  "regions": { "10000030": "Heimatar" },
  "systems": { "30002537": [93, 675] }
}
```

Same shape as v2: `regions` is `regionID -> regionName`, `systems[solarSystemID]
= [col, row]` are GLOBAL integer cell coordinates with `[0, 0]` at the global
minimum, keys are emitted sorted ascending numerically, and the file is
minified. The frontend needs no changes to consume this — it's the same
`{version, generatedAt, source, regions, systems}` shape as before, just
`version: 3` and Dotlan-sourced coordinates.

Re-running the generator against unchanged Dotlan/SDE data (or, more
practically, an unchanged local SVG cache) reproduces byte-identical output —
verified via a `sha256sum` diff across consecutive runs.

Re-run with:

```sh
node assets/scripts/generate-region-layouts.mjs
```

The SVG cache lives outside the repo (`os.tmpdir()/wanderer-dotlan-svg-cache`)
so it never needs a `.gitignore` entry and re-runs against the same cache are
free of network traffic. Delete that directory to force a fresh fetch (e.g.
after Dotlan updates a region's layout).

The output is committed (not generated at build/runtime) because it depends
on a third-party network fetch and EVE's universe geometry barely ever
changes — regenerating it is a rare, deliberate, reviewable diff.
