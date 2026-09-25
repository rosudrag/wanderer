#!/usr/bin/env node
// ---------------------------------------------------------------------------
// Map-beautifier layout benchmark.
//
// map/layout (the "beautifyLayout" engine) that the maintainers agreed MUST
// both hold before anything about the layout is "improved":
//
//   1. QUALITY   — does a from-scratch beautify produce a decent map (few
//                  edge crossings, tight bounding box, short edges, no
//                  overlapping systems, everything grid-aligned,
//                  deterministic output for the same input, IDEMPOTENT:
//                  beautifying an already-beautified map with nothing else
//                  changed moves nothing, and — the two rules this file
//                  once missed entirely — no two edges COLLINEAR-OVERLAP
//                  (one hiding another) and no node sits strictly on top
//                  of an edge it isn't an endpoint of (hiding it)?
//   2. STABILITY — when a system is added to an already-beautified map and
//                  it's re-beautified, how much does the existing map
//                  reshuffle? Measured two ways:
//                    - round-trip (THE number this is judged on): lay out
//                      the raw scenario once (P1), feed P1's OWN OUTPUT
//                      back in as the existing nodes' positions — exactly
//                      what the app does: the server persists what P1
//                      returned, the client re-reads it — attach k new,
//                      still-unbeautified systems, then beautify again
//                      with default options (`mode: 'auto'`) -> P2. This
//                      is "I have a tidy map, I add a system, I press
//                      beautify again" — the only scenario
//                      `BeautifyOptions.mode` was built for, and the only
//                      one `'auto'` can ever resolve to `'incremental'`
//                      for. Also reports which mode ('incremental'/'full')
//                      the engine actually resolved to per repeat — a
//                      scenario silently falling back to 'full' must be
//                      visible, not inferred.
//                    - cold (still meaningful, NOT the primary number):
//                      the original measurement, renamed honestly — attach
//                      k new systems to the RAW, never-beautified scenario
//                      nodes and re-beautify. `'auto'` always resolves
//                      `'full'` here (raw coordinates never look laid
//                      out), so this is "what a from-scratch re-solve
//                      costs", not stability.
//                  Both report moved fraction, displacement, and
//                  left/right & above/below order inversions. Round-trip
//                  additionally checks the k NEWLY ADDED nodes' own
//                  placement — on-grid, actually moved off their raw drop
//                  point, and landed near the already-placed neighbour
//                  they were attached to — since a perfect "existing
//                  nodes didn't move" score can otherwise hide a new
//                  system dumped off-grid far from the map. It also
//                  re-checks the same edge-overlap/node-occlusion rules
//                  as QUALITY on the post-insertion layout: a newly added
//                  system must not hide, or be hidden behind, a
//                  connection either.
//
// Run: `node dev/layout-bench.mjs` (plain Node, no install step, no Bun).
// Flags:
//   --scenario <name>     limit to one scenario (yugen|chain|kspace-wide|mixed|occlusion)
//   --json <path>         write the full structured result as JSON
//   --compare <path.json> diff against a previous --json run; prints a
//                         delta table and exits 1 if anything regressed
//                         beyond the tolerances documented in
//                         dev/layout-bench.README.md
//
// ---------------------------------------------------------------------------
// TypeScript loading strategy (the engine is authored in .ts; this file must
// run on plain `node`, no bundler, no project install step):
//
//   1. NATIVE — every Node >=22.6 can strip erasable TS syntax from .ts
//      files (unflagged since ~23.6; needs `--experimental-strip-types`
//      before that). We feature-detect via `process.features.typescript`
//      and, since that flag existing doesn't guarantee THIS file's syntax
//      is erasable, we additionally probe by actually importing the engine
//      and only commit to this strategy if that succeeds.
//   2. TYPESCRIPT PACKAGE — if native stripping is unavailable/insufficient,
//      we look for a real `typescript` install resolvable from this repo
//      (assets/node_modules, repo-root node_modules, or NODE_PATH) and use
//      `ts.transpileModule` per file through a custom `node:module` load
//      hook. This needs zero code changes if `cd assets && yarn install`
//      has been run — no new dependency is added by this file itself.
//   3. FAIL LOUD — if neither works we print the exact remediation command
//      and exit 1. We never silently fall back to a hand-rolled parser.
//
// Either strategy also needs a `resolve` hook (the engine's .ts files
// import each other extensionless, e.g. `from './chainLayout'`, which is
// legal under the bundler used to actually ship this code but not under
// Node's own ESM resolver) and a `load` hook for the engine's JSON data
// file (Node requires an explicit `type: "json"` import attribute that
// the engine's dynamic `import('./data/regionLayouts.json')` does not
// supply, since that attribute isn't needed by the Vite bundler either).
// ---------------------------------------------------------------------------

import { registerHooks, createRequire } from "node:module";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "..");
const ASSETS_DIR = path.join(REPO_ROOT, "assets");
const LAYOUT_DIR = path.join(
  ASSETS_DIR,
  "js/hooks/Mapper/components/map/layout",
);
const LAYOUT_INDEX = path.join(LAYOUT_DIR, "index.ts");
const REGION_LAYOUTS_JSON = path.join(LAYOUT_DIR, "data/regionLayouts.json");
const SEED_EX = path.join(REPO_ROOT, "lib/wanderer_app/dev/seed.ex");

const TS_EXTS = [".ts", ".tsx", ".mts"];

function jsonLoadHook(url, context, nextLoad) {
  if (url.endsWith(".json")) {
    const source = readFileSync(fileURLToPath(url), "utf8");
    return { format: "json", source, shortCircuit: true };
  }
  return nextLoad(url, context);
}

function extFixupResolveHook(specifier, context, nextResolve) {
  try {
    return nextResolve(specifier, context);
  } catch (err) {
    if (
      (specifier.startsWith("./") || specifier.startsWith("../")) &&
      !/\.[a-zA-Z0-9]+$/.test(specifier)
    ) {
      for (const ext of TS_EXTS) {
        try {
          return nextResolve(specifier + ext, context);
        } catch {
          // try next candidate extension
        }
      }
    }
    throw err;
  }
}

async function tryNativeStrip() {
  if (!process.features?.typescript) return false;
  registerHooks({ resolve: extFixupResolveHook, load: jsonLoadHook });
  try {
    await import(pathToFileURL(LAYOUT_INDEX));
    return true;
  } catch {
    // Native stripping exists but this file/syntax isn't erasable-only
    // (e.g. an older Node needing --experimental-transform-types, or the
    // engine grew non-erasable syntax) — fall through to the next strategy.
    return false;
  }
}

function tryTypescriptPackage() {
  const req = createRequire(import.meta.url);
  let ts;
  try {
    const resolved = req.resolve("typescript", {
      paths: [ASSETS_DIR, REPO_ROOT, process.cwd()],
    });
    ts = req(resolved);
  } catch {
    return false;
  }
  registerHooks({
    resolve: extFixupResolveHook,
    load(url, context, nextLoad) {
      if (url.endsWith(".ts") || url.endsWith(".tsx") || url.endsWith(".mts")) {
        const filePath = fileURLToPath(url);
        const source = readFileSync(filePath, "utf8");
        const out = ts.transpileModule(source, {
          compilerOptions: {
            module: ts.ModuleKind.ESNext,
            target: ts.ScriptTarget.ES2022,
          },
          fileName: filePath,
        }).outputText;
        return { format: "module", source: out, shortCircuit: true };
      }
      return jsonLoadHook(url, context, nextLoad);
    },
  });
  return true;
}

async function loadEngine() {
  const strategy = (await tryNativeStrip())
    ? "native"
    : tryTypescriptPackage()
      ? "typescript-package"
      : null;
  if (!strategy) {
    process.stderr.write(
      "\n[layout-bench] Cannot load the TypeScript layout engine: neither Node's\n" +
        "built-in TypeScript support nor a resolvable `typescript` package was found.\n\n" +
        "Fix ONE of the following, then re-run `node dev/layout-bench.mjs`:\n\n" +
        "  * Install the TypeScript compiler the engine already depends on:\n" +
        "      cd assets && yarn install\n" +
        "    (or, without touching yarn.lock: npm install typescript --no-save)\n\n" +
        "  * Upgrade Node to a version with built-in TypeScript stripping:\n" +
        "      Node >=23.6 needs no flag; Node 22.6-23.5 needs:\n" +
        "      node --experimental-strip-types dev/layout-bench.mjs\n\n",
    );
    process.exit(1);
  }
  // Silence the cosmetic "add type: module to package.json" warning the
  // native strategy triggers for every .ts file in this repo (assets/
  // package.json is owned by other work; this is not our call to make and
  // it doesn't affect correctness).
  process.on("warning", (w) => {
    if (
      w.name === "Warning" &&
      /MODULE_TYPELESS_PACKAGE_JSON/.test(String(w.message ?? ""))
    )
      return;
    console.error(w);
  });
  const mod = await import(pathToFileURL(LAYOUT_INDEX));
  return { mod, strategy };
}

// ---------------------------------------------------------------------------
// Deterministic PRNG (mulberry32, seeded from a string via FNV-1a)
// ---------------------------------------------------------------------------

