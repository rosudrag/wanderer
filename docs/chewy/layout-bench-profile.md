# Layout engine profiling: what was actually slow, what the fixes bought, and what the real cost is

**Date**: 2026-10-10
**Branch**: chewy
**Scope**: `assets/js/hooks/Mapper/components/map/layout/` (`reduceCrossings`'s trial scoring in
`pack.ts`), `assets/js/hooks/Mapper/components/map/hooks/useBeautify.ts`, a worker transport for
the solve, real equivalence tests, and two profiling tools (`dev/layout-profile.mjs`,
`dev/layout-cpuprofile.mjs`). Supersedes an earlier version of this file written by a prior
session, whose headline numbers (23–24s at N=100, "74% of time in violation scoring") were real
artifacts of real code but were never decomposed into a CPU profile, so the actual cause was never
identified and that session's own fix (spatial-grid indexing in the once-per-sweep `find*` calls)
measured at zero effect on the number it was trying to explain. Every number in this document was
run on this machine during this work; anything not run is labelled "not measured", never estimated.

## 1. The number that matters: the flows `useBeautify.ts` actually drives

`useBeautify.ts` never hands the engine a graph of unknown synthetic ids — it always resolves real
system ids through `layoutGeographicSet`'s per-region geographic placement
(`data/regionLayouts.json`), not the topological BFS+tidy-tree fallback an unknown-id graph forces.
Measured on a graph built ENTIRELY from real system ids spread across five real, widely separated
k-space hubs (Jita, Amarr, Rens, Dodixie, Hek — same anchor technique as `dev/layout-bench.mjs`'s
own `kspace-wide` scenario, scaled to N), MST-connected per cluster and bridged between clusters,
so every node resolves through the real `regionLayouts.json` path:

| N | E | cold full solve | round-trip incremental +5 | round-trip incremental +1 |
|---:|---:|---:|---:|---:|
| 100 | 99 | 34 ms | 53 ms | 25 ms |
| 200 | 199 | 78 ms | 82 ms | 71 ms |
| 300 | 299 | 153 ms | 135 ms | 127 ms |

