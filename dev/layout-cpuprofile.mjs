#!/usr/bin/env node
// CPU-profile hotspot analyzer for the map-beautifier layout engine.
//
// Runs one or more scenarios through `beautifyLayout` inside an in-process
// V8 CPU profiler session (node:inspector), then aggregates each captured
// .cpuprofile by SELF time per function (file:line, sample count) and
// prints the top 20. Also reports wall-clock time per named phase inside
// layout/index.ts (packBoxes / reduceCrossings / snapAngles / evictCrowded)
// via LAYOUT_PROFILE=1 call counts, for cross-reference.
//
// Usage:
//   node dev/layout-cpuprofile.mjs                 # all built-in scenarios
//   node dev/layout-cpuprofile.mjs --scenario kspace-lattice-100
//   node dev/layout-cpuprofile.mjs --top 30
//
// Scenarios:
//   kspace-lattice-<N>   grid of N synthetic systems, ids NOT present in
//                        regionLayouts.json (forces the topological fallback
//                        path, same generator as dev/layout-profile.mjs)
//   wormhole-chain-<N>   N synthetic systems as one long wormhole chain tree
//                        (ids also absent from regionLayouts.json)
//   mixed-real-<N>       real yugen-shaped mixed k-space+chain graph scaled
//                        up to N systems (yugen's own real system ids tiled
//                        with synthetic offsets layered on top of its real
//                        shape, so the k-space portion still resolves via
//                        regionLayouts.json)
//
// Output per scenario: wall time, top-N self-time functions from the
// .cpuprofile, and the engine's own LAYOUT_PROFILE call counters.

