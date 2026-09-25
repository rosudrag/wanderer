#!/usr/bin/env node
// Generates assets/js/hooks/Mapper/components/map/layout/data/regionLayouts.json
//
// Precomputes a tidy 2D grid layout for every k-space solar system, grouped by
// region, so the frontend "beautifier" can drop k-space systems into a
// Dotlan-like geographic arrangement without doing any layout math at runtime.
//
// v3 replaces the old SDE-lattice-projection geometry with Dotlan's own
// hand-made region maps (https://evemaps.dotlan.net/svg/<Region>.svg). Someone
// already spent a lot of effort making those maps readable; this script just
// stitches them into one shared grid instead of re-deriving a layout from
// scratch. The SDE is still consulted, but only to answer "which regions and
// systems are k-space, and which region does each system belong to" — all
// geometry (where a system sits, relative to its neighbours) comes from
// Dotlan.
//
// Usage: node assets/scripts/generate-region-layouts.mjs
// (No npm dependencies; uses global fetch, available in Node 18+ and Bun.)

import { writeFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

// NOTE: the SDE mirror path documented casually as
// https://www.fuzzwork.co.uk/dump/latest/mapSolarSystems.csv 404s. The real
// CSV dumps live one level deeper, under /dump/latest/csv/.
const SOLAR_SYSTEMS_URL = 'https://www.fuzzwork.co.uk/dump/latest/csv/mapSolarSystems.csv';
const REGIONS_URL = 'https://www.fuzzwork.co.uk/dump/latest/csv/mapRegions.csv';
const DOTLAN_SVG_BASE = 'https://evemaps.dotlan.net/svg/';

// Dotlan draws every region SVG at the same physical scale, so region-to-
// region stitching is a pure translation (no per-region rescaling needed).
const CELL_W = 180;
const CELL_H = 75;
// col = round(x / COL_DIVISOR), row = round(y / ROW_DIVISOR). The ratio
// COL_DIVISOR/ROW_DIVISOR must equal CELL_W/CELL_H (=2.4) so that a shape
// drawn on Dotlan keeps its proportions once rendered through our
// non-square (180x75) grid cells: physical width covered by `cols` columns
// is cols*CELL_W = (x/COL_DIVISOR)*CELL_W, and physical height covered by
// `rows` rows is rows*CELL_H = (y/ROW_DIVISOR)*CELL_H. Those are equal (for
// equal x, y pixel distances) exactly when COL_DIVISOR/ROW_DIVISOR ===
// CELL_W/CELL_H.
// Halved from 30/12.5 after measuring: the coarser pair forced 12.4% of systems
// off their true cell by collision-nudging, and Dotlan-ordering agreement sat at
// 98.2%. The engine collapses empty runs anyway, so a finer grid costs nothing
// on screen and buys back that fidelity.
const COL_DIVISOR = 15;
const ROW_DIVISOR = 6.25;

// Collisions above this fraction of all placed systems indicate the pixel
// divisors above are too coarse for Dotlan's local system spacing.
const COLLISION_WARN_FRACTION = 0.02;

const KSPACE_MIN_REGION_ID = 10000001;
const KSPACE_MAX_REGION_ID = 10999999;

// Gap (in Dotlan pixel units) left between the current placed bounding box
// and a region that has to be placed via SDE-direction fallback (no shared
// system with anything placed so far).
const ORPHAN_GAP_PX = 200;

// Polite: cache raw SVGs on disk (outside the repo) so re-runs don't
// re-fetch dotlan.net, and never hold more than this many requests open at
// once.
const CACHE_DIR = path.join(os.tmpdir(), 'wanderer-dotlan-svg-cache');
const FETCH_CONCURRENCY = 4;
const USER_AGENT =
  'wanderer-region-layout-generator/3.0 (+https://github.com/wanderer-eve/wanderer; ' +
  'one-off region-layout regeneration script, contact via GitHub issues)';

const OUTPUT_PATH = path.resolve(
  fileURLToPath(import.meta.url),
  '../../js/hooks/Mapper/components/map/layout/data/regionLayouts.json',
);

/** Minimal RFC4180-ish CSV line splitter for fuzzwork's always-quoted dumps. */
function parseCsvLine(line) {
  const fields = [];
  let i = 0;
  const n = line.length;
  while (i < n) {
    let field = '';
    if (line[i] === '"') {
      i++;
      while (i < n) {
        if (line[i] === '"') {
          if (line[i + 1] === '"') {
            field += '"';
            i += 2;
          } else {
            i++;
            break;
          }
        } else {
          field += line[i];
          i++;
        }
      }
    } else {
      while (i < n && line[i] !== ',') {
        field += line[i];
        i++;
      }
    }
    fields.push(field);
    // skip the comma separator
    if (line[i] === ',') i++;
  }
  return fields;
}

function parseCsv(text) {
  // `fetch(...).text()` already strips a leading UTF-8 BOM per the Encoding
  // standard, but strip defensively in case this is ever fed a raw buffer.
  const clean = text.replace(/^\uFEFF/, '');
  const lines = clean.split('\n').filter(l => l.trim().length > 0);
  const header = parseCsvLine(lines[0]);
  const idx = {};
  header.forEach((name, i) => {
    idx[name] = i;
  });
  const rows = [];
  for (let i = 1; i < lines.length; i++) {
    rows.push(parseCsvLine(lines[i]));
  }
  return { header, idx, rows };
}

async function fetchText(url) {
  const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });
  if (!res.ok) {
    throw new Error(`Failed to fetch ${url}: HTTP ${res.status}`);
  }
  return res.text();
}