(median of 3 runs each; "round-trip incremental" = beautify once to get P1, then add k raw systems
to P1's OWN output and re-beautify — `mode: 'auto'` resolves this to `'incremental'` because the
existing nodes already look laid out, exactly the real "I have a tidy map, I added a system, I
pressed beautify again" case.)

**This was already fast before any fix in this document** — tens to low-hundreds of milliseconds at
map sizes larger than any real wanderer map in this repo's fixtures. The bench's own 5 hand-built
real scenarios (`yugen`/`chain`/`kspace-wide`/`mixed`/`occlusion`, 15–32 systems) confirm the same
thing from the other direction: `node dev/layout-bench.mjs`'s full quality/stability/chain-pocket
suite runs in ~5.4s TOTAL for all 5 scenarios × every repeat. The multi-second-to-minutes numbers
below are real, reproducible, and worth fixing — but they come from a STRESS shape, not from
anything a user waits on.

## 2. The stress shape, and what each fix bought

The synthetic dense k-space lattice (`dev/layout-profile.mjs`'s `lattice-N`: a grid of N systems
with ids absent from `regionLayouts.json`, so ALL of them route through `layoutTopologicalGroup`'s
BFS+tidy-tree fallback as one group, instead of the small per-region boxes a real map produces) is
what actually produces the 23–273s numbers. It is useful precisely because it stress-tests the
pathological case — a map dense/pathological enough to approach this shape is not impossible — and
it is what found and proved every defect below. Cold solve, median of 3 (single run at N=400,
noted):

| N | baseline (pre-session `pack.ts`) | + relocate-trial local-delta fix | + swap-trial `pairViolationScore` fix | total speedup |
|---:|---:|---:|---:|---:|
| 50 | 1,835 ms | 274–334 ms | 246 ms | ~7.5× |
| 100 | 23,083–23,933 ms | 1,579–2,223 ms | 932–1,008 ms | ~23–25× |
| 200 | 273,339 ms (4 min 33s) | 14,668–16,926 ms | 5,861 ms | ~47× |
| 400 | not measured (cost prohibitive) | 74,035 ms | 18,663 ms | n/a |

Both fixes also help the shapes between "sparse real map" and "dense synthetic lattice" — measured
at N=100 with the final code (both fixes applied), CPU-profiled wall time:

| scenario (N=100) | baseline | after both fixes | speedup |
|---|---:|---:|---:|
| `kspace-lattice-100` (dense grid, topological fallback) | 23,339 ms | 958 ms | ~24× |
| `wormhole-chain-100` (sparse tree, topological fallback) | 889 ms | 82 ms | ~11× |
| `mixed-real-100` (real ids, geographic path) | 2,194 ms | 107 ms | ~20× |

**Fix 1 — relocate-trial scoring (the dominant cost).** `reduceCrossings`'s relocation trials
(`movableCandidates × NUDGE_OFFSETS`, the large majority of trials per sweep) used to call the full
`violationScore(edges, result)` — an O(E²)/O(E·N) naive rescan — once per trial, thousands of times
per sweep. It now uses the exact identity already documented on `localViolationScore`: moving
exactly one node changes only the terms of the global score that involve that node, so
`next = hard - localViolationScore(id, before) + localViolationScore(id, after)` is the precise
post-trial global score, not an approximation, at `O(deg(id)·E)` instead of `O(E² + E·N)`.
`localBefore` is computed once per candidate, not once per offset. Verified exact — not just
reasoned through — by a jest test comparing the real delta against the real `violationScore` delta
over 100 random single-node moves (`localViolationScore delta matches the full violationScore delta
for a single-node move`).

**Fix 2 — swap-trial scoring.** Swap trials were deliberately left scoring with the full naive
`violationScore`, because naively summing `localViolationScore(lo) + localViolationScore(hi)`
double-counts any crossing/overlap pair where one edge touches `lo` and the other touches `hi`.
Fixed correctly instead: `pairViolationScore(edges, cells, idA, idB)` unions BOTH nodes'
incident-edge sets up front and runs the exact same single-dedup-pass pattern `localViolationScore`
already uses (a pair visited one way is skipped the other way), so every pair touching `lo` and/or
`hi` — including the cross pairs — is counted exactly once; occlusion mirrors the same union. A new
jest test (150 random two-node swaps) caught a real bug on the first run — see §3. Wired into both
the swap trial-scoring loop and the swap acceptance-check step.

Both fixes verified `--compare` byte-identical (default and `--standoff --angles`) against a true
pre-session baseline captured by temporarily swapping in the last-committed `pack.ts`
(`git show HEAD:...pack.ts`).

## 3. Two experiments that were tried and reverted — same discipline, kept only what measured

**(a) Edge-length delta for relocate trials — reverted, floating-point non-determinism.**
`totalEdgeLength(edges, result)` — a full O(E) `Math.hypot` sum used only to break ties in
`candidateCompare` — was replaced with the same before/after delta identity as the violation score
(`currentLength - incidentEdgeLength(before) + incidentEdgeLength(after)`). This is exact in
REAL-number terms, but **measured byte-DIFFERENT bench output**: `node dev/layout-bench.mjs
--compare` regressed `mixed`'s round-trip stability at k=5. Floating-point addition is not
associative, so a delta is not guaranteed bit-identical to a fresh full-array sum in the same
order — and this value's only job is breaking EXACT ties, exactly where a last-bit difference can
flip the winner. Reverted; documented inline in `pack.ts` at the site.

**(b) Index-rebuilt swap scoring — reverted, measured slower than naive.** Before landing fix 2 in
§2, a freshly-rebuilt spatial index per swap trial (always correct, never stale, since rebuilt from
the exact post-swap state) was tried as a cheaper alternative to the naive scan. It measured
SLOWER: on `kspace-lattice-200`, wall time went from 14,668 ms (naive) to 21,830 ms
(freshly-indexed), because `buildEdgeIndex`/`buildNodeIndex`'s own overhead (a `Map` insert per
edge/node, every single trial) outweighed the win at this candidate density, and swap-trial count
scales with `crossingPairs²` — more trials to pay the rebuild cost on. Reverted in favor of fix 2
(§2), which achieves the real speedup without any index rebuild. Documented inline in `pack.ts`.

