#!/usr/bin/env node
// Generates assets/js/hooks/Mapper/components/map/layout/data/regionLayouts.json
//
// Precomputes a tidy 2D grid layout for every k-space solar system, grouped by
// region, so the frontend "beautifier" can drop k-space systems into a
// Dotlan-like geographic arrangement without doing any layout math at runtime.
//
// Usage: node assets/scripts/generate-region-layouts.mjs
// (No npm dependencies; uses global fetch, available in Node 18+ and Bun.)

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// NOTE: the SDE mirror path documented casually as
// https://www.fuzzwork.co.uk/dump/latest/mapSolarSystems.csv 404s. The real
// CSV dumps live one level deeper, under /dump/latest/csv/.
const SOLAR_SYSTEMS_URL = 'https://www.fuzzwork.co.uk/dump/latest/csv/mapSolarSystems.csv';
const REGIONS_URL = 'https://www.fuzzwork.co.uk/dump/latest/csv/mapRegions.csv';

const CELL_W = 180;
const CELL_H = 75;
// Row cells are drawn shorter than they are wide, so one lattice step along Y
// has to span more *row* units than one lattice step along X spans *col*
// units for the same on-screen physical distance. CELL_W/CELL_H is exactly
// that correction factor.
const ROW_ASPECT = CELL_W / CELL_H; // 2.4
const TARGET_BBOX_CELLS = 1200;

// A coordinate is considered "on the lattice" if it's within this fraction of
// one step from the nearest integer multiple.
const STEP_TOLERANCE = 0.01;
// At least this fraction of real position2D coordinates (per axis) must fall
// on the lattice, or the projection assumption is wrong and we abort.
const STEP_MIN_FIT_FRACTION = 0.99;

const KSPACE_MIN_REGION_ID = 10000001;
const KSPACE_MAX_REGION_ID = 10999999;

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
  const res = await fetch(url);
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

/**
 * Determines the fundamental lattice step of a set of quantized coordinates
 * via a real-valued GCD-by-successive-approximation: start from the modal
 * consecutive gap between sorted unique values (a good first guess even in
 * the presence of a handful of multi-step gaps or slightly-off-lattice
 * outliers), then refine with weighted least squares (weight = the integer
 * step count each value implies), excluding points that don't land near an
 * integer multiple. Iterating converges quickly because each refined `step`
 * produces better integer assignments than the last.
 */
function robustStep(values) {
  const uniq = [...new Set(values)].sort((a, b) => a - b);
  if (uniq.length < 2) {
    throw new Error('Cannot determine lattice step: fewer than 2 distinct coordinate values.');
  }
  const origin = uniq[0];
  const rel = uniq.map(v => v - origin);

  const diffs = [];
  for (let i = 1; i < uniq.length; i++) diffs.push(uniq[i] - uniq[i - 1]);
  const diffFreq = new Map();
  for (const d of diffs) diffFreq.set(d, (diffFreq.get(d) || 0) + 1);
  let step = diffs[0];
  let bestCount = 0;
  for (const [d, count] of diffFreq) {
    if (count > bestCount) {
      bestCount = count;
      step = d;
    }
  }

  for (let iter = 0; iter < 6; iter++) {
    let num = 0;
    let den = 0;
    for (const v of rel) {
      const n = Math.round(v / step);
      if (n === 0) continue;
      const relResid = Math.abs(v - n * step) / step;
      if (relResid > STEP_TOLERANCE) continue;
      num += v * n;
      den += n * n;
    }
    if (den === 0) break;
    step = num / den;
  }

  let within = 0;
  const outliers = [];
  for (let i = 0; i < rel.length; i++) {
    const n = Math.round(rel[i] / step);
    const relResid = Math.abs(rel[i] - n * step) / step;
    if (relResid <= STEP_TOLERANCE) {
      within++;
    } else {
      outliers.push(uniq[i]);
    }
  }
  const fraction = within / rel.length;
  return { step, fraction, total: rel.length, within, outliers };
}

/** Solves a 3x3 linear system via Cramer's rule. */
function solveLinear3(A, b) {
  const det3 = m =>
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
    m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
    m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
  const D = det3(A);
  if (Math.abs(D) < 1e-9) {
    throw new Error('Singular matrix while fitting fallback projection (reference systems are collinear).');
  }
  const withCol = (m, col, vec) => m.map((row, i) => row.map((v, j) => (j === col ? vec[i] : v)));
  return [det3(withCol(A, 0, b)) / D, det3(withCol(A, 1, b)) / D, det3(withCol(A, 2, b)) / D];
}

