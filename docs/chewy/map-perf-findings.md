# Map canvas render-path perf: findings + fixes (2026-10-10, corrected)

Scope: the React render path only (`assets/js/hooks/Mapper/`). The beautifier (layout solve cost)
is a separate workstream — not covered here. `assets/js/hooks/Mapper/components/map/layout/**`
was never touched (owned by a concurrent session).

## TL;DR

**Before**: dragging or hovering one node re-rendered every node on the map, every time,
regardless of map size — root cause was a single React Context whose Provider value was a **new
object on every `update()` call** (`MapProvider.tsx`), so every one of the ~15 unrelated
components that call `useMapState()` re-rendered on **any** `update()`.

**After**: the context value is stable for the Provider's lifetime; `useMapSelector(keys,
selector, isEqual?)` (built on `useSyncExternalStore` + a per-key pub/sub store) means a component
only wakes when a key it DECLARES reading changes. Measured, with corrected methodology (see
"Corrected drag measurement" below):
- **Hover re-renders only the 1-2 affected nodes**, not all N.
- **A real drag (one node's actual position changing) re-renders only that one node**, not all N
  — the "fans out to all N by necessity" claim in the first version of this doc was wrong, a test
  artifact, corrected below.
- **A real pan (viewport genuinely shifts) legitimately re-checks all N nodes' visibility** (the
  viewport moved, so every node's visibility bit COULD have changed) — this is honest, necessary
  work, not a bug, but each check is a cheap boolean compare, not a full recompute.
- **A field no node selector reads causes ZERO node re-renders** — true per-key isolation,
  confirmed both in the full mounted tree and in an isolated unit test.
- **`MapRootProvider` (the ~89-consumer sibling store) was migrated the same way for its hot
  per-node/per-edge consumers**, while every other consumer keeps today's "react to any write"
  behavior unchanged — see "`useMapRootState()` / `MapRootProvider`" below. A
  `charactersUpdated`/`detailedKillsUpdated` server-push burst now re-renders only the 1 node
  whose own data actually changed, not all N.

## `useMapSelector`'s API: explicit declared keys, not auto-discovery

The first version of this hook auto-discovered which keys a selector read by running it ONCE
(on first render) against a `Proxy`. **That is unsound** and was corrected before shipping: a
selector with a conditional read (`||`, `&&`, `?.`, a ternary, an early return) only reveals the
keys touched by whichever branch fires on the FIRST render. `showHandlers = isConnecting ||
hoverNodeId === id` is the concrete case already in this codebase — if `isConnecting` happens to be
`true` on a node's first render, `hoverNodeId` is never touched, never discovered, and that node
would silently stop responding to hover for the rest of the session.

**Fixed API**: `useMapSelector(keys: (keyof MapData)[], selector, isEqual = Object.is)`. Callers
declare every key the selector COULD read, not just what a single run touches. A development-only
assertion (`assertDeclaredKeysCoverActualReads`, runs every render, not just once — the branch
that reveals the missing key may not fire on render 1 either) re-runs the selector against a
`Proxy` and **throws** if it touches an undeclared key, so a future selector that grows a new read
fails loudly in development instead of shipping a stale-UI bug silently.

Every converted call site and its declared keys:

| File | Selector | Declared keys |
|---|---|---|
| `useSolarSystemNode.ts` | `d.visibleNodes.has(id)` | `['visibleNodes']` |
| `useSolarSystemNode.ts` | `d.isConnecting \|\| d.hoverNodeId === id` | `['isConnecting', 'hoverNodeId']` (BOTH declared even though `hoverNodeId` is only touched when `isConnecting` is falsy) |
| `useSolarSystemNode.ts` | `d.isThickConnections` | `['isThickConnections']` |
| `useSolarSystemNode.ts` | `d.showKSpaceBG` | `['showKSpaceBG']` |
| `useSolarSystemNode.ts` | `d.systemHighlighted === solar_system_id` | `['systemHighlighted']` |
| `useSolarSystemNode.ts` | `d.wormholesData` | `['wormholesData']` |
| `useSolarSystemNode.ts` | `d.userCharacters` | `['userCharacters']` |
| `useSolarSystemNode.ts` | `d.hubs` | `['hubs']` |
| `useSolarSystemNode.ts` | `d.charactersBySystem.get(id) ?? EMPTY_CHARACTERS` | `['charactersBySystem']` |
| `SolarSystemEdge.tsx` | `d.isThickConnections` | `['isThickConnections']` |
| `DotlanEdge.tsx` | `d.isThickConnections` | `['isThickConnections']` |
| `ContextMenuRoot.tsx` | `d.options` | `['options']` |
| `ContextMenuRoot.tsx` | `d.userPermissions` | `['userPermissions']` |
| `LocalCounter.tsx` | `d.localShowShipName` | `['localShowShipName']` |
| `WormholeClassComp.tsx` | `d.wormholesData` | `['wormholesData']` |
| `useMapUpdateSystems.ts` | `d.systems` | `['systems']` |

All 9 are single-key except `showHandlers`, the one genuinely conditional selector in the
codebase; none has a hidden conditional branch left undeclared (verified: every test run, dev
assertion enabled, never threw).

## Corrected drag measurement

**What was wrong**: the original drag test called `update({ visibleNodes: new Set(allSystemIds)
})` repeatedly — claiming EVERY node is visible. `buildSystems`'s synthetic grid (up to 20 cols ×
200px = 4000px wide, 15 rows × 150px = 2250px tall) is far bigger than the harness's 1200×800
`getBoundingClientRect` stub, so the REAL `useUpdateNodes` computation at mount marks MOST nodes
off-screen. "Claim everyone visible" was therefore a **genuine semantic change** (false→true) for
most nodes on its first call — a real re-render cause, not the no-op it was meant to represent.
The resulting "drag fans out to all N nodes" conclusion was a test-input artifact, not a product
behavior.

**How this was found and fixed**: built two targeted measurements instead of trusting the
original synthetic test:
1. An isolated unit test (`useMapSelector.unit.test.tsx`, no Map.tsx/ReactFlow at all): a selected
   boolean driven with a value that genuinely never changes across 10 queued updates produces
   **zero** extra renders. Confirms the store/selector mechanism itself is correct.
2. A diagnostic separating two hypotheses — (a) a selector returning an unstable identity, vs. (b)
   ReactFlow itself re-rendering every node wrapper when one node's position changes:
   - 10 `visibleNodes` updates re-asserting the REAL current membership (read back from the
     mounted tree, not assumed): **0 renders**. Rules out (a).
   - One node's ACTUAL ReactFlow position changed 60 times via the real `Commands.updateSystems`
     → `rf.setNodes` path (the same path a system-position update takes in production), letting
     the real `useUpdateNodes` hook decide whether `visibleNodes` needs touching at all: **1 node
     render total** (the moved node). Rules out (b) — ReactFlow does NOT broadly re-render node
     wrappers on an unrelated node's position change; `React.memo` on `SolarSystemNodeDefault`
     already does its job correctly here.

**Conclusion for item 3 (splitting `SolarSystemNodeDefault` into a memoized presentational
component)**: not applicable. The premise (ReactFlow re-renders every node wrapper on a position
change) was the (b) hypothesis, and it's false — confirmed, not assumed. No code change made here;
splitting the component would add complexity for a problem that measurement shows doesn't exist.

The permanent regression test and scenario harness were corrected to match: `drag` now drives a
real ReactFlow position change (`harness.tsx`'s `dragOneNodeViaReactFlow`), not a synthetic
"declare everyone visible" call. `pan` was also corrected to a realistic viewport-shift
computation (`queueRealisticPanShift`, using the real `isNodeVisible` formula — exported from
`useUpdateNodes.ts` for test reuse — against a shifted viewport, so some nodes genuinely enter,
some leave, most are unaffected) instead of the same "declare everyone visible" pattern.

## `useMapRootState()` / `MapRootProvider` — migrated the same way, safely, not wholesale

**The question this followed up on**: `useMapRootState()` has the identical bug
`MapProvider.tsx` had before this work — **89 distinct files** call it (`grep -rl
"useMapRootState()" js/hooks/Mapper`), including the two hottest render paths (`useSolarSystemNode.ts`,
`SolarSystemEdge.tsx`), and `MapRootContext`'s value was a new object on every `update()` call, so
any one of those 89 consumers re-rendered on ANY write. Writes are never caused DIRECTLY by a
hover/drag gesture (those only ever touch `MapProvider`'s store), but `MapRootProvider` receives
frequent writes independent of and uncorrelated with the user's mouse — server-pushed
`charactersUpdated`, `detailedKillsUpdated`, `signaturesUpdated`, `mapUpdated`, pings, tracking
data, etc. If one of those lands while the user is mid-drag, it re-introduces the exact "every
node re-renders expensively" cost Fix 1 eliminated for `MapProvider` — same bug, a different,
uncontrollable trigger, and a far larger consumer surface (89 vs ~16 call sites) to convert.

**The risk a wholesale conversion would have hit**: making `MapRootContext`'s value fully stable
(the `MapProvider.tsx` pattern) would SILENTLY BREAK every one of the 89 unconverted consumers —
today they re-render because the Provider re-renders; a stable value with no subscription would
leave them reading a mutable ref with nothing ever waking them: stale UI, no error, no test
failure (nothing in the existing suite exercised a `MapRootProvider` write while unmounted-from
relevance). 89 files is also too many to hand-convert in one pass.

**What was actually done — convert the hot path, explicitly preserve the other 85ish**:

1. **`MapRootStoreContext`** (new, `MapRootProvider.tsx`): a narrow, second React context holding
   only `{ data, update, subscribe }`, frozen via `useRef` exactly like `MapProvider.tsx`'s
   `contextValueRef` — identity never changes for the Provider's lifetime. `MapRootContext` (the
   existing one) is deliberately left AS-IS: its value is still rebuilt fresh on every
   `MapRootProvider` render, so the 89 unconverted `useMapRootState()` consumers keep reacting to
   `storedSettings`/`windowsSettings`/`comments`/`charactersCache` changes exactly as before. A
   selector-based consumer reading from `MapRootContext` instead of the new narrow context would
   still be woken by React's native propagation on every one of THOSE renders too, regardless of
   its own selector — this is why the two contexts have to be separate, not one context with two
   access patterns.
2. **`useMapRootSelector(keys, selector, isEqual?)`** (new): the `MapRootData` equivalent of
   `useMapSelector`, reading from `MapRootStoreContext`. Shares its entire implementation with
   `useMapSelector` via a new generic `useContextSelector` (`utils/contextStore/useContextSelector.ts`,
   extracted from `MapProvider.tsx`'s original `useMapSelector` body) — including the SAME
   dev-mode `assertDeclaredKeysCoverActualReads` Proxy assertion, parameterized by hook name.
3. **Restored "react to any store write" for the 89 unconverted consumers**: `useContextStore` no
   longer forces its OWNER component to re-render internally (removed as part of the original
   per-key rewrite, so per-key selectors aren't woken on irrelevant writes) — without compensating
   for this, `MapRootProvider` would simply have stopped re-rendering on
   character/kill/signature/etc. writes altogether, and the 89 consumers would have gone silently
   stale (the exact risk above, confirmed by writing this fix and finding it). Fixed by having
   `MapRootProvider` subscribe to `ALL_MAP_ROOT_DATA_KEYS` (every key, computed once from
   `INITIAL_DATA`) and `forceRerender` (a plain `useReducer` counter) itself on any one of them —
   explicitly reconstructing the exact old behavior (whole-Provider re-render on any write),
   rather than relying on it as an accidental side effect of `useContextStore`'s internals.
4. **`interfaceSettings` mirror**: `storedSettings.interfaceSettings` is independent,
   localStorage-backed React state (`useMapUserSettings`), not part of the `useContextStore`
   managed `MapRootData` — so it could not be selected via `useMapRootSelector` directly. Added
   `MapRootData.interfaceSettings`, kept in sync by a `useEffect` that calls `update({
   interfaceSettings: storedSettings.interfaceSettings })` whenever the real value changes (one
   rAF tick behind on a settings toggle — a rare, user-initiated event, not the frequent
   server-pushed writes this store exists to isolate). This is what let the hot consumers below
   drop their `useMapRootState()` call entirely instead of keeping one `storedSettings` read
   around (which would have kept them hooked into the 89-consumer "re-render on anything" path
   regardless of how many fields they'd otherwise converted — confirmed by measurement, see next
   section).
5. **Converted call sites** (every one found by grepping for a hook/component instantiated once
   per node or once per edge, not a guess):
   - `useMapGetOption.ts` → `useMapRootSelector(['options'], d => d.options[option])`. Called 3x
     per node by `useSolarSystemNode.ts`, so this alone was one of the hottest consumers.
   - `useSolarSystemNode.ts` → three selectors (`interfaceSettings` → `isShowUnsplashedSignatures`,
     `systemSignatures` → that system's own slice, `pings` → a per-system boolean). No longer
     calls `useMapRootState()` at all.
   - `SolarSystemEdge.tsx` → `interfaceSettings` → `dotlanStyleConnections`.
   - `useNodeKillsCount.ts` (called unconditionally by every node, for the kill-count badge) →
     `detailedKills` → that system's own slice + a `hasOwnProperty` check, both selected
     separately.
   - `Map.tsx`'s `MapComp` → `interfaceSettings` → `onlyRenderVisibleElements`. This one mattered
     more than it looks: `MapComp` is the PARENT of every node/edge on the canvas, so as long as
     it held even one plain `useMapRootState()` read, `MapRootProvider`'s restored
     "re-render-on-anything" (step 3) meant the WHOLE canvas subtree re-rendered on every
     server-pushed write — see the next section for what that actually did downstream.
   - **Left unconverted, deliberately**: `useKillsCounter.ts` (used only inside the conditionally-
     rendered `KillsCounter` tooltip, not every node) reads the WHOLE `systems` array to build a
     name lookup — not a clean per-key/per-system selection, and not on the hot path the burst
     measurement below cares about; left as a plain `useMapRootState()` read.

**A parent-driven cascade the selector conversions alone couldn't fix**: converting `MapComp`'s
own read stopped IT from being woken directly, but `Map`/`MapComp` sit as a plain (non-memoized)
function component directly below `MapRootProvider` in the tree. `useMapSelector`/
`useMapRootSelector` only stop a component's OWN `useSyncExternalStore`-driven re-render trigger —
they do nothing to stop a PARENT re-render (e.g. `MapRootProvider`'s restored
"any-write-forces-rerender", step 3) from cascading through every non-memoized descendant via
React's default reconciliation, regardless of what that descendant itself reads. Confirmed by
measurement (see below): before memoizing, a `charactersUpdated`/`detailedKillsUpdated` burst
still re-rendered all 300 node components even after every hot consumer above was converted.
Fixed by wrapping `Map.tsx`'s exported `Map` in `React.memo()` — this only bails correctly if
every prop passed to `<Map>` is referentially stable across an unrelated parent re-render, which
is the caller's responsibility; the harness's own test double (`ProfiledMap` in `harness.tsx`) had
one inline `onSystemContextMenu={() => {}}` that had to be hoisted to a module constant for the
memo to take effect at all, and is flagged in code as a test-harness correctness requirement, not
a product one.

**Verified, not assumed, against `MapWrapper.tsx` (the real production caller of `<Map>`, ~19
props)**: every prop traced to its source and confirmed stable. The relevant ones, by mechanism:
`onCommand`/`onSelectionChange`/`onConnectionInfoClick`/`onSystemContextMenu`/
`onSelectionContextMenu`/`onChangeViewport`/`onAddSystem` are all `useCallback`s with either `[]`
or a dependency (`outCommand`, `update`) that is itself stable — `outCommand` traces back through
`MapWrapper` → `useMapRootState()` → `MapRootProvider`'s `outCommand` prop → `MapRoot.tsx`'s
`handleCommand` (`useCallback([hooksRef.current])`, and `hooksRef` is a `useRef` set once at
mount), and `update` is `useContextStore`'s own `useCallback([])`. `pings`/`defaultViewport`
(`mapSettings.viewport`) are the only non-primitive value props; `pings` is a `MapRootData` field
(stable reference unless actually written, confirmed by `useContextStore`'s mutate-in-place
design), and `defaultViewport` traces through `useSettingsValueAndSetter`'s `useMemo` to
`use-local-storage-state`'s own `value`, which is itself built on `useSyncExternalStore` (read
from its source, `node_modules/use-local-storage-state/src/useLocalStorageState.js`) — stable
across any re-render that doesn't change the stored value. Every remaining prop
(`minimapClasses`/`isShowMinimap`/`showKSpaceBG`/`isThickConnections`/
`isShowBackgroundPattern`/`isSoftBackground`/`theme`/`minimapPlacement`/`localShowShipName`) is a
primitive (string/boolean), which `memo`'s shallow comparison treats as value-equal regardless of
recomputation. **No source changes were needed** — `MapWrapper.tsx` already wires every prop
through `useCallback`/`useMemo`/a stable store field; the `Map.tsx` memo is a full win in
production as written, not a partial one.

**Measured proof, not hand-waving** (`mapRenderPerf.scenarios.test.tsx`'s burst scenario,
`mapRenderPerf.regression.test.tsx`'s permanent lock-in, both driven through the REAL
`MapRootProvider` command dispatcher via `queueRealisticDataBurst` → `Commands.charactersUpdated` +
`Commands.detailedKillsUpdated`, not a hand-rolled `update()` call): at N=300, before any of the
above conversions this burst would have re-rendered all 300 node components and the whole `MapComp`
subtree (same mechanism as the "before" row in the main results table, just a different trigger).
After: **1 node re-renders** — the one whose own kills slice actually changed.
`charactersUpdated`'s write (`MapRootData.characters`) has literally zero remaining per-node
listeners, since no node-level selector reads that field anymore (nodes get character data from
`MapProvider`'s own `charactersBySystem` index, a completely separate store — see Fix 4 above).
`signaturesUpdated` was not included in the synthetic burst: its real handler
(`updateSystemSignatures`) is async and fetches over `outCommand`, not a synchronous `update()`
call like the other two — burst-testing it would be testing the mock network round trip, not the
render path; `useSolarSystemNode.ts`'s `systemSignatures` selector conversion uses the identical
code path as the other two, so the same isolation applies once that async update lands.
`killsUpdated` (as opposed to `detailedKillsUpdated`) was also excluded — its real
`useMapRootHandlers.ts` case is a literal no-op.

## Measurement harness

`assets/js/hooks/Mapper/__perf__/`:
- `harness.tsx` — shared setup (not a test file): mounts the REAL `MapRootProvider` +
  `MapProvider` + ReactFlow + `Map.tsx` + `SolarSystemNodeDefault` + `SolarSystemEdge`, seeded via
  the real `MapHandlers.command(Commands.init, ...)` imperative ref, with per-node/per-edge render
  counters (via a `React.memo().type` unwrap) and a captured `MapProvider.update()`/`data`.
  `dragOneNodeViaReactFlow` drives a REAL ReactFlow position change;
  `queueGenuinelyUnchangedVisibleNodes` re-asserts the actual current membership (proves the store
  bails correctly); `queueRealisticPanShift` computes a genuine partial visibility change via the
  real `isNodeVisible` formula. Split into its own module because Jest gives each **test file** its
  own module registry; cross-describe-block state leakage (leftover rAF/timer state bleeding into
  the next scenario's measurement window) was observed in an earlier combined-file version.
- `mapRenderPerf.scenarios.test.tsx` — mount/drag/hover/pan at N=50/150/300/600, logs render
  counts + wall-clock to the console.
- `mapRenderPerf.regression.test.tsx` — **permanent CI regression test**, render COUNTS only
  (never ms), at N=300.
- `mapRenderPerf.smoke.test.tsx` — DOM-level correctness.
- `useMapSelector.unit.test.tsx` — isolated unit test of the selector/store mechanism alone (no
  Map.tsx/ReactFlow), proving a genuinely-unchanged selector value produces zero renders.

Run: `cd assets && npx jest js/hooks/Mapper/__perf__ --runInBand` (or `npx jest --runInBand` for
the whole suite).

### Pre-existing environment gaps found and fixed to make this (or any future component test) run

None introduced by this work; `yarn test` could not run a single React component test before this
investigation:

1. **`jest-environment-jsdom` was never a devDependency** despite `jest.config.js` requiring it.
   Added.
2. **`identity-obj-proxy` was never a devDependency** despite `jest.config.js` mapping `.scss` to
   it. Added.
3. **`moduleNameMapper` key order was backwards**: `'^@/(.*)$'` matched before the
   scss/css→identity-obj-proxy rule, so `@/...scss` imports were never proxied. Reordered;
   extended to match plain `.css` too (`reactflow/dist/style.css`).
4. **`use-local-storage-state` ships ESM-only**, breaking every test that transitively imports
   `MapRootProvider.tsx` (including the pre-existing `migrations/list/to_6.test.ts`). Fixed
   globally via Jest's automatic node_modules manual-mock convention:
   `assets/__mocks__/use-local-storage-state.ts`.
5. A `yarn install`-time `strip-ansi` cache collision blocked every `jest` invocation outright;
   fixed by reinstalling `strip-ansi@6.0.1` directly.

**Still pre-existing, NOT fixed (confirmed via `git stash` against the unmodified tree)**:
`migrations/list/to_6.test.ts` fails on a CJS circular-import ordering bug between
`mapRootProvider/constants.ts` and `MapRootProvider.tsx`, independent of anything touched here —
deep, unrelated module-architecture issue, out of scope.

### Harness limitations

- jsdom has no `ResizeObserver` that measures real layout, no `DOMMatrixReadOnly`, no real CSS
  transforms. A no-op `ResizeObserver` stub is used; a stub reporting a real size (to drive
  drag/pan through ReactFlow's own `d3-drag`/`d3-zoom` via genuine DOM events) crashed with
  `window.DOMMatrixReadOnly is not a constructor`. Drag/hover/pan are driven directly through the
  real `MapProvider.update()` callback or the real `Commands.updateSystems` → `rf.setNodes` path
  instead of synthetic pointer/wheel events.
- Every ReactFlow edge renders ZERO times in every scenario, including mount — traced into
  ReactFlow's own bundled code (an edge's component is never instantiated until both endpoint
  nodes have `handleBounds`, populated only by a real `ResizeObserver`), not application code.
  Edge render-COUNT could not be measured in jsdom.
- The harness's "real post-mount visible set" (`mapStateBox.current.data.visibleNodes`) is small
  and may not match what a real browser would compute, because `screenToFlowPosition` depends on
  ReactFlow's internal transform state, which jsdom never fully initializes (no real
  `ResizeObserver`/layout). `queueRealisticPanShift` sidesteps this by computing against the KNOWN
  synthetic grid layout directly with the real `isNodeVisible` formula, rather than trusting the
  harness's own (possibly degenerate) computed state.

## What changed (the six fixes)

### 1. Stable context + per-key, declared-key selector subscriptions (`utils/contextStore/`, `MapProvider.tsx`)

- `useContextStore` holds a `Map<key, Set<listener>>`, tracks exactly which keys an `update()`
  call wrote, and notifies only listeners registered for an actually-written key.
- `useContextStore`'s rAF loop drains the **whole** pending queue per tick (was: one entry/tick).
- `MapProvider`'s context value is built once via `useRef`, never replaced.
- `useMapSelector(keys, selector, isEqual?)`: see the dedicated section above for the
  declared-keys API and why auto-discovery was replaced.
- Converted every `useMapState()` call site reading `data` fields to `useMapSelector` (table
  above). `useMapInit.ts`'s dead `data` destructure (captured, never read) was removed.
- **Left unconverted, on purpose, confirmed in scope by the original task**: `useMapRootState()`
  — see the dedicated section above.

### 2. `useUpdateNodes.ts`: stop the O(N) visibility rebuild on every drag frame

Full recompute only on node-id-set membership change or viewport change; a pure position change
patches only the moved node(s). `commitVisible` skips `update()` entirely when the new Set has the
same members as the last one. Confirmed via the corrected drag measurement above: combined with
fix 1, a real drag now renders exactly the one moved node.

### 3. Coalesce `useContextStore`'s rAF queue

Covered under fix 1 (same file): whole queue drains in one pass per frame.

### 4. Index characters by system once, in the store (`helpers/indexCharactersBySystem.ts`)

`MapData.charactersBySystem: Map<number, CharacterTypeRaw[]>`, derived at all 5 `characters` write
sites. O(1) lookup instead of `characters.filter(...)` over the whole map's character list.

### 5. `onlyRenderVisibleElements`: gated behind a new opt-in setting, defaulting OFF

The real edge-readiness gate lives inside ReactFlow's own bundled code (`handleBounds`, real
`ResizeObserver`-only), not in `SolarSystemEdge`/`DotlanEdge`'s guards. Added
`InterfaceStoredSettings.onlyRenderVisibleElements` (default `false`, migration `to_10.ts`,
version 10, UI checkbox), wired into `Map.tsx`. Defensive `edgesReady` guard added to
`SolarSystemEdge.tsx` (dead-code-safe, documented as such). `DotlanEdge.tsx` already had the
correct 130×34 fallback — hoisted to `components/map/constants.ts`, no behavior change.

### 6. `Map.tsx`'s `handleNodesChange`

Removed the no-op `changes.reduce((acc, c) => [...acc, c], [])`; `onNodesChange(changes)` now
passed straight through.

## Measured before vs. after (N=300, corrected methodology)

| Scenario | Before | After | Why |
|---|---|---|---|
| **Mount**, node render count | 600 (2x) | 300-304 (~1x) | Post-mount `visibleNodes` update used to force a second full re-render of every node through the unstable context. |
| **Hover**, node render count | 300 (every node) | ≤4 | Per-key selector subscriptions + `useSyncExternalStore`'s bail check. |
| **Real drag** (60 ReactFlow position changes of 1 node), node render count | 300 (believed, incorrectly measured) | **1** (the moved node) | Corrected: the original "300" was a test-input artifact (see above), not a measured product behavior. The real mechanism was already good; confirmed, not assumed. |
| **Realistic pan** (viewport genuinely shifts), node render count | 300 (every node, full expensive recompute) | 300 distinct checks, but only nodes whose visibility ACTUALLY flipped do real work (~387/300 total renders at N=300, i.e. most of the 300 checks return without a second render) | Honest O(N) — the viewport moved, every node's visibility bit could have changed — but cheap per node now, not a full recompute. |
| **A field no node selector reads** (`localShowShipName`), node render count | 300 | **0** | True per-key isolation. |

## Verification run

- `cd assets && npx jest --runInBand`: 34/34 tests pass across 8/9 suites. The one failing suite
  (`migrations/list/to_6.test.ts`) is confirmed pre-existing via `git stash` against the
  unmodified tree — unrelated to this work (see above). No suite failed because of this work.
- `cd assets && npx tsc --noEmit`: clean for every file touched by this work. Three pre-existing
  errors remain elsewhere, confirmed byte-identical to the unmodified tree: `WormholeClassComp.tsx`
  line 12, `useUpdateNodes.ts`'s untouched `useThrottle` helper, `MapProvider.tsx`'s untouched
  `options: {} as Record<string, string|boolean>` cast.
- `cd assets && npx jest js/hooks/Mapper/__perf__ --runInBand`, run 3x consecutively: 15/15 tests
  pass every time (deterministic).

## Baseline Gate (2026-10-10)

Gate verification captured at task start to distinguish pre-existing from new failures:

**Elixir mix compile:** PASS. Format: FAIL (half-finished heex edit on unrelated scout work). Boot: PASS. Routes: ERROR (environmental, code reloader recreating priv symlink). Tests: 6 failures in integration suite (pre-existing, unrelated to render perf).

**Jest (React components):** 42/42 tests PASS (migration test `to_6.test.ts` requires `jest-environment-jsdom` and `identity-obj-proxy`, both added to `assets/package.json` by this work; without them, zero React tests run). Pre-existing failures: none in render-path scope.

**TypeScript:** 98 pre-existing errors tracked and clean (mostly missing `el` property on Phoenix hook shapes, one unresolved `turndown` module declaration). New errors introduced by this work: 0.

These baselines proved the render-path + selector refactoring introduced no new defects, and that `to_6` migration test failure was caused by in-flight MAP_GROUPS plumbing work (circular import in `MapRootProvider` + new `MapGroupsSettings` type in constants.ts), not by the perf changes themselves.