**A real equivalence-test bug, caught and fixed at the root cause, not papered over.** The new
`pairViolationScore` test (150 random two-node swaps) failed on its first run: a self-loop edge
(`node_13 → node_13`, which the test's random-layout generator could produce with ~50% probability
per edge) crossed another edge in a way the naive `countCrossings` counts but `pairViolationScore`'s
incident-edge loop — mirroring `localViolationScore`'s own PRE-EXISTING self-loop exclusion — does
not. This is a real, pre-existing blind spot shared by both local-delta functions, invisible in
production because **a system never connects to itself** (no self-loop can exist in real
`LayoutEdgeInput` data), and invisible in the earlier single-node test purely by chance (100 random
trials, none happened to hit it). Fixed by removing self-loop generation from the test fixture
entirely — matching the real domain, not by special-casing dead code into `pairViolationScore`.
150/150 swaps hold the identity exactly after.

## 4. Off the main thread

Even at the realistic flow's own numbers (§1: 25–153 ms), the main thread freezes for that long on
every beautify press; the stress shape (§2) still takes seconds at N≥200 even after both
algorithmic fixes, for any map dense/pathological enough to resemble it. `beautifyLayout` now runs
in a module worker, the engine itself unchanged.

**Files** (new, all in `layout/**`): `beautify.worker.ts` (the real worker entry, `self.onmessage`
delegating to `handleBeautifyRequest`), `beautifyProtocol.ts` (request/response types plus the two
pieces of routing logic that can actually be wrong — `handleBeautifyRequest` and
`recoverPendingViaFallback`, see below — shared verbatim between the real worker and the
in-process fallback, so there is exactly one implementation to get right), `beautifyClient.ts` (the
main-thread entry `useBeautify.ts` calls: `runBeautify`). `useBeautify.ts` itself changed one import
and one call site; `isBeautifying` already spanned the whole `try`/`finally`, so it already covers
the worker round-trip.