/**
 * Fits a 2D affine transform (x, z) -> (position2Dx, position2Dy) by least
 * squares over a region's systems that DO have a position2D projection, for
 * use on the (expected to be empty, but handled defensively) handful of
 * k-space systems that don't. Coordinates are mean-centred and rescaled
 * before solving to keep the 3x3 normal-equations solve well-conditioned
 * despite EVE's ~1e17-magnitude coordinates.
 */
function fitFallbackProjection(referencePoints) {
  const n = referencePoints.length;
  if (n < 3) {
    throw new Error(`Cannot fit fallback projection: need >= 3 reference systems in the region, got ${n}.`);
  }
  const meanX = referencePoints.reduce((s, p) => s + p.x, 0) / n;
  const meanZ = referencePoints.reduce((s, p) => s + p.z, 0) / n;
  const SCALE = 1e16;
  const norm = referencePoints.map(p => ({
    x: (p.x - meanX) / SCALE,
    z: (p.z - meanZ) / SCALE,
    p2x: p.p2x,
    p2y: p.p2y,
  }));

  let Sxx = 0,
    Sxz = 0,
    Sx = 0,
    Szz = 0,
    Sz = 0,
    Sxp = 0,
    Szp = 0,
    Sp = 0,
    Sxq = 0,
    Szq = 0,
    Sq = 0;
  for (const p of norm) {
    Sxx += p.x * p.x;
    Sxz += p.x * p.z;
    Sx += p.x;
    Szz += p.z * p.z;
    Sz += p.z;
    Sxp += p.x * p.p2x;
    Szp += p.z * p.p2x;
    Sp += p.p2x;
    Sxq += p.x * p.p2y;
    Szq += p.z * p.p2y;
    Sq += p.p2y;
  }
  const A = [
    [Sxx, Sxz, Sx],
    [Sxz, Szz, Sz],
    [Sx, Sz, n],
  ];
  const [a, b, e] = solveLinear3(A, [Sxp, Szp, Sp]);
  const [c, d, f] = solveLinear3(A, [Sxq, Szq, Sq]);
  // norm.x = (x - meanX) / SCALE, so undo the centring/scaling algebraically.
  const aa = a / SCALE;
  const bb = b / SCALE;
  const ee = e - aa * meanX - bb * meanZ;
  const cc = c / SCALE;
  const dd = d / SCALE;
  const ff = f - cc * meanX - dd * meanZ;
  return (x, z) => [aa * x + bb * z + ee, cc * x + dd * z + ff];
}