import { registerHooks, createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { Session } from "node:inspector/promises";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "..");
const ASSETS_DIR = path.join(REPO_ROOT, "assets");
const LAYOUT_DIR = path.join(ASSETS_DIR, "js/hooks/Mapper/components/map/layout");
const LAYOUT_INDEX = path.join(LAYOUT_DIR, "index.ts");
const SEED_EX = path.join(REPO_ROOT, "lib/wanderer_app/dev/seed.ex");
const TS_EXTS = [".ts", ".tsx", ".mts"];
const PROF_DIR = path.join(HERE, "..", "tmp", "prof");

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
    if ((specifier.startsWith("./") || specifier.startsWith("../")) && !/\.[a-zA-Z0-9]+$/.test(specifier)) {
      for (const ext of TS_EXTS) {
        try {
          return nextResolve(specifier + ext, context);
        } catch {}
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
    return false;
  }
}
function tryTypescriptPackage() {
  const req = createRequire(import.meta.url);
  let ts;
  try {
    const resolved = req.resolve("typescript", { paths: [ASSETS_DIR, REPO_ROOT, process.cwd()] });
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
          compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
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
  const strategy = (await tryNativeStrip()) ? "native" : tryTypescriptPackage() ? "typescript-package" : null;
  if (!strategy) {
    console.error("[layout-cpuprofile] Cannot load TypeScript. Fix: cd assets && yarn install");
    process.exit(1);
  }
  process.on("warning", (w) => {
    if (w.name === "Warning" && /MODULE_TYPELESS_PACKAGE_JSON/.test(String(w.message ?? ""))) return;
    console.error(w);
  });
  return import(pathToFileURL(LAYOUT_INDEX));
}

function hashSeed(str) {
  let hash = 2166136261;
  for (let i = 0; i < str.length; i++) {
    hash ^= str.charCodeAt(i);
    hash = (hash * 16777619) >>> 0;
  }
  return hash >>> 0;
}
function mulberry32(seed) {
  return function () {
    let t = (seed += 0x6d2b79f5);
    t = Math.imul(t ^ (t >>> 15), 1 | t);
    t ^= t + Math.imul(t ^ (t >>> 7), 61 | t);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// --- Scenario builders ------------------------------------------------

function buildKSpaceLattice(N) {
  const prng = mulberry32(hashSeed("lattice-" + N));
  const systems = [];
  const connections = [];
  const side = Math.ceil(Math.sqrt(N));
  const cellSize = 150;
  for (let i = 0; i < N; i++) {
    const col = i % side;
    const row = Math.floor(i / side);
    systems.push({ id: `sys-${i}`, x: col * cellSize + (prng() - 0.5) * 50, y: row * cellSize + (prng() - 0.5) * 50, locked: false, systemClass: "K" });
  }
  for (let i = 0; i < N; i++) {
    const col = i % side;
    const row = Math.floor(i / side);
    if (col + 1 < side) {
      const right = row * side + (col + 1);
      if (right < N) connections.push({ source: `sys-${i}`, target: `sys-${right}`, type: 1 });
    }
    if (row + 1 < side) {
      const below = (row + 1) * side + col;
      if (below < N) connections.push({ source: `sys-${i}`, target: `sys-${below}`, type: 1 });
    }
  }
  return { name: `kspace-lattice-${N}`, nodes: systems, edges: connections };
}

/** One long wormhole chain tree (branching factor 2-3), N synthetic systems, no lattice entries. */
function buildWormholeChainHeavy(N) {
  const prng = mulberry32(hashSeed("chain-" + N));
  const systems = [{ id: "sys-0", x: 0, y: 0, locked: false, systemClass: "W" }];
  const edges = [];
  for (let i = 1; i < N; i++) {
    const parent = Math.floor(prng() * i);
    systems.push({ id: `sys-${i}`, x: prng() * 2000, y: prng() * 2000, locked: false, systemClass: "W" });
    edges.push({ source: `sys-${parent}`, target: `sys-${i}`, type: 0 });
  }
  return { name: `wormhole-chain-${N}`, nodes: systems, edges };
}

/** Parses the yugen seed fixture (real k-space + chain mix), same tuple format and `@systems`/`@connections` module attributes as dev/layout-bench.mjs's own parseYugenSeed, and tiles it (translated copies, re-ided) up to N systems, bridged by one connection per adjacent tile so it stays one component. */
function extractElixirListBlock(src, attrName) {
  const marker = `@${attrName} [`;
  const startIdx = src.indexOf(marker);
  if (startIdx === -1) throw new Error(`seed.ex: @${attrName} not found — has the seeder module moved/renamed it?`);
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
    nodes.push({ id: String(parseElixirInt(m[1])), x: parseElixirInt(m[2]), y: parseElixirInt(m[3]), locked: false });
  }
  const connectionsBlock = extractElixirListBlock(src, "connections");
  const edges = [];
  for (const m of connectionsBlock.matchAll(tuple3)) {
    edges.push({ source: String(parseElixirInt(m[1])), target: String(parseElixirInt(m[2])), type: parseElixirInt(m[3]) });
  }
  if (nodes.length === 0 || edges.length === 0) {
    throw new Error("seed.ex parser produced an empty graph — the module attribute format may have changed.");
  }
  return { nodes, edges };
}

function buildMixedRealistic(N) {
  const base = parseYugenSeed();
  if (base.nodes.length === 0) throw new Error("yugen fixture parse produced 0 nodes");
  const nodes = [];
  const edges = [];
  const tiles = Math.ceil(N / base.nodes.length);
  const tileSpan = 3000;
  let remaining = N;
  for (let t = 0; t < tiles; t++) {
    const take = Math.min(base.nodes.length, remaining);
    const idMap = new Map();
    for (let i = 0; i < take; i++) {
      const n = base.nodes[i];
      const newId = t === 0 ? n.id : `${n.id}-t${t}`;
      idMap.set(n.id, newId);
      nodes.push({ id: newId, x: n.x + t * tileSpan, y: n.y, locked: false });
    }
    for (const e of base.edges) {
      if (idMap.has(e.source) && idMap.has(e.target)) {
        edges.push({ source: idMap.get(e.source), target: idMap.get(e.target), type: e.type });
      }
    }
    // Bridge to previous tile so the whole thing stays one connected component.
    if (t > 0) {
      edges.push({ source: nodes[nodes.length - take].id, target: nodes[nodes.length - take - 1]?.id ?? nodes[0].id, type: 0 });
    }
    remaining -= take;
  }
  return { name: `mixed-real-${N}`, nodes, edges };
}

// --- CPU profiling + analysis ------------------------------------------

async function profileOnce(fn) {
  const session = new Session();
  session.connect();
  await session.post("Profiler.enable");
  await session.post("Profiler.setSamplingInterval", { interval: 100 }); // 100us for fine resolution at small N
  await session.post("Profiler.start");
  const t0 = process.hrtime.bigint();
  await fn();
  const wallMs = Number(process.hrtime.bigint() - t0) / 1e6;
  const { profile } = await session.post("Profiler.stop");
  session.disconnect();
  return { profile, wallMs };
}

/** Aggregates a .cpuprofile's self time (via hitCount) per callFrame (functionName@url:line), returns sorted desc. */
function aggregateSelfTime(profile) {
  const durationUs = profile.endTime - profile.startTime;
  const sampleCount = profile.samples?.length || profile.nodes.reduce((a, n) => a + (n.hitCount || 0), 0) || 1;
  const usPerSample = durationUs / sampleCount;
  const totals = new Map();
  for (const node of profile.nodes) {
    const hc = node.hitCount || 0;
    if (hc === 0) continue;
    const cf = node.callFrame;
    const file = (cf.url || "").replace(/^file:\/\//, "").split(/[\\/]/).slice(-2).join("/");
    const key = `${cf.functionName || "(anonymous)"} ${file}:${cf.lineNumber + 1}`;
    const prev = totals.get(key) || { selfUs: 0, hits: 0 };
    prev.selfUs += hc * usPerSample;
    prev.hits += hc;
    totals.set(key, prev);
  }
  return [...totals.entries()]
    .map(([key, v]) => ({ key, selfMs: v.selfUs / 1000, hits: v.hits }))
    .sort((a, b) => b.selfMs - a.selfMs);
}

function printTop(label, wallMs, rows, topN, callCounts) {
  console.log(`\n=== ${label} (wall: ${wallMs.toFixed(0)}ms) ===`);
  if (callCounts) console.log(`  LAYOUT_PROFILE call counts: ${JSON.stringify(callCounts)}`);
  console.log(`  ${"self ms".padStart(9)}  ${"hits".padStart(6)}  function @ file:line`);
  for (const r of rows.slice(0, topN)) {
    console.log(`  ${r.selfMs.toFixed(1).padStart(9)}  ${String(r.hits).padStart(6)}  ${r.key}`);
  }
}

async function main() {
  mkdirSync(PROF_DIR, { recursive: true });
  process.env.LAYOUT_PROFILE = "1"; // pack.ts call-count counters, read from stderr JSON lines
  const args = process.argv.slice(2);
  let only = null;
  let topN = 20;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--scenario") only = args[++i];
    if (args[i] === "--top") topN = parseInt(args[++i], 10);
  }

  const engine = await loadEngine();
  const { beautifyLayout } = engine;

  const scenarios = [
    buildKSpaceLattice(100),
    buildWormholeChainHeavy(100),
    buildMixedRealistic(100),
  ].filter((s) => !only || s.name === only);

  const jsonOut = {};
  for (const scenario of scenarios) {
    // Capture pack.ts's own [LAYOUT_PROFILE] call-count line from stderr.
    let callCounts = null;
    const origErr = console.error;
    console.error = (...a) => {
      const line = a.join(" ");
      if (line.startsWith("[LAYOUT_PROFILE]")) {
        try {
          callCounts = JSON.parse(line.slice("[LAYOUT_PROFILE]".length).trim());
        } catch {}
      } else origErr(...a);
    };
    const { profile, wallMs } = await profileOnce(() => beautifyLayout(scenario.nodes, scenario.edges, {}));
    console.error = origErr;
    const rows = aggregateSelfTime(profile);
    printTop(`${scenario.name} (N=${scenario.nodes.length}, E=${scenario.edges.length})`, wallMs, rows, topN, callCounts);
    const outFile = path.join(PROF_DIR, `${scenario.name}.cpuprofile`);
    writeFileSync(outFile, JSON.stringify(profile));
    jsonOut[scenario.name] = { wallMs, top: rows.slice(0, topN), callCounts };
  }
  writeFileSync(path.join(PROF_DIR, "summary.json"), JSON.stringify(jsonOut, null, 2));
  console.log(`\n.cpuprofile files + summary.json written to ${PROF_DIR}`);
}

main().catch((err) => {
  console.error("Error:", err.stack || err.message);
  process.exit(1);
});