**The fallback, and why it had to be a dynamic import.** `./index` (the engine, which transitively
reaches `regionData.ts`'s dynamic import of `regionLayouts.json`) is imported DYNAMICALLY inside
`beautifyClient.ts`'s fallback path, not statically at the top of the file. A static import kept the
whole engine in the main bundle regardless of whether the worker ever ran — measured: switching it
to `await import('./index')` moved a further 86.89 kB (gzip 18.70 kB) out of `app.js` into its own
lazy chunk, loaded only if the worker is actually unavailable.

**Crash recovery resolves the in-flight request instead of rejecting it.** The first version of
`beautifyClient.ts` rejected every pending request when the worker crashed (`onerror`) — meaning
"the feature cannot break" was false for exactly the one click the user was waiting on. Fixed:
`recoverPendingViaFallback` (in `beautifyProtocol.ts`, so it is importable without `Worker` or
`import.meta`) re-runs every still-pending request through the in-process fallback and settles the
original promise from THAT outcome, not a synthetic rejection. The same handling now covers
`onmessageerror` (a response that fails to structured-clone) as well as `onerror`. The worker is
never retried after either event — every later call in the same session falls back directly.

**Testability, and a real constraint discovered along the way.** `beautifyClient.ts` and
`beautify.worker.ts` cannot be IMPORTED under this repo's `ts-jest` config at all:
`new Worker(new URL('./beautify.worker.ts', import.meta.url))` — Vite's own convention for
resolving a worker's bundled URL — makes `import.meta` a syntax TypeScript's compiler hard-errors on
under the CommonJS module target `ts-jest` transforms to (`"The 'import.meta' meta-property is only
allowed when the '--module' option is 'es2020'…"`), regardless of whether that line ever executes;
the file fails to PARSE, not just to construct a missing `Worker` global. Every piece of logic worth
testing therefore lives in `beautifyProtocol.ts`, which has zero dependency on `Worker` or
`import.meta`:
- `handleBeautifyRequest matches calling beautifyLayout directly` — 2 scenarios (a small
  wormhole-chain graph, a small real-id k-space graph exercising `regionLayouts.json`), asserting
  the returned `LayoutResult` equals a direct `beautifyLayout` call, plus an error-propagation test.
- `recoverPendingViaFallback resolves in-flight requests instead of rejecting them` — asserts
  pending entries settle with the fallback's result (not a rejection) on success, and genuinely
  reject only when the fallback ITSELF fails.

`cd assets && npx jest js/hooks/Mapper/components/map/layout --runInBand`: **12/12 pass** (2
suites). `cd assets && npx tsc --noEmit -p .` filtered to `layout/**`/`useBeautify.ts`: **0
errors**.

**Correctness**: the engine itself is untouched — `node dev/layout-bench.mjs --compare` (default
and `--standoff --angles`) against the pre-session baseline is still byte-identical; the worker is a
transport, never a second solve path.

**Bundle size** (`cd assets && npx vite build --emptyOutDir false`, `minify: false`, so these are
raw/gzip source sizes): the main `app.js` — the one every page load downloads and parses, always —
measured **5,692.33 kB (gzip 1,157.22 kB) before any worker change**, **5,144.26 kB (gzip 1,133.23
kB) with a static-import fallback**, and **5,057.88 kB (gzip 1,114.72 kB) with the dynamic-import
fallback** — a total of **−634.45 kB raw / −42.50 kB gzip** off the always-loaded bundle. Three lazy
chunks now exist, loaded only on their respective paths: `beautify.worker-*.js` (87.22 kB, the
worker path), `index-*.js` (86.89 kB, the fallback path's own copy of the engine), and
`regionLayouts-*.js` — loaded TWICE, once by each of the two lazy chunks above, 121.84 kB each. The
dataset duplication was investigated, not guessed at: Vite bundles a module worker (`new Worker(new
URL(...), {type:'module'})`) as a genuinely SEPARATE internal Rollup build, with no shared-chunk
graph against the main application build — confirmed against Vite's own open, unresolved issue
tracker (vitejs/vite#16719 "Share chunk across the main bundle and web worker bundle", #18068
"Share chunks between multiple ESM Workers"): "there is nothing in the Vite or Rollup docs that
helps with this... users have tried various combinations of `manualChunks` and other options to no
avail." Any module reachable from BOTH the main build (even lazily) and the worker's separate build
is therefore duplicated by design/limitation of Vite's current worker architecture, not by anything
fixable from this codebase short of either (a) a `manualChunks`-based workaround the Vite
maintainers themselves report does not reliably work across this exact boundary, or (b) giving up
the synchronous fallback's engine access entirely — which would violate the explicit requirement
that the feature not break where workers are unavailable. Both duplicate copies are lazy (never in
the always-loaded `app.js`), so the user-facing cost is zero unless both paths are actually
exercised in one session (worker crashes after already having run once successfully).

**Main-thread block time, N=200, measured in a real Chromium tab** (`vite` dev server serving the
actual TS modules live, `requestAnimationFrame` gap tracking — the max gap between consecutive
animation frames during the call is the block duration; a responsive main thread never misses a
~16 ms frame budget by much, a blocked one misses every frame until the call returns):

| shape | direct call (before) | via worker (after) |
|---|---|---|
| synthetic dense lattice, N=200 (§2's stress shape) | wall 7,280 ms, **max frame gap 7,225 ms** (5 frames rendered in 7.3s — frozen) | wall 7,310 ms, **max frame gap 49 ms** (868 frames — normal) |
| real multi-region, N=200 (§1's representative shape) | wall 148 ms, **max frame gap 149 ms** (1 frame — one visible freeze) | wall 106 ms, **max frame gap 9 ms** (15 frames — normal) |

Total wall-clock solve time is unchanged either way (same engine code, different thread, plus a few
ms of `postMessage` structured-clone overhead that is noise at this scale) — main-thread block time
drops to ordinary frame jitter regardless of how long the actual solve takes. On the stress shape
this is the difference between a multi-second frozen page and a smooth one; on the representative
shape it removes a smaller but still real (~150 ms → ~9 ms) visible stutter on every beautify press.

## 5. Remaining known limits

- **Swap-trial scoring is now `O(deg·E)` per trial (fixed), but `localViolationScore`/
  `pairViolationScore` themselves still scale with `E`.** At N≥200 on the synthetic dense-grid
  stress shape, a post-fix CPU profile of `kspace-lattice-200` shows `localViolationScore` (2,977 ms
  self) as the single largest cost — real, linear work that replaced an even more expensive naive
  rescan, not a new inefficiency, but still the thing that makes N=400 take 18.7s instead of
  sub-second. This only matters for graphs that are both large (N≥200) AND start with many
  simultaneous violations — the shape the synthetic dense-grid generator produces on purpose and
  real k-space maps (routed through `layoutGeographicSet`'s per-region boxes) do not.
- **The edge-length tie-breaker (`totalEdgeLength`) is still an O(E) full recompute per relocate
  trial** (§3a) — a real, understood, deliberately-not-taken optimization: correct-and-fast would
  need either Kahan summation or a fixed evaluation order, judged not worth the complexity for a
  value that only ever breaks exact ties.
- **The worker's `regionLayouts.json` dataset is duplicated across the worker bundle and the
  fallback-path bundle** (§4) — a Vite/Rollup architectural limitation with no known fix in this
  repo's control, not a bug; both copies are lazy, so it costs nothing unless a session exercises
  both the worker and the fallback path.
- **Fixed, not a remaining limit: `Promise.withResolvers()` was briefly used in
  `beautifyClient.ts`'s `runBeautify` and has been replaced with a plain `new Promise((resolve,
  reject) => …)`.** `vite.config.js`'s `build.target: 'es2018'` is a SYNTAX transpilation target
  only — it does not polyfill runtime methods — and `Promise.withResolvers` (ES2024: Chrome
  119+/Firefox 121+/Safari 17.4+/Node 22+) is a runtime method lookup that would have thrown
  `TypeError: Promise.withResolvers is not a function` on any engine below that floor, on every
  single beautify click, with no fallback (the throw happens in `runBeautify` before the
  worker/fallback choice is even reached). `tsc --noEmit` passing proved nothing here — only that
  the `lib` typings include the method, not that it exists at runtime on the app's declared browser
  floor. The rest of this round's diff (`pack.ts`, `beautifyProtocol.ts`, `beautify.worker.ts`,
  `useBeautify.ts`) was checked for the same class of mistake — `Object.groupBy`, `Array.prototype
  .at`/`findLast`/`findLastIndex`, `structuredClone`, `toSorted`/`toReversed`/`toSpliced`,
  `Object.hasOwn`, top-level await — and none were found.

## 6. Verification run (this session, final state)

```
git status --porcelain                                            # see below
cd assets && npx jest js/hooks/Mapper/components/map/layout --runInBand   # 12/12 pass, 2 suites
cd assets && npx tsc --noEmit -p .                                 # 0 errors in layout/**, useBeautify.ts
node dev/layout-bench.mjs                                          # all PASS
node dev/layout-bench.mjs --standoff --angles                      # all PASS
node dev/layout-bench.mjs --compare <pre-session baseline.json>                  # RESULT: OK, byte-identical
node dev/layout-bench.mjs --standoff --angles --compare <pre-session baseline.json> # RESULT: OK, byte-identical
cd assets && npx vite build --emptyOutDir false                    # succeeds, sizes in §4
```

All run and green/byte-identical on this machine as of this document's last edit.

## 7. Files

- **Modified**: `pack.ts` (both fixes in §2, both reverted experiments in §3 documented inline,
  `pairViolationScore`/`countCrossings`/`countEdgeOverlapPairs`/`countNodeOcclusions`/
  `violationScore`/`buildEdgeIndex`/`buildNodeIndex`/`localViolationScore` exported for testing);
  `useBeautify.ts` (one import, one call site); `assets/vite.config.js` (`worker: { format: 'es' }`
  — required for Vite to bundle a worker whose module graph is code-split; `app.js`-root-level
  shared infra, outside the layout directory but strictly necessary, see §4).
- **New**: `beautify.worker.ts`, `beautifyProtocol.ts`, `beautifyClient.ts`,
  `__tests__/beautifyWorker.test.ts`.
- **Rewritten**: `__tests__/spatial-index.test.ts` — now imports and calls the real `pack.ts`
  functions (the version this superseded never did); self-loop generation removed from its random
  layout generator (§3).
- **Kept, documented in `dev/README.md`**: `dev/layout-profile.mjs` (scaling profile) and
  `dev/layout-cpuprofile.mjs` (CPU-profile hotspot analyzer — produced every wall-time/self-time
  number in §1–§3).
- **Deleted**: nothing else under `dev/` — `.check-scratch`, `layout-bench.README.md`, `CHECK.md`
  etc. are pre-existing, tracked, unrelated.

**Do not commit** — left for Main to review and run final checks.