async function main() {
  process.stderr.write('Fetching mapSolarSystems.csv...\n');
  const solarCsvText = await fetchText(SOLAR_SYSTEMS_URL);
  process.stderr.write('Fetching mapRegions.csv...\n');
  const regionsCsvText = await fetchText(REGIONS_URL);

  const { idx: solarIdx, rows: solarRows } = parseCsv(solarCsvText);
  const requiredCols = ['solarSystemID', 'regionID', 'solarSystemName', 'x', 'z', 'position2Dx', 'position2Dy'];
  for (const col of requiredCols) {
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

  const regionNames = new Map();
  for (const row of regionRows) {
    const regionID = parseInt(row[regionIdx.regionID], 10);
    regionNames.set(regionID, row[regionIdx.regionName]);
  }

  // --- parse + filter to k-space; position2Dx/position2Dy is the SDE's own
  // Dotlan-style 2D map projection (present for k-space, empty for the
  // ~3000 wormhole/abyssal systems, which the region filter already drops). ---
  const allSystems = [];
  for (const row of solarRows) {
    const regionID = parseInt(row[solarIdx.regionID], 10);
    if (!Number.isFinite(regionID) || regionID < KSPACE_MIN_REGION_ID || regionID > KSPACE_MAX_REGION_ID) continue;
    const solarSystemID = parseInt(row[solarIdx.solarSystemID], 10);
    const name = row[solarIdx.solarSystemName];
    const x = parseFloat(row[solarIdx.x]);
    const z = parseFloat(row[solarIdx.z]);
    if (!Number.isFinite(x) || !Number.isFinite(z)) {
      throw new Error(`System ${solarSystemID} (${name}) has non-numeric x/z coordinates.`);
    }
    const p2xRaw = row[solarIdx.position2Dx];
    const p2yRaw = row[solarIdx.position2Dy];
    const hasP2D = p2xRaw !== '' && p2yRaw !== '';
    if (hasP2D && (!Number.isFinite(parseFloat(p2xRaw)) || !Number.isFinite(parseFloat(p2yRaw)))) {
      throw new Error(`System ${solarSystemID} (${name}) has non-numeric position2Dx/position2Dy.`);
    }
    allSystems.push({
      regionID,
      solarSystemID,
      name,
      x,
      z,
      hasP2D,
      p2x: hasP2D ? parseFloat(p2xRaw) : null,
      p2y: hasP2D ? parseFloat(p2yRaw) : null,
    });
  }

  if (allSystems.length === 0) {
    throw new Error('No k-space systems parsed from mapSolarSystems.csv — aborting.');
  }

  // --- detect the SDE's projection lattice step, per axis, from every
  // k-space system that has a position2D projection ---
  const withP2D = allSystems.filter(s => s.hasP2D);
  const fallbackSystems = allSystems.filter(s => !s.hasP2D);

  const stepXInfo = robustStep(withP2D.map(s => s.p2x));
  const stepYInfo = robustStep(withP2D.map(s => s.p2y));
  process.stderr.write(
    `Lattice step X=${stepXInfo.step} (${stepXInfo.within}/${stepXInfo.total} on-lattice), ` +
      `Y=${stepYInfo.step} (${stepYInfo.within}/${stepYInfo.total} on-lattice)\n`,
  );
  if (stepXInfo.fraction < STEP_MIN_FIT_FRACTION || stepYInfo.fraction < STEP_MIN_FIT_FRACTION) {
    throw new Error(
      `position2D coordinates don't fit a regular lattice: X ${(stepXInfo.fraction * 100).toFixed(2)}%, ` +
        `Y ${(stepYInfo.fraction * 100).toFixed(2)}% within tolerance (need >= ${STEP_MIN_FIT_FRACTION * 100}%). ` +
        `X outliers: ${stepXInfo.outliers.slice(0, 5).join(', ')}. Y outliers: ${stepYInfo.outliers.slice(0, 5).join(', ')}.`,
    );
  }
  const stepX = stepXInfo.step;
  const stepY = stepYInfo.step;

  // --- group by region, then resolve any missing position2D via a
  // per-region affine fit of the old x/z projection onto position2D space,
  // using that region's other (known-good) systems as reference points ---
  const byRegion = new Map();
  for (const s of allSystems) {
    if (!byRegion.has(s.regionID)) byRegion.set(s.regionID, []);
    byRegion.get(s.regionID).push(s);
  }

  if (fallbackSystems.length > 0) {
    const byRegionFallback = new Map();
    for (const s of fallbackSystems) {
      if (!byRegionFallback.has(s.regionID)) byRegionFallback.set(s.regionID, []);
      byRegionFallback.get(s.regionID).push(s);
    }
    for (const [regionID, systems] of byRegionFallback) {
      const referencePoints = byRegion.get(regionID).filter(s => s.hasP2D);
      const project = fitFallbackProjection(referencePoints);
      for (const s of systems) {
        const [fx, fy] = project(s.x, s.z);
        s.p2x = fx;
        s.p2y = fy;
      }
    }
    process.stderr.write(
      `Fell back to x/z-derived projection for ${fallbackSystems.length} system(s) missing position2D: ` +
        `${fallbackSystems.map(s => `${s.name} (${s.solarSystemID})`).join(', ')}\n`,
    );
  } else {
    process.stderr.write('All k-space systems have a position2D projection; no fallback needed.\n');
  }

  // --- global scale factor, in lattice units, so the full k-space bounding
  // box is ~1200 cells across its larger dimension. Y is negated + aspect
  // corrected here too (same as the per-region row formula below) so that
  // centroids and per-region local cells share one "row grows downward"
  // coordinate space — callers translate local cells by the centroid
  // directly (see kspaceLayout.ts), so the two MUST agree on orientation. ---
  const uOf = s => s.p2x / stepX;
  const vOf = s => (-s.p2y / stepY) * ROW_ASPECT;

  let minU = Infinity;
  let maxU = -Infinity;
  let minV = Infinity;
  let maxV = -Infinity;
  for (const s of allSystems) {
    const u = uOf(s);
    const v = vOf(s);
    if (u < minU) minU = u;
    if (u > maxU) maxU = u;
    if (v < minV) minV = v;
    if (v > maxV) maxV = v;
  }
  const globalScale = TARGET_BBOX_CELLS / Math.max(maxU - minU, maxV - minV);

  const regionIds = [...byRegion.keys()].sort((a, b) => a - b);
  const regionsOut = {};
  let maxRegionSize = [0, 0];

  for (const regionID of regionIds) {
    const systems = byRegion.get(regionID);
    systems.sort((a, b) => a.solarSystemID - b.solarSystemID);

    // centroid: mean of (position2Dx/step, position2Dy/step*ROW_ASPECT,
    // sign-flipped), scaled by the shared global factor
    let sumU = 0;
    let sumV = 0;
    for (const s of systems) {
      sumU += uOf(s);
      sumV += vOf(s);
    }
    const centroid = [
      Math.round((sumU / systems.length) * globalScale),
      Math.round((sumV / systems.length) * globalScale),
    ];

    // region reference corner: min X (west edge) and max Y (north edge, since
    // higher position2Dy is further north / up-screen, verified against
    // Dotlan's own rendered The Forge map: Perimeter, whose position2Dy is
    // below Jita's, sits south of Jita on-screen, and New Caldari, whose
    // position2Dy is above Jita's, sits north of Jita on-screen)
    let minX = Infinity;
    let maxY = -Infinity;
    for (const s of systems) {
      if (s.p2x < minX) minX = s.p2x;
      if (s.p2y > maxY) maxY = s.p2y;
    }

    // lattice units -> integer cells, resolving rounding collisions
    // deterministically with a spiral search
    const occupied = new Set();
    const cellById = new Map();
    for (const s of systems) {
      const lx = (s.p2x - minX) / stepX;
      const ly = (maxY - s.p2y) / stepY;
      let col = Math.round(lx);
      let row = Math.round(ly * ROW_ASPECT);
      let key = `${col},${row}`;
      if (occupied.has(key)) {
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
      cellById.set(s.solarSystemID, [col, row]);
    }

    // re-translate so region min col/row = 0
    let finalMinCol = Infinity;
    let finalMinRow = Infinity;
    for (const [col, row] of cellById.values()) {
      if (col < finalMinCol) finalMinCol = col;
      if (row < finalMinRow) finalMinRow = row;
    }

    const systemsOut = {};
    let maxCol = 0;
    let maxRow = 0;
    // stable numeric-ascending key order (also V8's native ordering for
    // integer-like string keys, but built explicitly for clarity)
    const sortedIds = [...cellById.keys()].sort((a, b) => a - b);
    const seenCells = new Set();
    for (const id of sortedIds) {
      const [col, row] = cellById.get(id);
      const fCol = col - finalMinCol;
      const fRow = row - finalMinRow;
      const cellKey = `${fCol},${fRow}`;
      if (seenCells.has(cellKey)) {
        throw new Error(`Collision resolution failed: region ${regionID} has duplicate cell ${cellKey}.`);
      }
      seenCells.add(cellKey);
      if (fCol > maxCol) maxCol = fCol;
      if (fRow > maxRow) maxRow = fRow;
      systemsOut[String(id)] = [fCol, fRow];
    }

    const size = [maxCol + 1, maxRow + 1];
    if (size[0] * size[1] > maxRegionSize[0] * maxRegionSize[1]) maxRegionSize = size;

    regionsOut[String(regionID)] = {
      name: regionNames.get(regionID) ?? `Region ${regionID}`,
      centroid,
      size,
      systems: systemsOut,
    };
  }

  // top-level object; integer-like string keys inside `regions`/`systems`
  // are already emitted in ascending numeric order (both by explicit sort
  // above and by JS's native ordering of integer-index string keys).
  const output = {
    version: 1,
    generatedAt: new Date().toISOString().slice(0, 10),
    source: 'fuzzwork mapSolarSystems.csv (SDE) position2Dx/position2Dy projection',
    regions: regionsOut,
  };

  const json = JSON.stringify(output);
  writeFileSync(OUTPUT_PATH, json);

  const systemCount = allSystems.length;
  const regionCount = regionIds.length;
  const bytes = Buffer.byteLength(json, 'utf8');
  process.stderr.write(
    `regions=${regionCount} systems=${systemCount} maxRegionSizeCells=${maxRegionSize[0]}x${maxRegionSize[1]} outputBytes=${bytes}\n`,
  );
  process.stderr.write(`Wrote ${OUTPUT_PATH}\n`);
}

main().catch(err => {
  console.error('FATAL:', err.message);
  process.exit(1);
});