function hashSeed(str) {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

const orient = (p, q, r) =>
  Math.sign((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x));
const onSeg = (p, q, r) =>
  Math.min(p.x, r.x) <= q.x &&
  q.x <= Math.max(p.x, r.x) &&
  Math.min(p.y, r.y) <= q.y &&
  q.y <= Math.max(p.y, r.y);

/** Proper segment intersection (including collinear overlap), CCW-orientation based. */
function segmentsIntersect(p1, p2, p3, p4) {
  const o1 = orient(p1, p2, p3);
  const o2 = orient(p1, p2, p4);
  const o3 = orient(p3, p4, p1);
  const o4 = orient(p3, p4, p2);
  if (o1 !== o2 && o3 !== o4) return true;
  if (o1 === 0 && onSeg(p1, p3, p2)) return true;
  if (o2 === 0 && onSeg(p1, p4, p2)) return true;
  if (o3 === 0 && onSeg(p3, p1, p4)) return true;
  if (o4 === 0 && onSeg(p3, p2, p4)) return true;
  return false;
}

// CHEWY PATCH: two geometric rules the crossings/overlaps metrics above
// never checked — "lines can intersect but must never fully overlap in a
// way that hides a connection". Both work in CELL space (col = x/CELL_W,
// row = y/CELL_H), not pixels, per the fixture that exposed the bug.
const OVERLAP_EPS = 1e-6;

const toCell = (p, CELL_W, CELL_H) => ({ x: p.x / CELL_W, y: p.y / CELL_H });

/** Edge segments in CELL space, skipping self-loops and zero-length edges
 *  (a degenerate point can never "hide" a connection, so it is excluded
 *  from both rules below rather than falsely matching everything). */
function overlapSegs(edges, finalPos, CELL_W, CELL_H) {
  const segs = [];
  for (const e of edges) {
    const p1 = finalPos.get(e.source);
    const p2 = finalPos.get(e.target);
    if (!p1 || !p2 || e.source === e.target) continue;
    const c1 = toCell(p1, CELL_W, CELL_H);
    const c2 = toCell(p2, CELL_W, CELL_H);
    if (
      Math.abs(c1.x - c2.x) < OVERLAP_EPS &&
      Math.abs(c1.y - c2.y) < OVERLAP_EPS
    )
      continue;
    segs.push({ source: e.source, target: e.target, p1: c1, p2: c2 });
  }
  return segs;
}

/** Length of the shared stretch of two COLLINEAR segments' 1-D projections
 *  onto their common line; 0 (or negative) if they only touch at a single
 *  point or don't touch at all. A single shared endpoint (two edges
 *  fanning out from the same node) projects to a zero-length intersection
 *  and is correctly NOT an overlap; anything sharing more than that single
 *  point — including one edge being a subset of the other, e.g. a
 *  duplicate edge between the same two nodes — returns a positive length. */
function collinearOverlapLength(a, b) {
  const d1x = a.p2.x - a.p1.x;
  const d1y = a.p2.y - a.p1.y;
  const d2x = b.p2.x - b.p1.x;
  const d2y = b.p2.y - b.p1.y;
  if (Math.abs(d1x * d2y - d1y * d2x) > OVERLAP_EPS) return 0; // not parallel
  const vx = b.p1.x - a.p1.x;
  const vy = b.p1.y - a.p1.y;
  if (Math.abs(d1x * vy - d1y * vx) > OVERLAP_EPS) return 0; // parallel, different line
  const useX = Math.abs(d1x) >= Math.abs(d1y);
  const aLo = useX ? Math.min(a.p1.x, a.p2.x) : Math.min(a.p1.y, a.p2.y);
  const aHi = useX ? Math.max(a.p1.x, a.p2.x) : Math.max(a.p1.y, a.p2.y);
  const bLo = useX ? Math.min(b.p1.x, b.p2.x) : Math.min(b.p1.y, b.p2.y);
  const bHi = useX ? Math.max(b.p1.x, b.p2.x) : Math.max(b.p1.y, b.p2.y);
  return Math.min(aHi, bHi) - Math.max(aLo, bLo);
}

/** Rule 1: unordered edge pairs whose segments are collinear and share a
 *  positive-length stretch (CELL space). Counts each pair exactly once. */
function edgeOverlapPairs(edges, finalPos, CELL_W, CELL_H) {
  const segs = overlapSegs(edges, finalPos, CELL_W, CELL_H);
  let pairs = 0;
  for (let i = 0; i < segs.length; i++)
    for (let j = i + 1; j < segs.length; j++)
      if (collinearOverlapLength(segs[i], segs[j]) > OVERLAP_EPS) pairs++;
  return pairs;
}

/** Node box size in px (assets/.../layout/types.ts NODE_W_PX/NODE_H_PX): the
 *  map draws every system as this box and every connection as a straight
 *  centre-to-centre line under it. */
const NODE_W_PX = 130;
const NODE_H_PX = 34;

/** Rule 2: a node "occludes" an edge when the edge's drawn line passes
 *  through that node's RENDERED BOX and the node is not one of the edge's
 *  own endpoints (CELL space; the box is the same rect around every node, so
 *  the centre offset cancels — see layout/geometry.ts, which the engine uses
 *  and this metric must agree with).
 *
 *  This used to be "the node's centre lies exactly on the segment", which
 *  only fires when a node lands precisely on the line: the live production
 *  map `yugen` scored 0 under that rule while six of its connections ran
 *  under a node box. */
function nodeOcclusions(nodeIds, edges, finalPos, CELL_W, CELL_H) {
  const segs = overlapSegs(edges, finalPos, CELL_W, CELL_H);
  const halfW = NODE_W_PX / 2 / CELL_W;
  const halfH = NODE_H_PX / 2 / CELL_H;
  let count = 0;
  for (const id of nodeIds) {
    const p = finalPos.get(id);
    if (!p) continue;
    const c = toCell(p, CELL_W, CELL_H);
    for (const s of segs) {
      if (id === s.source || id === s.target) continue;
      const dx = s.p2.x - s.p1.x;
      const dy = s.p2.y - s.p1.y;
      // Liang-Barsky clip of the segment against the node's box.
      const ps = [-dx, dx, -dy, dy];
      const qs = [
        s.p1.x - (c.x - halfW),
        c.x + halfW - s.p1.x,
        s.p1.y - (c.y - halfH),
        c.y + halfH - s.p1.y,
      ];
      let t0 = 0;
      let t1 = 1;
      let outside = false;
      for (let i = 0; i < 4; i++) {
        if (ps[i] === 0) {
          if (qs[i] < 0) {
            outside = true;
            break;
          }
          continue;
        }
        const t = qs[i] / ps[i];
        if (ps[i] < 0) {
          if (t > t1) {
            outside = true;
            break;
          }
          if (t > t0) t0 = t;
        } else {
          if (t < t0) {
            outside = true;
            break;
          }
          if (t < t1) t1 = t;
        }
      }
      if (!outside && t1 > t0) count++;
    }
  }
  return count;
}

/** Prim's MST over (col,row) points; returns [id,id] edge pairs. */
function buildMST(points) {
  const n = points.length;
  if (n < 2) return [];
  const inTree = new Array(n).fill(false);
  const minDist = new Array(n).fill(Infinity);
  const parent = new Array(n).fill(-1);
  minDist[0] = 0;
  const edges = [];
  for (let iter = 0; iter < n; iter++) {
    let u = -1;
    let best = Infinity;
    for (let i = 0; i < n; i++) {
      if (!inTree[i] && minDist[i] < best) {
        best = minDist[i];
        u = i;
      }
    }
    inTree[u] = true;
    if (parent[u] !== -1) edges.push([points[parent[u]].id, points[u].id]);
    for (let v = 0; v < n; v++) {
      if (inTree[v]) continue;
      const d = Math.hypot(
        points[u].col - points[v].col,
        points[u].row - points[v].row,
      );
      if (d < minDist[v]) {
        minDist[v] = d;
        parent[v] = u;
      }
    }
  }
  return edges;
}

/** Shortest `cap` non-MST pairs, for a few realistic redundant gates/loops. */
function extraShortcuts(points, existingKeys, cap) {
  const cands = [];
  for (let i = 0; i < points.length; i++) {
    for (let j = i + 1; j < points.length; j++) {
      const a = points[i];
      const b = points[j];
      const key = a.id < b.id ? `${a.id}|${b.id}` : `${b.id}|${a.id}`;
      if (existingKeys.has(key)) continue;
      const d = Math.hypot(a.col - b.col, a.row - b.row);
      cands.push({ a: a.id, b: b.id, d, key });
    }
  }
  cands.sort((x, y) => x.d - y.d || (x.key < y.key ? -1 : 1));
  return cands.slice(0, cap);
}

// ---------------------------------------------------------------------------
// lib/wanderer_app/dev/seed.ex parser (source of truth for the "yugen" map)
// ---------------------------------------------------------------------------

function extractElixirListBlock(src, attrName) {
  const marker = `@${attrName} [`;
  const startIdx = src.indexOf(marker);
  if (startIdx === -1)
    throw new Error(
      `seed.ex: @${attrName} not found — has the seeder module moved/renamed it?`,
    );
  const openBracket = src.indexOf("[", startIdx);
  let depth = 0;
  for (let j = openBracket; j < src.length; j++) {
    if (src[j] === "[") depth++;
    else if (src[j] === "]") {
      depth--;
      if (depth === 0) return src.slice(openBracket + 1, j);
    }
  }
  throw new Error(`seed.ex: @${attrName} block never closes`);
}

const parseElixirInt = (s) => parseInt(s.replace(/_/g, ""), 10);

function parseYugenSeed() {
  const src = readFileSync(SEED_EX, "utf8");
  const tuple3 = /\{\s*(-?[\d_]+)\s*,\s*(-?[\d_]+)\s*,\s*(-?[\d_]+)\s*\}/g;

  const systemsBlock = extractElixirListBlock(src, "systems");
  const nodes = [];
  for (const m of systemsBlock.matchAll(tuple3)) {
    nodes.push({
      id: String(parseElixirInt(m[1])),
      x: parseElixirInt(m[2]),
      y: parseElixirInt(m[3]),
      locked: false,
    });
  }

  const connectionsBlock = extractElixirListBlock(src, "connections");
  const edges = [];
  for (const m of connectionsBlock.matchAll(tuple3)) {
    edges.push({
      source: String(parseElixirInt(m[1])),
      target: String(parseElixirInt(m[2])),
      type: parseElixirInt(m[3]),
    });
  }

  if (nodes.length === 0 || edges.length === 0) {
    throw new Error(
      "seed.ex parser produced an empty graph — the module attribute format may have changed.",
    );
  }
  return { nodes, edges };
}

// ---------------------------------------------------------------------------
// Region lattice (data/regionLayouts.json) — read directly for scenario
// construction / stability extension (the engine loads its own copy at
// runtime via dynamic import; this is an independent read for benchmark
// bookkeeping only).
// ---------------------------------------------------------------------------

function loadRegionSystems() {
  const data = JSON.parse(readFileSync(REGION_LAYOUTS_JSON, "utf8"));
  return data.systems; // solarSystemId (string) -> [col, row]
}

function nearestUnused(systems, anchorId, count, excludeSet) {
  const [ac, ar] = systems[anchorId];
  const cands = [];
  for (const [id, [c, r]] of Object.entries(systems)) {
    if (excludeSet.has(id)) continue;
    cands.push({ id, col: c, row: r, d: Math.hypot(c - ac, r - ar) });
  }
  cands.sort((a, b) => a.d - b.d || (a.id < b.id ? -1 : 1));
  return cands.slice(0, count);
}

// ---------------------------------------------------------------------------
// Scenario builders
// ---------------------------------------------------------------------------

function buildYugenScenario() {
  const { nodes, edges } = parseYugenSeed();
  return { name: "yugen", nodes, edges };
}

function buildChainScenario() {
  const nodes = [];
  const edges = [];
  const addNode = (id, x, y, extra = {}) =>
    nodes.push({ id, x, y, locked: false, ...extra });
  const addEdge = (source, target, type) =>
    edges.push({ source, target, type });

  addNode("chain-root", 0, 0);

  // Branch A: depth 4, wormhole classes cycling 1-4.
  const aIds = ["chain-a1", "chain-a2", "chain-a3", "chain-a4"];
  aIds.forEach((id, i) =>
    addNode(id, 200 + i * 37, 50 + i * 23, { systemClass: 1 + i }),
  );
  addEdge("chain-root", aIds[0], 0);
  for (let i = 1; i < aIds.length; i++) addEdge(aIds[i - 1], aIds[i], 0);

  // Branch B: depth 2, wormhole classes 5-6.
  const bIds = ["chain-b1", "chain-b2"];
  bIds.forEach((id, i) =>
    addNode(id, -150 - i * 41, 80 + i * 29, { systemClass: 5 + i }),
  );
  addEdge("chain-root", bIds[0], 0);
  for (let i = 1; i < bIds.length; i++) addEdge(bIds[i - 1], bIds[i], 0);

  // Branch C: depth 3, wormhole classes cycling 1-3.
  const cIds = ["chain-c1", "chain-c2", "chain-c3"];
  cIds.forEach((id, i) =>
    addNode(id, 30 - i * 53, -180 - i * 31, { systemClass: 1 + i }),
  );
  addEdge("chain-root", cIds[0], 0);
  for (let i = 1; i < cIds.length; i++) addEdge(cIds[i - 1], cIds[i], 0);

  // One K162 loop-back edge: a non-tree wormhole link between two already-
  // connected chain nodes (never consulted for geometry by the engine, but
  // exercises sanitizeEdges/pickChainRoot degree counting).
  addEdge(aIds[3], cIds[2], 0);

  // One k-space exit: a highsec system hanging directly off the root via a
  // fresh wormhole (systemClass 7 = hs, per chainLayout.ts's KNOWN_SPACE_CLASS_IDS).
  addNode("chain-ks-exit", 400, -60, { systemClass: 7, security: 0.5 });
  addEdge("chain-root", "chain-ks-exit", 0);

  return { name: "chain", nodes, edges };
}

// Anchors: Jita (The Forge), Amarr (Domain), Rens (Heimatar) — three
// well-known, widely-separated k-space hubs; ids/cells are real, read
// straight out of data/regionLayouts.json (Dotlan-derived global lattice).
const KSPACE_WIDE_ANCHORS = [
  { id: "30000142", label: "Jita/TheForge", count: 14 },
  { id: "30002187", label: "Amarr/Domain", count: 13 },
  { id: "30002510", label: "Rens/Heimatar", count: 13 },
];

function scrambledPixel(col, row) {
  // Deliberately NOT grid-aligned and NOT the eventual beautified layout —
  // just a deterministic "somebody dragged these onto the map ad hoc" stand-in.
  return { x: col * 47 + 131, y: row * 31 + 59 };
}

function buildKspaceWideScenario(regionSystems) {
  const excludeSet = new Set();
  const clusters = KSPACE_WIDE_ANCHORS.map(({ id, count }) => {
    const picked = nearestUnused(regionSystems, id, count, excludeSet);
    for (const p of picked) excludeSet.add(p.id);
    return picked;
  });

  const edges = [];
  for (const cluster of clusters) {
    const mst = buildMST(cluster);
    const keys = new Set(
      mst.map(([a, b]) => (a < b ? `${a}|${b}` : `${b}|${a}`)),
    );
    const extra = extraShortcuts(cluster, keys, 2);
    for (const [a, b] of mst) edges.push({ source: a, target: b, type: 1 });
    for (const e of extra) edges.push({ source: e.a, target: e.b, type: 1 });
  }
  // Bridge adjacent clusters so kspace-wide is one connected component,
  // same as real adjacent regions being linked by a handful of gates.
  for (let i = 0; i < clusters.length - 1; i++) {
    let best = null;
    for (const p of clusters[i]) {
      for (const q of clusters[i + 1]) {
        const d = Math.hypot(p.col - q.col, p.row - q.row);
        if (!best || d < best.d) best = { a: p.id, b: q.id, d };
      }
    }
    edges.push({ source: best.a, target: best.b, type: 1 });
  }

  const nodes = clusters.flat().map((p) => {
    const { x, y } = scrambledPixel(p.col, p.row);
    return { id: p.id, x, y, locked: false };
  });

  return { name: "kspace-wide", nodes, edges };
}

function buildMixedScenario(kspaceWide) {
  const nodes = structuredClone(kspaceWide.nodes);
  const edges = structuredClone(kspaceWide.edges);
  const sortedIds = nodes.map((n) => n.id).sort();
  const attachId = sortedIds[Math.floor(sortedIds.length / 2)];
  const attachNode = nodes.find((n) => n.id === attachId);

  const chainIds = Array.from({ length: 10 }, (_, i) => `mixed-chain-${i + 1}`);
  chainIds.forEach((id, i) => {
    const dx = 60 + i * 19 * (i % 2 === 0 ? 1 : -1);
    const dy = 45 + i * 17;
    nodes.push({
      id,
      x: attachNode.x + dx,
      y: attachNode.y + dy,
      locked: false,
      systemClass: 1 + (i % 6),
    });
  });
  edges.push({ source: attachId, target: chainIds[0], type: 0 });
  for (let i = 1; i < chainIds.length; i++)
    edges.push({ source: chainIds[i - 1], target: chainIds[i], type: 0 });

  return { name: "mixed", nodes, edges };
}

// CHEWY PATCH: regression fixture captured verbatim from the LIVE production
// map "yugen" (29 systems, 32 connections) on the day a user reported that a
// wormhole link to Raihbaka was invisible. The snapshot contains BOTH defects
// the rules above exist to catch, twice over:
//   Ibani->Raihbaka   (wormhole) hidden inside Irmalin->Ibani   (gate), Raihbaka on the line
//   Gebuladi->Gomati  (wormhole) hidden inside Eszur->Gebuladi  (gate), Gomati   on the line
// A real map of realistic size, so its stability numbers mean the same thing
// as every other scenario here (a 4-node fixture reads one moved node as
// movedFrac 1.00 and is useless for the stability thresholds).
function buildOcclusionScenario() {
  const nodes = [
    { id: "30002093", x: 360, y: 225, locked: false },
    { id: "30002094", x: 900, y: 225, locked: false },
    { id: "30002095", x: 720, y: 225, locked: false },
    { id: "30002099", x: 1260, y: -375, locked: false },
    { id: "30002100", x: 1260, y: -300, locked: false },
    { id: "30002101", x: 900, y: -150, locked: false },
    { id: "30002102", x: 1620, y: -150, locked: false },
    { id: "30002515", x: 1620, y: 0, locked: false },
    { id: "30002517", x: 540, y: -225, locked: false },
    { id: "30002537", x: 1080, y: -75, locked: false },
    { id: "30002539", x: 360, y: 150, locked: false },
    { id: "30002540", x: 1260, y: 75, locked: false },
    { id: "30002541", x: 1800, y: 150, locked: false },
    { id: "30002542", x: 1620, y: -75, locked: false },
    { id: "30002983", x: 540, y: 300, locked: false },
    { id: "30003068", x: 2160, y: 450, locked: false },
    { id: "30003571", x: 0, y: 150, locked: false },
    { id: "30003930", x: -360, y: 525, locked: false },
    { id: "30003932", x: -540, y: 600, locked: false },
    { id: "30003933", x: -540, y: 675, locked: false },
    { id: "30003935", x: -180, y: 675, locked: false },
    { id: "30005212", x: 1260, y: 0, locked: false },
    { id: "30045315", x: -360, y: 675, locked: false },
    { id: "31000126", x: 720, y: -225, locked: false },
    { id: "31001021", x: 180, y: 150, locked: false },
    { id: "30000070", x: 540, y: 225, locked: false },
    { id: "30002090", x: 720, y: 0, locked: false },
    { id: "30002091", x: 180, y: 75, locked: false },
    { id: "30002092", x: 1080, y: 75, locked: false },
  ];
  const edges = [
    { source: "30002540", target: "30002541", type: 1 },
    { source: "30002541", target: "30002542", type: 1 },
    { source: "30002542", target: "30002537", type: 1 },
    { source: "30002541", target: "30002537", type: 1 },
    { source: "30002542", target: "30002515", type: 0 },
    { source: "30002542", target: "30003068", type: 1 },
    { source: "30002542", target: "30002539", type: 1 },
    { source: "30002539", target: "30002537", type: 1 },
    { source: "30002541", target: "30002539", type: 1 },
    { source: "30002539", target: "30002095", type: 1 },
    { source: "30002095", target: "30002093", type: 1 },
    { source: "30002093", target: "30000070", type: 0 },
    { source: "30002093", target: "30002983", type: 0 },
    { source: "30002093", target: "30002091", type: 1 },
    { source: "30002091", target: "30002090", type: 1 },
    { source: "30002090", target: "30002092", type: 1 },
    { source: "30002092", target: "30002094", type: 1 },
    { source: "30002092", target: "30005212", type: 0 },
    { source: "30002094", target: "30002095", type: 1 },
    { source: "30002539", target: "31001021", type: 0 },
    { source: "31001021", target: "30003571", type: 0 },
    { source: "30002517", target: "30002099", type: 1 },
    { source: "30002099", target: "30002100", type: 1 },
    { source: "30002100", target: "30002101", type: 1 },
    { source: "30002537", target: "30002517", type: 1 },
    { source: "30002101", target: "30002102", type: 1 },
    { source: "30002102", target: "30002100", type: 1 },
    { source: "30002517", target: "31000126", type: 0 },
    { source: "30003935", target: "30003933", type: 1 },
    { source: "30003933", target: "30045315", type: 0 },
    { source: "30003933", target: "30003932", type: 1 },
    { source: "30003932", target: "30003930", type: 1 },
  ];
  return { name: "occlusion", nodes, edges };
}

// ---------------------------------------------------------------------------
// Quality metrics
// ---------------------------------------------------------------------------

function mergeFinalPositions(nodes, result) {
  const m = new Map();
  for (const n of nodes) m.set(n.id, { x: n.x, y: n.y });
  for (const [id, p] of Object.entries(result.positions)) m.set(id, p);
  return m;
}

const cellDist = (dxPix, dyPix, CELL_W, CELL_H) =>
  Math.hypot(dxPix / CELL_W, dyPix / CELL_H);

function edgeStats(values) {
  if (values.length === 0) return { mean: 0, max: 0 };
  return {
    mean: values.reduce((a, b) => a + b, 0) / values.length,
    max: Math.max(...values),
  };
}

/** CHEWY PATCH: minimum Chebyshev cell distance between a chain-only system
 *  (one with no gate edge on this map — the engine's own k-space/chain split)
 *  and any gate-connected system. Infinity when either side is empty. */
function chainClearanceCells(nodes, edges, finalPos, CELL_W, CELL_H) {
  const latticeIds = new Set();
  for (const e of edges) {
    if (e.type !== 1) continue;
    latticeIds.add(e.source);
    latticeIds.add(e.target);
  }
  const cellOf = (id) => {
    const p = finalPos.get(id);
    return p ? { col: p.x / CELL_W, row: p.y / CELL_H } : null;
  };
  let min = Infinity;
  for (const node of nodes) {
    if (latticeIds.has(node.id)) continue;
    const a = cellOf(node.id);
    if (!a) continue;
    for (const latticeId of latticeIds) {
      const b = cellOf(latticeId);
      if (!b) continue;
      min = Math.min(min, Math.max(Math.abs(a.col - b.col), Math.abs(a.row - b.row)));
    }
  }
  return min;
}

function computeQuality(nodes, edges, finalPos, CELL_W, CELL_H) {
  const ids = [...finalPos.keys()];

  let overlaps = 0;
  const seenKeys = new Set();
  for (const id of ids) {
    const p = finalPos.get(id);
    const key = `${p.x},${p.y}`;
    if (seenKeys.has(key)) overlaps++;
    else seenKeys.add(key);
  }

  let offGrid = 0;
  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  for (const id of ids) {
    const p = finalPos.get(id);
    if (p.x % CELL_W !== 0 || p.y % CELL_H !== 0) offGrid++;
    minX = Math.min(minX, p.x);
    maxX = Math.max(maxX, p.x);
    minY = Math.min(minY, p.y);
    maxY = Math.max(maxY, p.y);
  }
  const spanCols = Math.round((maxX - minX) / CELL_W) + 1;
  const spanRows = Math.round((maxY - minY) / CELL_H) + 1;

  const segs = [];
  for (const e of edges) {
    const p1 = finalPos.get(e.source);
    const p2 = finalPos.get(e.target);
    if (p1 && p2 && e.source !== e.target)
      segs.push({ source: e.source, target: e.target, type: e.type, p1, p2 });
  }

  let crossings = 0;
  for (let i = 0; i < segs.length; i++) {
    for (let j = i + 1; j < segs.length; j++) {
      const a = segs[i];
      const b = segs[j];
      if (
        a.source === b.source ||
        a.source === b.target ||
        a.target === b.source ||
        a.target === b.target
      )
        continue;
      if (segmentsIntersect(a.p1, a.p2, b.p1, b.p2)) crossings++;
    }
  }

  const gateLens = [];
  const whLens = [];
  for (const s of segs) {
    const d = cellDist(s.p2.x - s.p1.x, s.p2.y - s.p1.y, CELL_W, CELL_H);
    if (s.type === 1) gateLens.push(d);
    else if (s.type === 0) whLens.push(d);
  }

  return {
    crossings,
    overlaps,
    spanCols,
    spanRows,
    offGrid,
    gateEdgeCells: edgeStats(gateLens),
    wormholeEdgeCells: edgeStats(whLens),
    // CHEWY PATCH: lines can cross but must never fully hide a connection —
    // see the geometry helpers above segmentsIntersect for the exact rules.
    edgeOverlapPairs: edgeOverlapPairs(edges, finalPos, CELL_W, CELL_H),
    nodeOcclusions: nodeOcclusions(ids, edges, finalPos, CELL_W, CELL_H),
    // CHEWY PATCH: total drawn edge length in cells — the repair pass's
    // tie-breaker term (pack.ts LENGTH_WEIGHT), tracked so "fixed an
    // occlusion by flinging a node across the map" shows up as a regression.
    totalEdgeCells: segs.reduce(
      (sum, s) => sum + cellDist(s.p2.x - s.p1.x, s.p2.y - s.p1.y, CELL_W, CELL_H),
      0,
    ),
    // CHEWY PATCH: how close the nearest wormhole-chain system gets to a
    // k-space system it isn't attached to, in cells (Chebyshev). This is what
    // BeautifyOptions.chainStandoff buys: the whole point of a pocket is that
    // the chain does NOT sit on the Dotlan-geometry lattice the map is read by.
    // Infinity when the scenario has no chain-only nodes or no gate edges.
    chainClearanceCells: chainClearanceCells(nodes, edges, finalPos, CELL_W, CELL_H),
  };
}

async function checkDeterminism(beautifyLayout, nodes, edges, options) {
  const r1 = await beautifyLayout(
    structuredClone(nodes),
    structuredClone(edges),
    structuredClone(options),
  );
  const r2 = await beautifyLayout(
    structuredClone(nodes),
    structuredClone(edges),
    structuredClone(options),
  );
  return { ok: JSON.stringify(r1) === JSON.stringify(r2), result: r1 };
}

// ---------------------------------------------------------------------------
// Stability metrics
// ---------------------------------------------------------------------------

function rankInversionCount(commonIds, P1, P2) {
  let count = 0;
  for (let i = 0; i < commonIds.length; i++) {
    for (let j = i + 1; j < commonIds.length; j++) {
      const a = commonIds[i];
      const b = commonIds[j];
      const p1a = P1.get(a);
      const p1b = P1.get(b);
      const p2a = P2.get(a);
      const p2b = P2.get(b);
      const sx1 = Math.sign(p1a.x - p1b.x);
      const sx2 = Math.sign(p2a.x - p2b.x);
      const sy1 = Math.sign(p1a.y - p1b.y);
      const sy2 = Math.sign(p2a.y - p2b.y);
      const xFlip = sx1 !== 0 && sx2 !== 0 && sx1 !== sx2;
      const yFlip = sy1 !== 0 && sy2 !== 0 && sy1 !== sy2;
      if (xFlip || yFlip) count++;
    }
  }
  return count;
}

function shiftStats(commonIds, P1, P2, CELL_W, CELL_H) {
  let moved = 0;
  let sum = 0;
  let max = 0;
  for (const id of commonIds) {
    const a = P1.get(id);
    const b = P2.get(id);
    const d = cellDist(b.x - a.x, b.y - a.y, CELL_W, CELL_H);
    if (d > 1e-9) moved++;
    sum += d;
    max = Math.max(max, d);
  }
  return {
    movedFraction: moved / commonIds.length,
    meanShiftCells: sum / commonIds.length,
    maxShiftCells: max,
  };
}

/** Nodes with `x`/`y` overridden from `positions` (every other field — `locked`, `systemClass`, etc. — kept as-is). This is exactly what the app does: the server persists a beautify's output, the client re-reads it as the new "current position". */
function withPositions(nodes, positions) {
  return nodes.map((n) => {
    const p = positions.get(n.id);
    return p ? { ...n, x: p.x, y: p.y } : structuredClone(n);
  });
}

/** Adds `k` plausible-but-unbeautified new systems to a cloned copy of `graph` (`graph.nodes`/`graph.edges`/`graph.name` — either the raw scenario, for the "cold" measurement, or the scenario's own beautified P1 output, for the "round-trip" measurement). Also returns `added`: `{ id, baseId, x, y }` for each new node — its raw drop position and the pre-existing node it was attached to — so callers can judge where the new nodes themselves ended up. */
function extendGraph(scenario, prng, k, regionSystems, kLabel, repeatIndex) {
  const nodes = structuredClone(scenario.nodes);
  const edges = structuredClone(scenario.edges);
  const baseIds = nodes.map((n) => n.id).sort();
  const usedSystemIds = new Set(baseIds);
  const added = [];

  for (let i = 0; i < k; i++) {
    const baseId = baseIds[Math.floor(prng() * baseIds.length)];
    const baseNode = nodes.find((n) => n.id === baseId);
    const isKSpace = regionSystems[baseId] !== undefined;

    if (isKSpace) {
      const [best] = nearestUnused(regionSystems, baseId, 1, usedSystemIds);
      if (!best) continue; // exhausted the lattice (never happens in practice: 5000+ entries)
      usedSystemIds.add(best.id);
      const jx = Math.round((prng() - 0.5) * 80);
      const jy = Math.round((prng() - 0.5) * 80);
      const x = baseNode.x + jx;
      const y = baseNode.y + jy;
      nodes.push({ id: best.id, x, y, locked: false });
      edges.push({ source: baseId, target: best.id, type: 1 });
      added.push({ id: best.id, baseId, x, y });
    } else {
      const newId = `${scenario.name}-ext-k${kLabel}-r${repeatIndex}-${i}`;
      const cls = 1 + Math.floor(prng() * 6);
      const jx = Math.round((prng() - 0.5) * 300);
      const jy = Math.round((prng() - 0.5) * 300);
      const x = baseNode.x + jx;
      const y = baseNode.y + jy;
      usedSystemIds.add(newId);
      nodes.push({
        id: newId,
        x,
        y,
        locked: false,
        systemClass: cls,
      });
      edges.push({ source: baseId, target: newId, type: 0 });
      added.push({ id: newId, baseId, x, y });
    }
  }
  return { nodes, edges, added };
}

// CHEWY PATCH: the round-trip metrics above this point only ever looked at
// how much the PRE-EXISTING nodes moved — a newly added node could be left
// exactly where it was dropped, off-grid, far from the map, and every one
// of those numbers would still read a perfect 0. This checks the k newly
// added nodes themselves: are they on-grid, did the engine actually move
// them at all, and did they land near the already-placed neighbour they
// were attached to.
function newNodeMetrics(added, P2, CELL_W, CELL_H) {
  let offGrid = 0;
  let unplaced = 0;
  const anchorDists = [];
  for (const a of added) {
    const p = P2.get(a.id);
    if (p.x % CELL_W !== 0 || p.y % CELL_H !== 0) offGrid++;
    if (p.x === a.x && p.y === a.y) unplaced++;
    const anchor = P2.get(a.baseId);
    if (anchor) {
      anchorDists.push(
        cellDist(p.x - anchor.x, p.y - anchor.y, CELL_W, CELL_H),
      );
    }
  }
  return { offGrid, unplaced, anchorDists };
}

const K_VALUES = [1, 3, 5];
const REPEATS = 10;

/** Beautify an already-beautified, UNCHANGED map again; nothing should move. */
async function runIdempotence(
  beautifyLayout,
  scenario,
  P1positions,
  CELL_W,
  CELL_H,
) {
  const beautifiedNodes = withPositions(scenario.nodes, P1positions);
  const result = await beautifyLayout(
    structuredClone(beautifiedNodes),
    structuredClone(scenario.edges),
    {},
  );
  const again = mergeFinalPositions(beautifiedNodes, result);
  const baseIds = scenario.nodes.map((n) => n.id);
  const shift = shiftStats(baseIds, P1positions, again, CELL_W, CELL_H);
  return { movedFraction: shift.movedFraction, mode: result.mode };
}

async function runStability(
  beautifyLayout,
  scenario,
  regionSystems,
  CELL_W,
  CELL_H,
  P1positions,
) {
  const beautifiedNodes = withPositions(scenario.nodes, P1positions);
  const baseIds = scenario.nodes.map((n) => n.id);

  const roundTrip = {};
  const cold = {};
  for (const k of K_VALUES) {
    const rtRepeats = [];
    const coldRepeats = [];
    for (let r = 0; r < REPEATS; r++) {
      // Round-trip (the number that matters): grow the map the app itself
      // hands back to the engine — P1's OWN OUTPUT positions plus k new,
      // still-unbeautified systems — then re-beautify with default
      // options (mode: 'auto').
      const rtPrng = mulberry32(
        hashSeed(`${scenario.name}:${k}:${r}:roundtrip`),
      );
      const rtGraph = {
        name: scenario.name,
        nodes: beautifiedNodes,
        edges: scenario.edges,
      };
      const rtEnlarged = extendGraph(rtGraph, rtPrng, k, regionSystems, k, r);
      const rtResult = await beautifyLayout(
        structuredClone(rtEnlarged.nodes),
        structuredClone(rtEnlarged.edges),
        {},
      );
      const rtP2 = mergeFinalPositions(rtEnlarged.nodes, rtResult);
      const rtShift = shiftStats(baseIds, P1positions, rtP2, CELL_W, CELL_H);
      const rtInv = rankInversionCount(baseIds, P1positions, rtP2);
      // CHEWY PATCH: how did the k NEWLY ADDED nodes themselves land?
      const rtNew = newNodeMetrics(rtEnlarged.added, rtP2, CELL_W, CELL_H);
      // CHEWY PATCH: did inserting the k new nodes/edges make any edge hide
      // another, or drop a node onto an edge it isn't an endpoint of?
      const rtOverlapPairs = edgeOverlapPairs(
        rtEnlarged.edges,
        rtP2,
        CELL_W,
        CELL_H,
      );
      const rtOcclusions = nodeOcclusions(
        rtEnlarged.nodes.map((n) => n.id),
        rtEnlarged.edges,
        rtP2,
        CELL_W,
        CELL_H,
      );
      rtRepeats.push({
        ...rtShift,
        rankInversions: rtInv,
        mode: rtResult.mode,
        newOffGrid: rtNew.offGrid,
        newUnplaced: rtNew.unplaced,
        newAnchorDists: rtNew.anchorDists,
        edgeOverlapPairs: rtOverlapPairs,
        nodeOcclusions: rtOcclusions,
      });

      // Cold (still meaningful, NOT the primary number): grow the RAW,
      // never-beautified scenario nodes — the original measurement,
      // renamed honestly. `'auto'` always resolves `'full'` here.
      const coldPrng = mulberry32(hashSeed(`${scenario.name}:${k}:${r}`));
      const coldEnlarged = extendGraph(
        scenario,
        coldPrng,
        k,
        regionSystems,
        k,
        r,
      );
      const coldResult = await beautifyLayout(
        structuredClone(coldEnlarged.nodes),
        structuredClone(coldEnlarged.edges),
        {},
      );
      const coldP2 = mergeFinalPositions(coldEnlarged.nodes, coldResult);
      const coldShift = shiftStats(
        baseIds,
        P1positions,
        coldP2,
        CELL_W,
        CELL_H,
      );
      const coldInv = rankInversionCount(baseIds, P1positions, coldP2);
      coldRepeats.push({ ...coldShift, rankInversions: coldInv });
    }
    const avg = (arr, key) => arr.reduce((s, x) => s + x[key], 0) / arr.length;
    const mx = (arr, key) => Math.max(...arr.map((x) => x[key]));
    // CHEWY PATCH: newOffGrid/newUnplaced are hard invariants, summed
    // across all REPEATS (like overlaps/offGrid at the quality level —
    // any nonzero count is a failure, not a rate to average away).
    // newAnchorCells pools every newly added node's distance to its
    // attach-point across all REPEATS into one mean/max, same shape as
    // gateEdgeCells/wormholeEdgeCells.
    const newOffGrid = rtRepeats.reduce((s, x) => s + x.newOffGrid, 0);
    const newUnplaced = rtRepeats.reduce((s, x) => s + x.newUnplaced, 0);
    const newAnchorCells = edgeStats(
      rtRepeats.flatMap((x) => x.newAnchorDists),
    );
    // CHEWY PATCH: edgeOverlapPairs/nodeOcclusions are hard invariants too,
    // same summed-not-averaged treatment as newOffGrid/newUnplaced above —
    // a newly placed system must not hide, or be hidden behind, a
    // connection in any of the 10 repeats.
    const edgeOverlapPairsTotal = rtRepeats.reduce(
      (s, x) => s + x.edgeOverlapPairs,
      0,
    );
    const nodeOcclusionsTotal = rtRepeats.reduce(
      (s, x) => s + x.nodeOcclusions,
      0,
    );
    roundTrip[k] = {
      movedFraction: {
        mean: avg(rtRepeats, "movedFraction"),
        max: mx(rtRepeats, "movedFraction"),
      },
      meanShiftCells: {
        mean: avg(rtRepeats, "meanShiftCells"),
        max: mx(rtRepeats, "meanShiftCells"),
      },
      maxShiftCells: {
        mean: avg(rtRepeats, "maxShiftCells"),
        max: mx(rtRepeats, "maxShiftCells"),
      },
      rankInversions: {
        mean: avg(rtRepeats, "rankInversions"),
        max: mx(rtRepeats, "rankInversions"),
      },
      incrementalShare:
        rtRepeats.filter((x) => x.mode === "incremental").length /
        rtRepeats.length,
      newOffGrid,
      newUnplaced,
      newAnchorCells,
      edgeOverlapPairs: edgeOverlapPairsTotal,
      nodeOcclusions: nodeOcclusionsTotal,
    };
    cold[k] = {
      movedFraction: {
        mean: avg(coldRepeats, "movedFraction"),
        max: mx(coldRepeats, "movedFraction"),
      },
      meanShiftCells: {
        mean: avg(coldRepeats, "meanShiftCells"),
        max: mx(coldRepeats, "meanShiftCells"),
      },
      maxShiftCells: {
        mean: avg(coldRepeats, "maxShiftCells"),
        max: mx(coldRepeats, "maxShiftCells"),
      },
      rankInversions: {
        mean: avg(coldRepeats, "rankInversions"),
        max: mx(coldRepeats, "rankInversions"),
      },
    };
  }
  return { roundTrip, cold };
}

// ---------------------------------------------------------------------------
// Table rendering
// ---------------------------------------------------------------------------

function renderTable(headers, rows) {
  const widths = headers.map((h, i) =>
    Math.max(String(h).length, ...rows.map((r) => String(r[i]).length)),
  );
  const line = (cells) =>
    cells.map((c, i) => String(c).padEnd(widths[i])).join("  ");
  const out = [line(headers), widths.map((w) => "-".repeat(w)).join("  ")];
  for (const r of rows) out.push(line(r));
  return out.join("\n");
}

const fmt = (n) => (Number.isInteger(n) ? String(n) : n.toFixed(2));

function printQualityTable(scenarios) {
  const headers = [
    "scenario",
    "crossings",
    "overlaps",
    "spanCols",
    "spanRows",
    "gateMean",
    "gateMax",
    "whMean",
    "whMax",
    "offGrid",
    "edgeOverlap",
    "occlusion",
    "edgeLen",
    "chainClear",
    "determ.",
    "idempotent",
  ];
  const rows = scenarios.map((s) => [
    s.name,
    s.quality.crossings,
    s.quality.overlaps,
    s.quality.spanCols,
    s.quality.spanRows,
    fmt(s.quality.gateEdgeCells.mean),
    fmt(s.quality.gateEdgeCells.max),
    fmt(s.quality.wormholeEdgeCells.mean),
    fmt(s.quality.wormholeEdgeCells.max),
    s.quality.offGrid,
    s.quality.edgeOverlapPairs,
    s.quality.nodeOcclusions,
    fmt(s.quality.totalEdgeCells),
    Number.isFinite(s.quality.chainClearanceCells) ? fmt(s.quality.chainClearanceCells) : "-",
    s.determinism.ok ? "yes" : "NO",
    s.idempotent.movedFraction === 0
      ? "0"
      : `NO (${fmt(s.idempotent.movedFraction)})`,
  ]);
  console.log("\n== Quality ==\n");
  console.log(renderTable(headers, rows));
}

// Thresholds the round-trip number is judged against (see README).
const ROUND_TRIP_THRESHOLDS = {
  movedFraction: 0.15,
  meanShiftCells: 0.5,
  rankInversions: 2,
  // CHEWY PATCH: how close a newly added node must land to the
  // already-placed neighbour it was attached to.
  newAnchorCellsMean: 2.0,
  newAnchorCellsMax: 4,
};

function printRoundTripStabilityTable(scenarios) {
  const headers = [
    "scenario",
    "k",
    "movedFrac",
    "meanShift",
    "maxShift",
    "rankInv(mean)",
    "rankInv(max)",
    "incremental%",
    "newOffGrid",
    "newUnplaced",
    "newAnchor(mean)",
    "newAnchor(max)",
    "edgeOverlap",
    "occlusion",
  ];
  const rows = [];
  for (const s of scenarios) {
    for (const k of K_VALUES) {
      const st = s.stability.roundTrip[k];
      rows.push([
        s.name,
        k,
        fmt(st.movedFraction.mean),
        fmt(st.meanShiftCells.mean),
        fmt(st.maxShiftCells.mean),
        fmt(st.rankInversions.mean),
        fmt(st.rankInversions.max),
        `${Math.round(st.incrementalShare * 100)}%`,
        st.newOffGrid,
        st.newUnplaced,
        fmt(st.newAnchorCells.mean),
        fmt(st.newAnchorCells.max),
        st.edgeOverlapPairs,
        st.nodeOcclusions,
      ]);
    }
  }
  console.log(
    "\n== Stability — round-trip (beautify, add k systems, beautify again; THE number; mean over 10 repeats) ==\n",
  );
  console.log(renderTable(headers, rows));
}

function printColdStabilityTable(scenarios) {
  const headers = [
    "scenario",
    "k",
    "movedFrac",
    "meanShift",
    "maxShift",
    "rankInv(mean)",
    "rankInv(max)",
  ];
  const rows = [];
  for (const s of scenarios) {
    for (const k of K_VALUES) {
      const st = s.stability.cold[k];
      rows.push([
        s.name,
        k,
        fmt(st.movedFraction.mean),
        fmt(st.meanShiftCells.mean),
        fmt(st.maxShiftCells.mean),
        fmt(st.rankInversions.mean),
        fmt(st.rankInversions.max),
      ]);
    }
  }
  console.log(
    "\n== Stability — cold (k raw new systems added to the RAW scenario, both full re-solves; mean over 10 repeats) ==\n",
  );
  console.log(renderTable(headers, rows));
}

function scenarioVerdict(s) {
  const worstMoved = Math.max(
    ...K_VALUES.map((k) => s.stability.roundTrip[k].movedFraction.mean),
  );
  const worstShift = Math.max(
    ...K_VALUES.map((k) => s.stability.roundTrip[k].meanShiftCells.mean),
  );
  const worstInv = Math.max(
    ...K_VALUES.map((k) => s.stability.roundTrip[k].rankInversions.mean),
  );
  // CHEWY PATCH: newOffGrid/newUnplaced are summed (any nonzero count is a
  // hard failure, not a rate); newAnchorCells is judged on the worst mean
  // and worst max seen at any k, same as the other worst-case checks above.
  const totalNewOffGrid = K_VALUES.reduce(
    (sum, k) => sum + s.stability.roundTrip[k].newOffGrid,
    0,
  );
  const totalNewUnplaced = K_VALUES.reduce(
    (sum, k) => sum + s.stability.roundTrip[k].newUnplaced,
    0,
  );
  const worstAnchorMean = Math.max(
    ...K_VALUES.map((k) => s.stability.roundTrip[k].newAnchorCells.mean),
  );
  const worstAnchorMax = Math.max(
    ...K_VALUES.map((k) => s.stability.roundTrip[k].newAnchorCells.max),
  );
  // CHEWY PATCH: edgeOverlapPairs/nodeOcclusions are summed across k, same
  // hard-zero treatment as newOffGrid/newUnplaced — inserting new systems
  // must never make one edge hide another, or drop a node onto an edge it
  // isn't an endpoint of.
  const totalEdgeOverlapPairs = K_VALUES.reduce(
    (sum, k) => sum + s.stability.roundTrip[k].edgeOverlapPairs,
    0,
  );
  const totalNodeOcclusions = K_VALUES.reduce(
    (sum, k) => sum + s.stability.roundTrip[k].nodeOcclusions,
    0,
  );
  const movedOk = worstMoved <= ROUND_TRIP_THRESHOLDS.movedFraction;
  const shiftOk = worstShift <= ROUND_TRIP_THRESHOLDS.meanShiftCells;
  const invOk = worstInv <= ROUND_TRIP_THRESHOLDS.rankInversions;
  const idempotentOk = s.idempotent.movedFraction === 0;
  const newOffGridOk = totalNewOffGrid === 0;
  const newUnplacedOk = totalNewUnplaced === 0;
  const anchorOk =
    worstAnchorMean <= ROUND_TRIP_THRESHOLDS.newAnchorCellsMean &&
    worstAnchorMax <= ROUND_TRIP_THRESHOLDS.newAnchorCellsMax;
  const edgeOverlapOk = totalEdgeOverlapPairs === 0;
  const nodeOcclusionOk = totalNodeOcclusions === 0;
  return {
    movedOk,
    shiftOk,
    invOk,
    idempotentOk,
    newOffGridOk,
    newUnplacedOk,
    anchorOk,
    edgeOverlapOk,
    nodeOcclusionOk,
    worstMoved,
    worstShift,
    worstInv,
    totalNewOffGrid,
    totalNewUnplaced,
    worstAnchorMean,
    worstAnchorMax,
    totalEdgeOverlapPairs,
    totalNodeOcclusions,
    pass:
      movedOk &&
      shiftOk &&
      invOk &&
      idempotentOk &&
      newOffGridOk &&
      newUnplacedOk &&
      anchorOk &&
      edgeOverlapOk &&
      nodeOcclusionOk,
  };
}

function printVerdictTable(scenarios) {
  const headers = [
    "scenario",
    "movedFrac<=0.15",
    "meanShift<=0.5",
    "rankInv(mean)<=2",
    "idempotent==0",
    "newOffGrid==0",
    "newUnplaced==0",
    "newAnchor<=2.0/4",
    "edgeOverlap==0",
    "occlusion==0",
    "PASS",
  ];
  const rows = scenarios.map((s) => {
    const v = scenarioVerdict(s);
    return [
      s.name,
      `${v.movedOk ? "yes" : "NO"} (${fmt(v.worstMoved)})`,
      `${v.shiftOk ? "yes" : "NO"} (${fmt(v.worstShift)})`,
      `${v.invOk ? "yes" : "NO"} (${fmt(v.worstInv)})`,
      `${v.idempotentOk ? "yes" : "NO"} (${fmt(s.idempotent.movedFraction)})`,
      `${v.newOffGridOk ? "yes" : "NO"} (${v.totalNewOffGrid})`,
      `${v.newUnplacedOk ? "yes" : "NO"} (${v.totalNewUnplaced})`,
      `${v.anchorOk ? "yes" : "NO"} (${fmt(v.worstAnchorMean)}/${fmt(v.worstAnchorMax)})`,
      `${v.edgeOverlapOk ? "yes" : "NO"} (${v.totalEdgeOverlapPairs})`,
      `${v.nodeOcclusionOk ? "yes" : "NO"} (${v.totalNodeOcclusions})`,
      v.pass ? "PASS" : "FAIL",
    ];
  });
  console.log(
    "\n== Round-trip stability verdict (worst case over k=1,3,5) ==\n",
  );
  console.log(renderTable(headers, rows));
}

// ---------------------------------------------------------------------------
// --compare
// ---------------------------------------------------------------------------

// rel = fraction of baseline; abs = floor below which small noise is ignored.
// See dev/layout-bench.README.md for the rationale behind each tolerance.
const TOLERANCES = {
  crossings: { rel: 0, abs: 0 },
  spanCols: { rel: 0.05, abs: 1 },
  spanRows: { rel: 0.05, abs: 1 },
  "gateEdgeCells.mean": { rel: 0.05, abs: 0.05 },
  "gateEdgeCells.max": { rel: 0.05, abs: 0.1 },
  "wormholeEdgeCells.mean": { rel: 0.05, abs: 0.05 },
  "wormholeEdgeCells.max": { rel: 0.05, abs: 0.1 },
  "stability.roundTrip.movedFraction": { rel: 0.05, abs: 0.03 },
  "stability.roundTrip.meanShiftCells": { rel: 0.05, abs: 0.05 },
  "stability.roundTrip.maxShiftCells": { rel: 0.05, abs: 0.1 },
  "stability.roundTrip.rankInversions": { rel: 0.05, abs: 1 },
  // CHEWY PATCH: mean/max grid distance from a newly added node to the
  // already-placed neighbour it was attached to.
  "stability.roundTrip.newAnchorCells.mean": { rel: 0.05, abs: 0.1 },
  "stability.roundTrip.newAnchorCells.max": { rel: 0.05, abs: 0.2 },
  // Higher is better (share of repeats that resolved 'incremental'); see
  // HIGHER_IS_BETTER_METRICS below for the flipped regression direction.
  "stability.roundTrip.incrementalShare": { rel: 0.05, abs: 0.05 },
  "stability.cold.movedFraction": { rel: 0.05, abs: 0.03 },
  "stability.cold.meanShiftCells": { rel: 0.05, abs: 0.05 },
  "stability.cold.maxShiftCells": { rel: 0.05, abs: 0.1 },
  "stability.cold.rankInversions": { rel: 0.05, abs: 1 },
};
// Hard invariants: any violation fails regardless of baseline/tolerance.
// CHEWY PATCH: newOffGrid/newUnplaced (per k) joined the hard-zero list —
// they were the exact gap that let the reported defect through unnoticed.
const HARD_ZERO_METRICS = [
  "overlaps",
  "offGrid",
  "idempotent.movedFraction",
  "stability.roundTrip.newOffGrid",
  "stability.roundTrip.newUnplaced",
  // CHEWY PATCH: lines can cross but must never fully hide a connection —
  // an edge pair collinear-overlapping, or a node sitting on an edge it
  // isn't an endpoint of, is exactly as much a hard failure as
  // overlaps/offGrid above, at both the quality level and (per k) the
  // round-trip post-insertion level.
  "edgeOverlapPairs",
  "nodeOcclusions",
  "stability.roundTrip.edgeOverlapPairs",
  "stability.roundTrip.nodeOcclusions",
];
// Metrics where a HIGHER current value is the improvement (a regression is
// a DECREASE beyond tolerance) — every other metric is "lower is better".
const HIGHER_IS_BETTER_METRICS = ["stability.roundTrip.incrementalShare"];

function isRegression(metricKey, baseline, current) {
  const tol = TOLERANCES[metricKey] ?? { rel: 0.05, abs: 0 };
  const allowed = Math.max(tol.abs, Math.abs(baseline) * tol.rel);
  return HIGHER_IS_BETTER_METRICS.includes(metricKey)
    ? baseline - current > allowed
    : current - baseline > allowed;
}

function flattenScenarioMetrics(s) {
  const out = {
    crossings: s.quality.crossings,
    overlaps: s.quality.overlaps,
    spanCols: s.quality.spanCols,
    spanRows: s.quality.spanRows,
    offGrid: s.quality.offGrid,
    edgeOverlapPairs: s.quality.edgeOverlapPairs,
    nodeOcclusions: s.quality.nodeOcclusions,
    totalEdgeCells: s.quality.totalEdgeCells,
    chainClearanceCells: Number.isFinite(s.quality.chainClearanceCells)
      ? s.quality.chainClearanceCells
      : null,
    "gateEdgeCells.mean": s.quality.gateEdgeCells.mean,
    "gateEdgeCells.max": s.quality.gateEdgeCells.max,
    "wormholeEdgeCells.mean": s.quality.wormholeEdgeCells.mean,
    "wormholeEdgeCells.max": s.quality.wormholeEdgeCells.max,
    determinism: s.determinism.ok,
    "idempotent.movedFraction": s.idempotent.movedFraction,
  };
  for (const k of K_VALUES) {
    out[`stability.roundTrip.movedFraction@k${k}`] =
      s.stability.roundTrip[k].movedFraction.mean;
    out[`stability.roundTrip.meanShiftCells@k${k}`] =
      s.stability.roundTrip[k].meanShiftCells.mean;
    out[`stability.roundTrip.maxShiftCells@k${k}`] =
      s.stability.roundTrip[k].maxShiftCells.mean;
    out[`stability.roundTrip.rankInversions@k${k}`] =
      s.stability.roundTrip[k].rankInversions.mean;
    out[`stability.roundTrip.incrementalShare@k${k}`] =
      s.stability.roundTrip[k].incrementalShare;
    // CHEWY PATCH: new-node placement metrics, per k.
    out[`stability.roundTrip.newOffGrid@k${k}`] =
      s.stability.roundTrip[k].newOffGrid;
    out[`stability.roundTrip.newUnplaced@k${k}`] =
      s.stability.roundTrip[k].newUnplaced;
    out[`stability.roundTrip.newAnchorCells.mean@k${k}`] =
      s.stability.roundTrip[k].newAnchorCells.mean;
    out[`stability.roundTrip.newAnchorCells.max@k${k}`] =
      s.stability.roundTrip[k].newAnchorCells.max;
    out[`stability.roundTrip.edgeOverlapPairs@k${k}`] =
      s.stability.roundTrip[k].edgeOverlapPairs;
    out[`stability.roundTrip.nodeOcclusions@k${k}`] =
      s.stability.roundTrip[k].nodeOcclusions;
    out[`stability.cold.movedFraction@k${k}`] =
      s.stability.cold[k].movedFraction.mean;
    out[`stability.cold.meanShiftCells@k${k}`] =
      s.stability.cold[k].meanShiftCells.mean;
    out[`stability.cold.maxShiftCells@k${k}`] =
      s.stability.cold[k].maxShiftCells.mean;
    out[`stability.cold.rankInversions@k${k}`] =
      s.stability.cold[k].rankInversions.mean;
  }
  return out;
}

function toleranceKeyFor(flatKey) {
  return flatKey.replace(/@k\d+$/, "");
}

function runCompare(current, baselinePath) {
  const baseline = JSON.parse(readFileSync(baselinePath, "utf8"));
  const baselineByName = new Map(baseline.scenarios.map((s) => [s.name, s]));
  let regressed = false;
  const rows = [];

  for (const s of current.scenarios) {
    const base = baselineByName.get(s.name);
    if (!base) {
      rows.push([s.name, "(new scenario, no baseline)", "", "", ""]);
      continue;
    }
    const curFlat = flattenScenarioMetrics(s);
    const baseFlat = flattenScenarioMetrics(base);
    for (const [key, curVal] of Object.entries(curFlat)) {
      const baseVal = baseFlat[key];
      if (typeof curVal === "boolean") {
        if (curVal !== true) {
          regressed = true;
          rows.push([
            s.name,
            key,
            String(baseVal),
            String(curVal),
            "REGRESSED (must be true)",
          ]);
        }
        continue;
      }
      const delta = curVal - baseVal;
      const higherIsBetter = HIGHER_IS_BETTER_METRICS.includes(
        toleranceKeyFor(key),
      );
      let verdict = "ok";
      // CHEWY PATCH: strip the @kN suffix before matching HARD_ZERO_METRICS
      // too, so per-k hard invariants (newOffGrid/newUnplaced) work the
      // same way the tolerance lookup already does.
      if (HARD_ZERO_METRICS.includes(toleranceKeyFor(key)) && curVal !== 0) {
        verdict = "REGRESSED (must be 0)";
        regressed = true;
      } else if (isRegression(toleranceKeyFor(key), baseVal, curVal)) {
        verdict = "REGRESSED";
        regressed = true;
      } else if (higherIsBetter ? delta > 0 : delta < 0) {
        verdict = "better";
      }
      if (verdict !== "ok" || Math.abs(delta) > 1e-9) {
        rows.push([s.name, key, fmt(baseVal), fmt(curVal), verdict]);
      }
    }
  }

  console.log("\n== Compare vs baseline ==\n");
  console.log(
    renderTable(["scenario", "metric", "baseline", "current", "verdict"], rows),
  );
  console.log(
    regressed
      ? "\nRESULT: REGRESSED\n"
      : "\nRESULT: OK (no regression beyond tolerance)\n",
  );
  return regressed;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = { scenario: null, json: null, compare: null, standoff: 0 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--scenario") opts.scenario = argv[++i];
    else if (argv[i] === "--json") opts.json = argv[++i];
    else if (argv[i] === "--compare") opts.compare = argv[++i];
    // CHEWY PATCH: run every scenario with a chain/k-space standoff of N cells
    // (BeautifyOptions.chainStandoff / WANDERER_CHAIN_STANDOFF). Default 0 is
    // the shipped default, so a plain run still measures upstream geometry.
    else if (argv[i] === "--standoff") opts.standoff = Number.parseInt(argv[++i], 10) || 0;
    else {
      process.stderr.write(`Unknown argument: ${argv[i]}\n`);
      process.exit(1);
    }
  }
  return opts;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const { mod } = await loadEngine();
  const { CELL_W, CELL_H } = mod;
  const beautifyLayout =
    opts.standoff > 0
      ? (nodes, edges, options = {}) =>
          mod.beautifyLayout(nodes, edges, { ...options, chainStandoff: opts.standoff })
      : mod.beautifyLayout;

  const regionSystems = loadRegionSystems();
  const kspaceWide = buildKspaceWideScenario(regionSystems);
  const allScenarios = {
    yugen: buildYugenScenario(),
    chain: buildChainScenario(),
    "kspace-wide": kspaceWide,
    mixed: buildMixedScenario(kspaceWide),
    occlusion: buildOcclusionScenario(),
  };

  const names = opts.scenario ? [opts.scenario] : Object.keys(allScenarios);
  for (const n of names) {
    if (!allScenarios[n]) {
      process.stderr.write(
        `Unknown scenario "${n}". Valid: ${Object.keys(allScenarios).join(", ")}\n`,
      );
      process.exit(1);
    }
  }

  const results = [];
  for (const name of names) {
    const scenario = allScenarios[name];
    // P1: a from-scratch beautify of the raw scenario — the "tidy map"
    // every stability/idempotence measurement below builds on.
    const determinism = await checkDeterminism(
      beautifyLayout,
      scenario.nodes,
      scenario.edges,
      {},
    );
    const P1positions = mergeFinalPositions(scenario.nodes, determinism.result);
    const quality = computeQuality(
      scenario.nodes,
      scenario.edges,
      P1positions,
      CELL_W,
      CELL_H,
    );
    const idempotent = await runIdempotence(
      beautifyLayout,
      scenario,
      P1positions,
      CELL_W,
      CELL_H,
    );
    const stability = await runStability(
      beautifyLayout,
      scenario,
      regionSystems,
      CELL_W,
      CELL_H,
      P1positions,
    );
    results.push({
      name,
      nodeCount: scenario.nodes.length,
      edgeCount: scenario.edges.length,
      quality,
      determinism: { ok: determinism.ok },
      idempotent,
      stability,
    });
  }

  const output = {
    generatedAt: new Date().toISOString(),
    cellW: CELL_W,
    cellH: CELL_H,
    scenarios: results,
  };

  printQualityTable(results);
  printRoundTripStabilityTable(results);
  printColdStabilityTable(results);
  printVerdictTable(results);

  let hardFail = false;
  for (const s of results) {
    if (s.quality.overlaps !== 0) hardFail = true;
    if (s.quality.offGrid !== 0) hardFail = true;
    if (!s.determinism.ok) hardFail = true;
    if (s.idempotent.movedFraction !== 0) hardFail = true;
    // CHEWY PATCH: lines can cross but must never fully hide a connection —
    // an overlapping edge pair or an occluding node is a hard failure at
    // the quality level too, same treatment as overlaps/offGrid.
    if (s.quality.edgeOverlapPairs !== 0) hardFail = true;
    if (s.quality.nodeOcclusions !== 0) hardFail = true;
    // CHEWY PATCH: a newly added node landing off-grid, or left exactly at
    // its raw drop point, is just as much a hard failure as an existing
    // node overlapping/off-grid — this is the exact defect class that used
    // to slip through unnoticed.
    for (const k of K_VALUES) {
      if (s.stability.roundTrip[k].newOffGrid !== 0) hardFail = true;
      if (s.stability.roundTrip[k].newUnplaced !== 0) hardFail = true;
      // CHEWY PATCH: same for the post-insertion layout — inserting k new
      // systems must not make an edge hide another or drop a node onto one.
      if (s.stability.roundTrip[k].edgeOverlapPairs !== 0) hardFail = true;
      if (s.stability.roundTrip[k].nodeOcclusions !== 0) hardFail = true;
    }
  }
  if (hardFail) {
    console.error(
      "\nFAIL: a hard invariant was violated (overlaps/offGrid must be 0; output must be deterministic; " +
        "an unchanged already-beautified map must stay unchanged on repeat beautify; every newly added " +
        "node must land on-grid and must actually be moved off its raw drop point; no edge pair may " +
        "collinear-overlap and no node may sit on an edge it isn't an endpoint of).\n",
    );
  }

  if (opts.json) {
    writeFileSync(opts.json, JSON.stringify(output, null, 2));
    console.log(`\nWrote ${opts.json}`);
  }

  let compareRegressed = false;
  if (opts.compare) {
    if (!existsSync(opts.compare)) {
      process.stderr.write(`--compare baseline not found: ${opts.compare}\n`);
      process.exit(1);
    }
    compareRegressed = runCompare(output, opts.compare);
  }

  process.exit(hardFail || compareRegressed ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
