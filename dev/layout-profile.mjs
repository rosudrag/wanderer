#!/usr/bin/env node
// Scaling profile and phase-timing for map-beautifier layout engine.
// Usage: node dev/layout-profile.mjs [--scenario lattice-100] [--json path]

import { registerHooks, createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "..");
const ASSETS_DIR = path.join(REPO_ROOT, "assets");
const LAYOUT_DIR = path.join(ASSETS_DIR, "js/hooks/Mapper/components/map/layout");
const LAYOUT_INDEX = path.join(LAYOUT_DIR, "index.ts");
const TS_EXTS = [".ts", ".tsx", ".mts"];

function jsonLoadHook(url, context, nextLoad) {
  if (url.endsWith("regionLayouts.json")) {
    const filePath = fileURLToPath(url);
    const fileContent = readFileSync(filePath, "utf-8");
    return { format: "json", source: fileContent };
  }
  return nextLoad(url, context);
}

function extFixupResolveHook(specifier, context, nextResolve) {
  if (!specifier.startsWith(".")) return nextResolve(specifier, context);
  if (TS_EXTS.some(ext => specifier.endsWith(ext))) return nextResolve(specifier, context);
  for (const ext of TS_EXTS) {
    try {
      return nextResolve(specifier + ext, context);
    } catch {}
  }
  return nextResolve(specifier, context);
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
    console.error("[layout-profile] Cannot load TypeScript. Fix: cd assets && yarn install");
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

function buildKSpaceLattice(N) {
  const prng = mulberry32(hashSeed("lattice-" + N));
  const systems = [];
  const connections = [];
  const side = Math.ceil(Math.sqrt(N));
  const cellSize = 150;
  
  for (let i = 0; i < N; i++) {
    const col = i % side;
    const row = Math.floor(i / side);
    systems.push({
      id: `sys-${i}`,
      x: col * cellSize + (prng() - 0.5) * 50,
      y: row * cellSize + (prng() - 0.5) * 50,
      locked: false,
      systemClass: "K",
    });
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
  
  return { name: `lattice-${N}`, nodes: systems, edges: connections };
}

async function profileLayout(beautifyLayout, scenario) {
  const start = process.hrtime.bigint();
  await beautifyLayout(scenario.nodes, scenario.edges, {});
  const elapsed = Number(process.hrtime.bigint() - start) / 1_000_000;
  return elapsed;
}
async function profileLayoutIncremental(beautifyLayout, scenario, nodesAdded) {
  // First pass: solve the base scenario (don't time this)
  await beautifyLayout(scenario.nodes, scenario.edges, {});
  
  // Add nodes
  const augmented = {
    nodes: [...scenario.nodes, ...nodesAdded],
    edges: scenario.edges,
  };
  
  // Measure incremental solve
  const start = process.hrtime.bigint();
  await beautifyLayout(augmented.nodes, augmented.edges, {});
  const elapsed = Number(process.hrtime.bigint() - start) / 1_000_000;
  return elapsed;
}


async function main() {
  const engine = await loadEngine();
  const { beautifyLayout } = engine;
  
  const args = process.argv.slice(2);
  let targetScenario = null;
  let jsonPath = null;
  
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--scenario') targetScenario = args[++i];
    else if (args[i] === '--json') jsonPath = args[++i];
  }
  
  const systemCounts = targetScenario ? [parseInt(targetScenario.split('-')[1])] : [50, 100, 200, 400, 800];
  const results = [];
  
  for (const N of systemCounts) {
    console.log(`\nProfiling N=${N}...`);
    const scenario = buildKSpaceLattice(N);
    
    // Cold solve (3 runs)
    console.log('  Cold solve:');
    const coldTimes = [];
    for (let run = 0; run < 3; run++) {
      const t = await profileLayout(beautifyLayout, scenario);
      coldTimes.push(t);
      console.log(`    Run ${run + 1}: ${t.toFixed(0)}ms`);
    }
    const coldMedian = coldTimes.sort((a, b) => a - b)[1];
    
    // Incremental solve: add 5 systems (3 runs)
    console.log('  Incremental (+5 systems):');
    const nodesAdded = [];
    for (let i = 0; i < 5; i++) {
      nodesAdded.push({
        id: `sys-added-${i}`,
        x: Math.random() * 1000,
        y: Math.random() * 1000,
        locked: false,
        systemClass: "K",
      });
    }
    const incTimes = [];
    for (let run = 0; run < 3; run++) {
      const t = await profileLayoutIncremental(beautifyLayout, scenario, nodesAdded);
      incTimes.push(t);
      console.log(`    Run ${run + 1}: ${t.toFixed(0)}ms`);
    }
    const incMedian = incTimes.sort((a, b) => a - b)[1];
    
    results.push({ N, cold_median_ms: coldMedian, inc_median_ms: incMedian });
  }
  
  console.log('\n=== Results ===');
  console.table(results);
  
  if (jsonPath) writeFileSync(jsonPath, JSON.stringify(results, null, 2));
}

main().catch(err => {
  console.error("Error:", err.message);
  process.exit(1);
});