/**
 * Classic square-spiral offset generator: right, down, left, up, with the
 * segment length growing by one every two turns. Used to deterministically
 * find the nearest free grid cell when two systems round to the same cell.
 */
function* spiralOffsets() {
  let x = 0;
  let y = 0;
  let dx = 1;
  let dy = 0;
  let segmentLength = 1;
  let stepsInSegment = 0;
  let turns = 0;
  for (;;) {
    x += dx;
    y += dy;
    yield [x, y];
    stepsInSegment++;
    if (stepsInSegment === segmentLength) {
      stepsInSegment = 0;
      // rotate direction clockwise: right -> down -> left -> up -> right
      const ndx = -dy;
      const ndy = dx;
      dx = ndx;
      dy = ndy;
      turns++;
      if (turns % 2 === 0) segmentLength++;
    }
  }
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const n = sorted.length;
  const mid = n >> 1;
  return n % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/**
 * Parses every `<use id="sys<id>" x="…" y="…" … />` tag out of a Dotlan
 * region SVG. Attribute order isn't assumed (each of id/x/y is matched
 * independently within the tag) even though Dotlan happens to emit them in
 * a consistent order today.
 */
function parseSvgSystemPositions(svgText) {
  const positions = new Map(); // solarSystemID -> [x, y] in this SVG's local pixel space
  const useTagRe = /<use\b([^>]*?)\/>/g;
  let m;
  while ((m = useTagRe.exec(svgText))) {
    const attrs = m[1];
    const idMatch = attrs.match(/\bid="sys(\d+)"/);
    if (!idMatch) continue;
    const xMatch = attrs.match(/\bx="(-?[\d.]+)"/);
    const yMatch = attrs.match(/\by="(-?[\d.]+)"/);
    if (!xMatch || !yMatch) continue;
    positions.set(parseInt(idMatch[1], 10), [parseFloat(xMatch[1]), parseFloat(yMatch[1])]);
  }
  return positions;
}

function dotlanSvgUrl(regionName) {
  return `${DOTLAN_SVG_BASE}${regionName.replace(/ /g, '_')}.svg`;
}

/** Reads a cached SVG from disk, or fetches + caches it if missing. */
async function fetchRegionSvg(regionName) {
  const cacheFile = path.join(CACHE_DIR, `${regionName.replace(/ /g, '_')}.svg`);
  if (existsSync(cacheFile)) {
    return readFileSync(cacheFile, 'utf8');
  }
  const text = await fetchText(dotlanSvgUrl(regionName));
  writeFileSync(cacheFile, text);
  return text;
}

/**
 * Fetches every region's SVG (cache-first), at most FETCH_CONCURRENCY in
 * flight at once. Per-region failures (404, empty SVG) are collected rather
 * than thrown, so one bad region doesn't block placing the other ~69.
 */
async function fetchAllRegionSvgs(regions) {
  mkdirSync(CACHE_DIR, { recursive: true });
  const svgPositions = new Map(); // regionID -> Map<solarSystemID, [x,y]>
  const skipped = []; // { region, reason }
  let cursor = 0;
  async function worker() {
    while (cursor < regions.length) {
      const region = regions[cursor++];
      try {
        const svgText = await fetchRegionSvg(region.name);
        const positions = parseSvgSystemPositions(svgText);
        if (positions.size === 0) {
          throw new Error('SVG fetched but contained zero <use id="sys…"> system markers');
        }
        svgPositions.set(region.id, positions);
      } catch (err) {
        process.stderr.write(`ABORT region "${region.name}" (${region.id}): ${err.message}\n`);
        skipped.push({ region, reason: err.message });
      }
    }
  }
  await Promise.all(Array.from({ length: FETCH_CONCURRENCY }, worker));
  return { svgPositions, skipped };
}

function bboxOfPositions(positions) {
  let minX = Infinity,
    maxX = -Infinity,
    minY = Infinity,
    maxY = -Infinity;
  for (const [x, y] of positions) {
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return { minX, maxX, minY, maxY };
}

function centroid2D(points) {
  let sx = 0,
    sy = 0,
    n = 0;
  for (const [x, y] of points) {
    sx += x;
    sy += y;
    n++;
  }
  return n ? [sx / n, sy / n] : null;
}

async function main() {
  process.stderr.write('Fetching mapSolarSystems.csv...\n');
  const solarCsvText = await fetchText(SOLAR_SYSTEMS_URL);
  process.stderr.write('Fetching mapRegions.csv...\n');
  const regionsCsvText = await fetchText(REGIONS_URL);

  const { idx: solarIdx, rows: solarRows } = parseCsv(solarCsvText);
  const requiredSolarCols = ['solarSystemID', 'regionID', 'solarSystemName', 'position2Dx', 'position2Dy'];
  for (const col of requiredSolarCols) {
    if (!(col in solarIdx)) {
      throw new Error(
        `mapSolarSystems.csv is missing required column "${col}". Header had: ${Object.keys(solarIdx).join(', ')}`,
      );
    }
  }

  const { idx: regionIdx, rows: regionRows } = parseCsv(regionsCsvText);
  for (const col of ['regionID', 'regionName']) {
    if (!(col in regionIdx)) {
      throw new Error(`mapRegions.csv is missing required column "${col}".`);
    }
  }

  // --- SDE is authoritative for "which regions/systems are k-space, and
  // which region owns each system"; Dotlan supplies only geometry. ---
  const regionNames = new Map();
  for (const row of regionRows) {
    const regionID = parseInt(row[regionIdx.regionID], 10);
    if (!Number.isFinite(regionID) || regionID < KSPACE_MIN_REGION_ID || regionID > KSPACE_MAX_REGION_ID) continue;
    regionNames.set(regionID, row[regionIdx.regionName]);
  }
  const regionList = [...regionNames.entries()].map(([id, name]) => ({ id, name })).sort((a, b) => a.id - b.id);

  const ownRegionOf = new Map(); // solarSystemID -> regionID
  const systemNames = new Map();
  const systemP2D = new Map(); // solarSystemID -> [position2Dx, position2Dy], used ONLY to pick a
  // direction for regions with no Dotlan-shared anchor to the placed set.
  for (const row of solarRows) {
    const regionID = parseInt(row[solarIdx.regionID], 10);
    if (!regionNames.has(regionID)) continue;
    const solarSystemID = parseInt(row[solarIdx.solarSystemID], 10);
    ownRegionOf.set(solarSystemID, regionID);
    systemNames.set(solarSystemID, row[solarIdx.solarSystemName]);
    const px = parseFloat(row[solarIdx.position2Dx]);
    const py = parseFloat(row[solarIdx.position2Dy]);
    if (Number.isFinite(px) && Number.isFinite(py)) systemP2D.set(solarSystemID, [px, py]);
  }
  if (ownRegionOf.size === 0) {
    throw new Error('No k-space systems parsed from mapSolarSystems.csv — aborting.');
  }
  process.stderr.write(`k-space regions=${regionList.length} systems=${ownRegionOf.size} (from SDE)\n`);

  // --- fetch + cache + parse every region's Dotlan SVG. Region SVGs draw
  // their own systems PLUS a chunk of neighbouring regions' systems for
  // context; those foreign appearances are exactly the anchors used below
  // to stitch regions together (a system's OWN region's rendering always
  // wins for its final position — see placeRegion below). ---
  process.stderr.write(`Fetching ${regionList.length} region SVGs from Dotlan (cache: ${CACHE_DIR})...\n`);
  const { svgPositions, skipped: skippedRegions } = await fetchAllRegionSvgs(regionList);
  const placeableRegions = regionList.filter(r => svgPositions.has(r.id));
  if (skippedRegions.length > 0) {
    process.stderr.write(
      `Skipped ${skippedRegions.length} region(s) (see ABORT lines above): ` +
        `${skippedRegions.map(s => s.region.name).join(', ')}\n`,
    );
  }

  // --- region adjacency graph: an edge exists between two regions if their
  // SVGs share at least one system id (own or foreign-context). ---
  const adjacency = new Map();
  for (const r of placeableRegions) adjacency.set(r.id, new Map());
  for (let i = 0; i < placeableRegions.length; i++) {
    for (let j = i + 1; j < placeableRegions.length; j++) {
      const A = placeableRegions[i].id;
      const B = placeableRegions[j].id;
      const mapA = svgPositions.get(A);
      const mapB = svgPositions.get(B);
      let shared = 0;
      for (const sid of mapA.keys()) if (mapB.has(sid)) shared++;
      if (shared > 0) {
        adjacency.get(A).set(B, shared);
        adjacency.get(B).set(A, shared);
      }
    }
  }

  // --- stitch every region into one global (translation-only) pixel frame ---
  const regionOffset = new Map(); // regionID -> [ox, oy]
  const authoritative = new Map(); // solarSystemID -> [gx, gy], from the system's OWN region
  const provisional = new Map(); // solarSystemID -> [gx, gy], from a foreign-context rendering,
  // used only as a stitching anchor until (if ever) the system's own region gets placed
  function globalPosOf(sid) {
    return authoritative.has(sid) ? authoritative.get(sid) : provisional.get(sid);
  }
  function placeRegion(regionId, offset) {
    regionOffset.set(regionId, offset);
    for (const [sid, [lx, ly]] of svgPositions.get(regionId)) {
      const g = [lx + offset[0], ly + offset[1]];
      if (ownRegionOf.get(sid) === regionId) {
        authoritative.set(sid, g); // own region always wins, even over an earlier foreign guess
      } else if (!provisional.has(sid)) {
        provisional.set(sid, g);
      }
    }
  }

  const stitchReport = []; // { region, anchors, residual, method, via }
  const unvisited = new Set(placeableRegions.map(r => r.id));

  function totalSharedAmong(regionId, candidateSet) {
    let total = 0;
    for (const [neighborId, count] of adjacency.get(regionId)) {
      if (candidateSet.has(neighborId)) total += count;
    }
    return total;
  }

  while (unvisited.size > 0) {
    // Pick the next BFS root: prefer a region with graph edges into the
    // still-unvisited set (so its shape stitches onto the shared-anchor
    // frame like the rest); the very first root is "the region with the
    // most shared systems" overall. Any region with zero such edges (no
    // shared system with anything, anywhere) is placed via SDE-direction
    // fallback below, and BFS from it will simply terminate immediately.
    let rootId = null;
    let rootScore = -1;
    for (const id of unvisited) {
      const score = totalSharedAmong(id, unvisited);
      if (score > rootScore || (score === rootScore && (rootId === null || id < rootId))) {
        rootScore = score;
        rootId = id;
      }
    }

    if (authoritative.size === 0) {
      // very first region ever placed: anchors its own frame at [0,0]
      placeRegion(rootId, [0, 0]);
      stitchReport.push({ region: regionNames.get(rootId), id: rootId, anchors: 0, residual: 0, method: 'root' });
    } else {
      // check whether this root shares any anchor with what's already placed
      const localMap = svgPositions.get(rootId);
      const anchors = [];
      for (const [sid, local] of localMap) {
        const g = globalPosOf(sid);
        if (g) anchors.push({ local, global: g });
      }
      if (anchors.length > 0) {
        const offX = median(anchors.map(a => a.global[0] - a.local[0]));
        const offY = median(anchors.map(a => a.global[1] - a.local[1]));
        let residual = 0;
        for (const a of anchors) {
          residual = Math.max(
            residual,
            Math.abs(a.global[0] - a.local[0] - offX),
            Math.abs(a.global[1] - a.local[1] - offY),
          );
        }
        placeRegion(rootId, [offX, offY]);
        stitchReport.push({
          region: regionNames.get(rootId),
          id: rootId,
          anchors: anchors.length,
          residual,
          method: 'anchor',
        });
      } else {
        // no shared system with the placed set anywhere: fall back to an
        // SDE-derived direction, pushed just outside the current global
        // bbox so it can't collide with anything already placed.
        const ownSids = [...localMap.keys()].filter(sid => ownRegionOf.get(sid) === rootId);
        const placedCentroidP2D = centroid2D([...authoritative.keys()].map(sid => systemP2D.get(sid)).filter(Boolean));
        const ownCentroidP2D = centroid2D(ownSids.map(sid => systemP2D.get(sid)).filter(Boolean));
        const { minX, maxX, minY, maxY } = bboxOfPositions(authoritative.values());
        const centerX = (minX + maxX) / 2;
        const centerY = (minY + maxY) / 2;
        const globalRadius = Math.hypot(maxX - minX, maxY - minY) / 2;
        const localBbox = bboxOfPositions(localMap.values());
        const localCenterX = (localBbox.minX + localBbox.maxX) / 2;
        const localCenterY = (localBbox.minY + localBbox.maxY) / 2;
        const localRadius = Math.hypot(localBbox.maxX - localBbox.minX, localBbox.maxY - localBbox.minY) / 2;

        let dir = [1, 0];
        if (placedCentroidP2D && ownCentroidP2D) {
          // position2Dy grows north on the SDE's own projection (same
          // orientation Dotlan draws in); our pixel-space y grows downward
          // (south), so the y component is inverted.
          const raw = [ownCentroidP2D[0] - placedCentroidP2D[0], -(ownCentroidP2D[1] - placedCentroidP2D[1])];
          const len = Math.hypot(raw[0], raw[1]);
          if (len > 0) dir = [raw[0] / len, raw[1] / len];
        }
        const targetCenter = [
          centerX + dir[0] * (globalRadius + localRadius + ORPHAN_GAP_PX),
          centerY + dir[1] * (globalRadius + localRadius + ORPHAN_GAP_PX),
        ];
        const offset = [targetCenter[0] - localCenterX, targetCenter[1] - localCenterY];
        placeRegion(rootId, offset);
        stitchReport.push({
          region: regionNames.get(rootId),
          id: rootId,
          anchors: 0,
          residual: null,
          method: 'sde-direction',
          direction: dir,
        });
        process.stderr.write(
          `No Dotlan-shared anchor for region "${regionNames.get(rootId)}" (${rootId}); placed via SDE-derived ` +
            `direction [${dir[0].toFixed(2)}, ${dir[1].toFixed(2)}] instead.\n`,
        );
      }
    }
    unvisited.delete(rootId);

    // BFS the rest of this region's connected component using shared-anchor
    // stitching (this also picks up any region that becomes reachable only
    // once an SDE-direction-placed root is on the board).
    const queue = [rootId];
    while (queue.length > 0) {
      const R = queue.shift();
      const neighbors = [...adjacency.get(R).keys()].filter(n => unvisited.has(n)).sort((a, b) => a - b);
      for (const N of neighbors) {
        if (!unvisited.has(N)) continue;
        const localMap = svgPositions.get(N);
        const anchors = [];
        for (const [sid, local] of localMap) {
          const g = globalPosOf(sid);
          if (g) anchors.push({ local, global: g });
        }
        if (anchors.length === 0) continue; // will be handled as a new root by the outer loop
        const offX = median(anchors.map(a => a.global[0] - a.local[0]));
        const offY = median(anchors.map(a => a.global[1] - a.local[1]));
        let residual = 0;
        for (const a of anchors) {
          residual = Math.max(
            residual,
            Math.abs(a.global[0] - a.local[0] - offX),
            Math.abs(a.global[1] - a.local[1] - offY),
          );
        }
        placeRegion(N, [offX, offY]);
        unvisited.delete(N);
        queue.push(N);
        stitchReport.push({
          region: regionNames.get(N),
          id: N,
          anchors: anchors.length,
          residual,
          method: 'anchor',
          via: regionNames.get(R),
        });
      }
    }
  }
  const droppedSystems = [...ownRegionOf.keys()].filter(sid => !authoritative.has(sid));
  if (droppedSystems.length > 0) {
    process.stderr.write(
      `${droppedSystems.length} system(s) dropped (their region's SVG could not be placed): ` +
        `${droppedSystems
          .slice(0, 10)
          .map(sid => systemNames.get(sid))
          .join(', ')}${droppedSystems.length > 10 ? ', …' : ''}\n`,
    );
  }

  // --- stitch quality report: worst 5 residuals among anchor-stitched regions ---
  const anchorStitched = stitchReport.filter(s => s.method === 'anchor');
  const worst = [...anchorStitched].sort((a, b) => b.residual - a.residual).slice(0, 5);
  process.stderr.write('Stitch report (5 worst residuals):\n');
  for (const s of worst) {
    process.stderr.write(
      `  ${s.region}: anchors=${s.anchors} residual=${s.residual.toFixed(1)}px (via ${s.via ?? 'root'})\n`,
    );
  }
  const sdeDirectionPlaced = stitchReport.filter(s => s.method === 'sde-direction');
  if (sdeDirectionPlaced.length > 0) {
    process.stderr.write(
      `Placed via SDE-derived direction (no Dotlan-shared anchor): ${sdeDirectionPlaced.map(s => s.region).join(', ')}\n`,
    );
  }

  // --- pixels -> integer grid cells, preserving Dotlan's aspect ratio on
  // our non-square (180x75) cells; resolve rounding collisions
  // deterministically (ascending solarSystemID, square spiral outward) ---
  const placedSids = [...authoritative.keys()].sort((a, b) => a - b);
  const occupied = new Set();
  const cellById = new Map();
  let nudged = 0;
  for (const sid of placedSids) {
    const [x, y] = authoritative.get(sid);
    let col = Math.round(x / COL_DIVISOR);
    let row = Math.round(y / ROW_DIVISOR);
    let key = `${col},${row}`;
    if (occupied.has(key)) {
      nudged++;
      const spiral = spiralOffsets();
      for (;;) {
        const [dx, dy] = spiral.next().value;
        const cCol = col + dx;
        const cRow = row + dy;
        const cKey = `${cCol},${cRow}`;
        if (!occupied.has(cKey)) {
          col = cCol;
          row = cRow;
          key = cKey;
          break;
        }
      }
    }
    occupied.add(key);
    cellById.set(sid, [col, row]);
  }
  const collisionFraction = nudged / placedSids.length;
  process.stderr.write(`Collision nudges: ${nudged}/${placedSids.length} (${(collisionFraction * 100).toFixed(2)}%)\n`);
  if (collisionFraction > COLLISION_WARN_FRACTION) {
    process.stderr.write(
      `WARNING: collision-nudge fraction ${(collisionFraction * 100).toFixed(2)}% exceeds the ` +
        `${(COLLISION_WARN_FRACTION * 100).toFixed(0)}% sanity threshold — COL_DIVISOR=${COL_DIVISOR}/` +
        `ROW_DIVISOR=${ROW_DIVISOR} are coarse relative to how tightly Dotlan packs systems within a region.\n`,
    );
  }

  // re-translate so the global min col/row = 0
  let finalMinCol = Infinity;
  let finalMinRow = Infinity;
  for (const [col, row] of cellById.values()) {
    if (col < finalMinCol) finalMinCol = col;
    if (row < finalMinRow) finalMinRow = row;
  }

  const systemsOut = {};
  let maxCol = 0;
  let maxRow = 0;
  const sortedIds = [...cellById.keys()].sort((a, b) => a - b);
  const seenCells = new Set();
  for (const id of sortedIds) {
    const [col, row] = cellById.get(id);
    const fCol = col - finalMinCol;
    const fRow = row - finalMinRow;
    const cellKey = `${fCol},${fRow}`;
    if (seenCells.has(cellKey)) {
      throw new Error(`Collision resolution failed: duplicate global cell ${cellKey} (system ${id}).`);
    }
    seenCells.add(cellKey);
    if (fCol > maxCol) maxCol = fCol;
    if (fRow > maxRow) maxRow = fRow;
    systemsOut[String(id)] = [fCol, fRow];
  }

  if (seenCells.size !== placedSids.length) {
    throw new Error(
      `Global cell uniqueness assertion failed: ${seenCells.size} unique cells for ${placedSids.length} systems.`,
    );
  }

  const gridSize = [maxCol + 1, maxRow + 1];

  const placedRegionIds = placeableRegions
    .map(r => r.id)
    .filter(id => regionOffset.has(id))
    .sort((a, b) => a - b);
  const regionsOut = {};
  for (const regionID of placedRegionIds) {
    regionsOut[String(regionID)] = regionNames.get(regionID);
  }

  const output = {
    version: 3,
    generatedAt: new Date().toISOString().slice(0, 10),
    source: 'evemaps.dotlan.net region SVGs, stitched into one global frame',
    regions: regionsOut,
    systems: systemsOut,
  };

  const json = JSON.stringify(output);
  writeFileSync(OUTPUT_PATH, json);

  const bytes = Buffer.byteLength(json, 'utf8');
  process.stderr.write(
    `regions=${placedRegionIds.length} systems=${placedSids.length} globalGridSizeCells=${gridSize[0]}x${gridSize[1]} outputBytes=${bytes}\n`,
  );
  process.stderr.write(`Wrote ${OUTPUT_PATH}\n`);
}

main().catch(err => {
  console.error('FATAL:', err.message);
  process.exit(1);
});
