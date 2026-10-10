/**
 * Map render-path perf harness - shared setup, imported by mapRenderPerf.scenarios.test.tsx,
 * mapRenderPerf.smoke.test.tsx and mapRenderPerf.regression.test.tsx.
 *
 * Split into its own (non-test) module, NOT because the test content differs, but because Jest
 * gives each TEST FILE its own fresh module registry - module-level state here (nodeRenderCounts,
 * mapStateBox, staticInfoById, pending rAF/timers from a previous describe block's mounted tree)
 * was observed to leak ACROSS describe blocks when they shared one test file (a hover test
 * directly after a 600-node scenario test sometimes found node "30000000" missing from the DOM;
 * localStorage/timer-driven settle work from an unrelated prior test occasionally fired inside
 * the NEXT test's measurement window). Each of the three test files below gets its own registry,
 * so this contamination cannot happen between them; within one file, scenarios/tests still mount
 * fresh per test (see `mountHarness`) and are therefore still isolated from each other.
 *
 * Mounts the REAL Map canvas (MapRootProvider -> MapProvider -> ReactFlow -> Map.tsx) with a
 * synthetic map of N systems, drives it through: mount, one node drag (~60 `visibleNodes` fan-out
 * updates), one hover enter/leave, one viewport pan, and counts renders per component via
 * React.Profiler (onRender's `actualDuration` also gives wall-clock per commit).
 *
 * jsdom has no ResizeObserver; a no-op stub is installed below (ReactFlow only needs it to not
 * throw - it never sizes nodes in jsdom, so every node width/height stays at the 130x34 fallback
 * set by convertSystem2Node, which is enough to drive the identical code paths under test).
 *
 * A stub reporting REAL dimensions was also tried, to drive drag/pan through genuine pointer/
 * wheel DOM events via ReactFlow's own d3-drag/d3-zoom. That hit `window.DOMMatrixReadOnly is
 * not a constructor` inside ReactFlow's viewport transform math the instant a node's size
 * updated - jsdom implements neither `DOMMatrixReadOnly` nor real CSS layout, and d3-zoom/d3-drag
 * need both for coordinate math. That is this harness's "real ReactFlow in jsdom proves
 * impractical" case, scoped narrowly: mount and node-render-COUNT measurement work completely
 * with real components and the simple stub below; only DOM/d3-driven drag and pan do not. Hover
 * and the per-drag-frame `visibleNodes` fan-out are instead driven directly through the real
 * `MapProvider.update()` callback (captured via a thin `useMapState` wrapper below) - the exact
 * same function every real pointer handler in Map.tsx calls - so every node/edge component still
 * renders through its real code path; only the DOM/d3 input-simulation layer is bypassed.
 *
 * `@testing-library/react` is NOT a devDependency here (checked assets/package.json) and was not
 * added; mounting uses `react-dom/client` + `react-dom/test-utils` `act`, which ship with the
 * `react-dom` dependency already in package.json.
 */
import { Profiler, ProfilerOnRenderCallback } from 'react';
import { act } from 'react-dom/test-utils';
import { createRoot, Root } from 'react-dom/client';

// Node 26 (this repo's test runtime) ships `Promise.withResolvers` (used below per project
// convention over `new Promise((resolve) => ...)`), but the project's `tsconfig.json` targets
// `lib: ["ES2020", ...]`, which predates its TS types (added in ES2024 lib). Augmenting locally
// avoids bumping the whole project's lib target just for this harness.
declare global {
  interface PromiseConstructor {
    withResolvers<T>(): {
      promise: Promise<T>;
      resolve: (value: T | PromiseLike<T>) => void;
      reject: (reason?: unknown) => void;
    };
  }
}
class StubResizeObserver implements ResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver = StubResizeObserver;
// Silence the (benign, jsdom-only) "not configured to support act" warning React Flow trips via
// an internal zustand store update outside our `act()` call.
(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// ---------------------------------------------------------------------------------------------
// getSystemStaticInfo is backed by a module-private Map populated over the wire in production
// (useLoadSystemStatic -> OutCommand.getSystemStaticInfos). Mocking the module lets the harness
// hand back synthetic static info synchronously with zero network/outCommand round trips, without
// touching the real cache-population code path (which is not part of the render perf question).
// ---------------------------------------------------------------------------------------------

// @uiw/react-codemirror's codemirror language packages break under ts-jest's CJS transform
// (`@codemirror/lang-html` ships an ESM build that `.configure`-calls something undefined when
// required as CJS). MarkdownEditor (system notes widget) pulls that whole chain in transitively
// through MapRootProvider -> useStoreWidgets -> mapInterface widgets, even though nothing in the
// render-perf path under test touches it. Stub it out; see docs/chewy/map-perf-findings.md
// "Harness limitations" for the full import chain and why this is a pre-existing environment gap,
// not something papering over the hot path.
jest.mock('@/hooks/Mapper/components/mapInterface/components/MarkdownEditor', () => ({
  MarkdownEditor: () => null,
}));

// mapRootProvider -> useStoreWidgets -> mapInterface/constants.tsx pulls in the ENTIRE widget
// render tree (LocalCharacters, SystemSignatures, ..., PingsInterface) purely to list them as
// `content: () => <Widget/>` window registry entries - none of them ever render in this harness
// (no widget window is opened). That barrel also round-trips back through `ui-kit` into
// mapRootProvider itself; under ts-jest's CommonJS transform (unlike Vite/ESM) that circularity
// resolves eagerly and `PingsInterface.tsx`'s module-level `TooltipPosition.top` read throws
// `Cannot read properties of undefined` because `ui-kit/WdTooltipWrapper`'s enum hasn't finished
// initializing yet. Real, order-dependent CJS-vs-ESM circular-import difference - not a hot-path
// bug - documented in docs/chewy/map-perf-findings.md "Harness limitations".
jest.mock('@/hooks/Mapper/components/mapInterface/widgets', () => ({
  CommentsWidget: () => null,
  LocalCharacters: () => null,
  SystemInfo: () => null,
  SystemSignatures: () => null,
  SystemStructures: () => null,
  WRoutesPublic: () => null,
  WRoutesUser: () => null,
  WRoutesBy: () => null,
  WSystemKills: () => null,
}));

// `use-local-storage-state` is handled globally by __mocks__/use-local-storage-state.ts (Jest's
// automatic node_modules manual-mock convention) - no per-file jest.mock() needed here.

// `../../hooks` (map/hooks/index.ts) re-exports `useBeautify`, which imports
// `layout/beautifyClient.ts` (a concurrent, unrelated session's in-progress work -
// `components/map/layout/**` is out of scope here) - that file uses `import.meta.url` to
// construct a Worker, which Jest's CommonJS transform cannot parse. Mocked at its own module
// path (not the barrel) so Jest's module resolution intercepts it before the parse ever happens,
// regardless of which barrel re-exports it.
jest.mock('@/hooks/Mapper/components/map/hooks/useBeautify', () => ({
  useBeautify: () => ({ beautify: () => {}, isEnabled: false, isBeautifying: false }),
}));
// Map.tsx's './components' barrel also exports ContextMenuRoot/ContextMenuConnection, which pull
// in `ui-kit/index.ts` - a single barrel re-exporting ~20 unrelated components (CharacterCard,
// SystemView, MarkdownTextViewer, WindowManager, ...), each with its own ESM-only transitive dep
// (react-markdown, quill, @codemirror/*, use-local-storage-state - already hit three of these
// above). None of that is on the node/edge render hot path this harness measures, and jest has no
// transformIgnorePatterns/babel preset-env override to load ESM packages from node_modules, so
// real-mounting through this barrel is a whack-a-mole of unrelated ESM deps, not a hot-path
// finding. Mocking these three narrow modules (not the whole './components' barrel - that would
// also take out the real SolarSystemEdge under test) cuts the chain off at its root.
jest.mock('@/hooks/Mapper/components/map/components/ContextMenuRoot', () => ({
  ContextMenuRoot: () => null,
  useContextMenuRootHandlers: () => ({ handleRootContext: () => {} }),
}));
jest.mock('@/hooks/Mapper/components/map/components/ContextMenuConnection', () => ({
  ContextMenuConnection: () => null,
  useContextMenuConnectionHandlers: () => ({ handleConnectionContext: () => {} }),
}));
jest.mock('@/hooks/Mapper/components/contexts/ContextMenuSystemMultiple', () => ({
  ContextMenuSystemMultiple: () => null,
  useContextMenuSystemMultipleHandlers: () => ({}),
}));

// `ui-kit/WdTooltipWrapper` imports from the `ui-kit` barrel itself (self-referencing), and that
// barrel also exports `MarkdownTextViewer` (react-markdown/remark-gfm/remark-breaks, all ESM-
// only). WdTooltipWrapper is used directly inside SolarSystemEdge/SolarSystemNodeDefault - the
// hot path itself - so this is not avoidable by mocking anything context-menu-adjacent; these
// three leaf packages are mocked by name instead.
jest.mock('react-markdown', () => ({ __esModule: true, default: () => null }));
jest.mock('remark-gfm', () => ({ __esModule: true, default: () => null }));
jest.mock('remark-breaks', () => ({ __esModule: true, default: () => null }));
import type { SolarSystemStaticInfoRaw } from '@/hooks/Mapper/types/system';

const staticInfoById = new Map<number, SolarSystemStaticInfoRaw>();

jest.mock('@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic', () => ({
  getSystemStaticInfo: (id: number | string | undefined) => {
    if (id == null) return undefined;
    return staticInfoById.get(typeof id === 'number' ? id : parseInt(id, 10));
  },
  useLoadSystemStatic: () => ({ addSystemStatic: () => {}, systems: staticInfoById, lastUpdateKey: 0, loading: false, loadSystems: async () => {} }),
  loadSystemStaticInfo: async () => [],
}));

// Per-node / per-edge render counters. Map.tsx hardcodes `nodeTypes`/`edgeTypes` internally (not
// prop-injectable), so individual node/edge render counts can't be read off a single root
// Profiler (its actualDuration/commit-count is for the WHOLE subtree, not "how many of the N
// nodes re-ran"). Wrapping the real components at the module boundary - unwrapping
// SolarSystemNodeDefault's `memo()` via `.type` to count actual render-function invocations
// (not just attempts memo may have bailed out of) - gives a true per-component count while still
// exercising the real implementation underneath.
export const nodeRenderCounts = new Map<string, number>();
export const edgeRenderCounts = new Map<string, number>();

jest.mock('@/hooks/Mapper/components/map/components/SolarSystemNode/SolarSystemNodeDefault', () => {
  const actual = jest.requireActual('@/hooks/Mapper/components/map/components/SolarSystemNode/SolarSystemNodeDefault');
  const ReactActual = jest.requireActual('react');
  const innerRender = actual.SolarSystemNodeDefault.type;
  const Wrapped = ReactActual.memo((props: { id: string }) => {
    nodeRenderCounts.set(props.id, (nodeRenderCounts.get(props.id) ?? 0) + 1);
    return innerRender(props);
  });
  return { __esModule: true, SolarSystemNodeDefault: Wrapped };
});

jest.mock('@/hooks/Mapper/components/map/components/SolarSystemEdge/SolarSystemEdge', () => {
  const actual = jest.requireActual('@/hooks/Mapper/components/map/components/SolarSystemEdge/SolarSystemEdge');
  const Wrapped = (props: { id: string }) => {
    edgeRenderCounts.set(props.id, (edgeRenderCounts.get(props.id) ?? 0) + 1);
    return actual.SolarSystemEdge(props);
  };
  return { __esModule: true, SolarSystemEdge: Wrapped, SHIP_SIZES_COLORS: actual.SHIP_SIZES_COLORS };
});

// Captures the REAL `MapProvider.update()` (and current `data`) on every render of every real
// `useMapState()` consumer in the mounted tree (nodes, edges, Map.tsx itself), by wrapping the
// real hook rather than replacing it - every consumer still gets the genuine context value.
// `update` is referentially stable (`useCallback(..., [])` inside `useContextStore`), so any
// captured copy is the one true queueing function. Used to drive hover/drag directly through the
// real update-queue -> rAF -> context-identity-change -> re-render pipeline, bypassing only the
// unreliable DOM/d3 pointer-event layer (see file header).
import type { MapContextProps } from '@/hooks/Mapper/components/map/MapProvider';
export const mapStateBox: { current: MapContextProps | null } = { current: null };
jest.mock('@/hooks/Mapper/components/map/MapProvider', () => {
  const actual = jest.requireActual('@/hooks/Mapper/components/map/MapProvider');
  return {
    ...actual,
    useMapState: (...args: unknown[]) => {
      const result = actual.useMapState(...args);
      mapStateBox.current = result;
      return result;
    },
  };
});

// Import AFTER the mock registration above.
import { Map as MapCanvas } from '@/hooks/Mapper/components/map/Map';
import { MapRootProvider, useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { ToastProvider } from '@/hooks/Mapper/ToastProvider';
import { ReactFlowProvider } from 'reactflow';
import { SolarSystemRawType } from '@/hooks/Mapper/types/system';
import { OutCommandHandler } from '@/hooks/Mapper/types/mapHandlers';
import { convertSystem2Node } from '@/hooks/Mapper/components/map/helpers';
import { isNodeVisible, Viewport } from '@/hooks/Mapper/components/map/hooks/useUpdateNodes';

const mockOutCommand: OutCommandHandler = async () => ({}) as never;

// -------------------------------- synthetic map construction -----------------------------------

const GRID_COLS = 20;
const GRID_SPACING_X = 200;
const GRID_SPACING_Y = 150;

export function buildSystems(n: number): SolarSystemRawType[] {
  const systems: SolarSystemRawType[] = [];
  for (let i = 0; i < n; i++) {
    const id = String(30000000 + i);
    const col = i % GRID_COLS;
    const row = Math.floor(i / GRID_COLS);

    staticInfoById.set(30000000 + i, {
      region_id: 10000001,
      constellation_id: 20000001,
      solar_system_id: 30000000 + i,
      solar_system_name: `J${100000 + i}`,
      solar_system_name_lc: `j${100000 + i}`,
      constellation_name: 'Test Constellation',
      region_name: 'Test Region',
      system_class: 5,
      security: '-1.0',
      type_description: 'Class 5',
      class_title: 'C5',
      is_shattered: false,
      effect_name: '',
      effect_power: 0,
      statics: ['N110'],
      wandering: [],
      triglavian_invasion_status: 'Normal',
      sun_type_id: 3800,
    });

    systems.push({
      id,
      position: { x: col * GRID_SPACING_X, y: row * GRID_SPACING_Y },
      description: null,
      labels: null,
      locked: false,
      tag: null,
      status: 0,
      name: null,
      temporary_name: null,
      linked_sig_eve_id: null,
      comments_count: 0,
      system_static_info: staticInfoById.get(30000000 + i)!,
      system_signatures: [],
    });
  }
  return systems;
}

export function buildConnections(systems: SolarSystemRawType[]): SolarSystemConnection[] {
  // chain connectivity: close to a real wormhole map's N-ish edge count.
  const connections: SolarSystemConnection[] = [];
  for (let i = 1; i < systems.length; i++) {
    connections.push({
      id: `${systems[i - 1].id}_${systems[i].id}`,
      time_status: 0,
      mass_status: 0,
      ship_size_type: 0,
      locked: false,
      source: systems[i - 1].id,
      target: systems[i].id,
    });
  }
  return connections;
}

// CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) test support - spreads
// `n` systems evenly across `regionCount` k-space regions (region ids 11000000.. so they never
// collide with `buildSystems`' single region 10000001), chained together the same way
// `buildConnections` does, so a region boundary has exactly the connections `deriveCollapsedView`
// is meant to aggregate. Populates the SAME mocked `getSystemStaticInfo` cache as `buildSystems`.
export function buildMultiRegionSystems(n: number, regionCount: number): SolarSystemRawType[] {
  const systems: SolarSystemRawType[] = [];
  for (let i = 0; i < n; i++) {
    const id = String(30000000 + i);
    const col = i % GRID_COLS;
    const row = Math.floor(i / GRID_COLS);
    const regionIndex = i % regionCount;
    const regionId = 11000000 + regionIndex;

    staticInfoById.set(30000000 + i, {
      region_id: regionId,
      constellation_id: 21000000 + regionIndex,
      solar_system_id: 30000000 + i,
      solar_system_name: `K${100000 + i}`,
      solar_system_name_lc: `k${100000 + i}`,
      constellation_name: `Test Constellation ${regionIndex}`,
      region_name: `Test Region ${regionIndex}`,
      system_class: 7, // SOLAR_SYSTEM_CLASS_IDS.hs - k-space, not in isWormholeSpace's list
      security: '0.5',
      type_description: 'High-sec',
      class_title: '',
      is_shattered: false,
      effect_name: '',
      effect_power: 0,
      statics: [],
      wandering: [],
      triglavian_invasion_status: 'Normal',
      sun_type_id: 3800,
    });

    systems.push({
      id,
      position: { x: col * GRID_SPACING_X, y: row * GRID_SPACING_Y },
      description: null,
      labels: null,
      locked: false,
      tag: null,
      status: 0,
      name: null,
      temporary_name: null,
      linked_sig_eve_id: null,
      comments_count: 0,
      system_static_info: staticInfoById.get(30000000 + i)!,
      system_signatures: [],
    });
  }
  return systems;
}

// ---------------------------------------------------------------------------------------------
// Map.tsx seeds its local useNodesState/useEdgesState from its own module-level `initialNodes`/
// `initialEdges` constants (2 hardcoded systems) and otherwise only mutates them through its own
// `MapHandlers.command()` ref (components/map/hooks/useMapHandlers.ts), separate from
// MapRootProvider's own `fwdRef`/`command()` (which only updates MapRootData, not the ReactFlow
// canvas - production wires BOTH refs to the same LiveView event in MapRoot.tsx/MapWrapper.tsx,
// not reproduced here since that pulls in the whole app shell). The harness drives the canvas the
// same way production's `init` map_event does: `command(Commands.init, {...})`, which internally
// debounces one tick (10ms, lodash.debounce in useEventBuffer) before calling `rf.setNodes`.
// ---------------------------------------------------------------------------------------------
import { MapHandlers, Commands, CommandInit, CommandUpdateSystems, CommandCharactersUpdated } from '@/hooks/Mapper/types/mapHandlers';
import { SolarSystemConnection } from '@/hooks/Mapper/types/connection';
import { RoutesList } from '@/hooks/Mapper/types/routes';
import { UserPermission, UserPermissions } from '@/hooks/Mapper/types/permissions';
import { MapOptions } from '@/hooks/Mapper/types/options';

const EMPTY_USER_PERMISSIONS: UserPermissions = {
  [UserPermission.ADMIN_MAP]: false,
  [UserPermission.MANAGE_MAP]: false,
  [UserPermission.VIEW_SYSTEM]: false,
  [UserPermission.VIEW_CHARACTER]: false,
  [UserPermission.VIEW_CONNECTION]: false,
  [UserPermission.ADD_SYSTEM]: false,
  [UserPermission.ADD_CONNECTION]: false,
  [UserPermission.UPDATE_SYSTEM]: false,
  [UserPermission.TRACK_CHARACTER]: false,
  [UserPermission.DELETE_CONNECTION]: false,
  [UserPermission.DELETE_SYSTEM]: false,
  [UserPermission.LOCK_SYSTEM]: false,
  [UserPermission.ADD_ACL]: false,
  [UserPermission.DELETE_ACL]: false,
  [UserPermission.DELETE_MAP]: false,
};

const EMPTY_MAP_OPTIONS: MapOptions = {
  allowed_copy_for: UserPermission.VIEW_SYSTEM,
  allowed_paste_for: UserPermission.VIEW_SYSTEM,
  layout: '',
  restrict_offline_showing: 'false',
  show_linked_signature_id: 'false',
  show_linked_signature_id_temp_name: 'false',
  show_temp_system_name: 'false',
  store_custom_labels: 'false',
};

export type RenderCounts = Record<string, { count: number; totalActualMs: number }>;

function makeProfilerHandler(counts: RenderCounts): ProfilerOnRenderCallback {
  return (id, _phase, actualDuration) => {
    const entry = counts[id] ?? { count: 0, totalActualMs: 0 };
    entry.count += 1;
    entry.totalActualMs += actualDuration;
    counts[id] = entry;
  };
}

export interface HarnessHandle {
  root: Root;
  container: HTMLDivElement;
  mapRef: { current: MapHandlers | null };
  // Separate from `mapRef`: `MapRootProvider`'s own command dispatcher
  // (`useMapRootHandlers.ts`), reached via its `fwdRef` prop - production wires this to the SAME
  // LiveView event as `mapRef`, but they drive two independent stores (`MapRootData` vs
  // `MapData`). Used to drive a realistic `charactersUpdated`/`detailedKillsUpdated` burst
  // through the real command handlers, not a hand-rolled `MapRootProvider.update()` call.
  mapRootRef: { current: MapHandlers | null };
  counts: RenderCounts;
}

export async function mountHarness(
  n: number,
  opts?: {
    systems?: SolarSystemRawType[];
    connections?: SolarSystemConnection[];
    groupsEnabled?: boolean;
    mapSlug?: string;
  },
): Promise<HarnessHandle> {
  const container = document.createElement('div');
  Object.defineProperty(container, 'getBoundingClientRect', {
    value: () => ({ x: 0, y: 0, top: 0, left: 0, right: 1200, bottom: 800, width: 1200, height: 800, toJSON() {} }),
  });
  document.body.appendChild(container);
  const root = createRoot(container);
  const mapRef: { current: MapHandlers | null } = { current: null };
  const mapRootRef: { current: MapHandlers | null } = { current: null };
  const counts: RenderCounts = {};
  const onRender = makeProfilerHandler(counts);

  act(() => {
    root.render(
      <Profiler id="root" onRender={onRender}>
        <ToastProvider>
          <ReactFlowProvider>
            <MapRootProvider outCommand={mockOutCommand} fwdRef={mapRootRef}>
              <ProfiledMap
                onRender={onRender}
                refCb={(h: MapHandlers | null) => {
                  mapRef.current = h;
                }}
              />
            </MapRootProvider>
          </ReactFlowProvider>
        </ToastProvider>
      </Profiler>,
    );
  });

  const systems = opts?.systems ?? buildSystems(n);
  const connections = opts?.connections ?? buildConnections(systems);
  const initCommand: CommandInit = {
    systems,
    connections,
    system_signatures: {},
    kills: [],
    system_static_infos: [],
    wormholes: [],
    effects: [],
    characters: [],
    present_characters: [],
    user_characters: [],
    user_permissions: EMPTY_USER_PERMISSIONS,
    hubs: [],
    user_hubs: [],
    routes: { loading: false, solar_system_id: '', routes: [], systems_static_data: [] } satisfies RoutesList,
    // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) test support.
    options: opts?.groupsEnabled ? { ...EMPTY_MAP_OPTIONS, groups_enabled: 'true' } : EMPTY_MAP_OPTIONS,
    expired_characters: [],
    ...(opts?.mapSlug != null ? { map_slug: opts.mapSlug } : {}),
  };

  act(() => {
    mapRef.current?.command(Commands.init, initCommand);
    // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) - `MapRootData`
    // (systems/connections/options) is a SEPARATE store from `MapData`, written by a DIFFERENT
    // `Commands.init` handler registered on `mapRootRef`, not `mapRef` - production wires both
    // refs to the same LiveView event (see this file's header), so both need the init dispatch
    // for anything reading `MapRootData.systems`/`options`/`connections` (e.g. `useMapGroups`)
    // to see real data in this harness.
    mapRootRef.current?.command(Commands.init, initCommand);
  });
  // useMapInit's node/edge seeding goes through useEventBuffer (lodash.debounce, 10ms) before
  // calling rf.setNodes/rf.setEdges - let the real timer fire, then flush extra animation frames
  // so useUpdateNodes's resulting `visibleNodes` computation (itself routed through
  // useContextStore's rAF queue) is fully settled BEFORE a scenario starts measuring - otherwise
  // a still-pending post-mount settle can fire during the NEXT act()/flush window and get
  // misattributed to whatever that scenario is actually testing.
  await act(async () => {
    const { promise, resolve } = Promise.withResolvers<void>();
    setTimeout(resolve, 30);
    await promise;
  });
  await flushRAF(10);

  return { root, container, mapRef, mapRootRef, counts };
}

// Wraps Map, profiling each node/edge render individually via a per-id Profiler injected through
// a patched nodeTypes/edgeTypes is not possible without editing Map.tsx (out of scope: measurement
// only). Instead we profile at the SolarSystemNodeDefault / SolarSystemEdge module boundary using
// jest's module mock wrapping: re-export the real components wrapped in Profiler.
import { OnMapSelectionChange } from '@/hooks/Mapper/components/map/map.types';

const noopSelectionChange: OnMapSelectionChange = () => {};
// Stable reference: Map.tsx's own `useEffect([showKSpaceBG, isThickConnections, pings, update,
// localShowShipName])` refires `update({...x, showKSpaceBG, isThickConnections, pings,
// localShowShipName})` whenever `pings` changes identity. A fresh `[]` literal passed as a prop
// on every `ProfiledMap` render would refire that effect spuriously, rewriting (not actually
// changing, but still marking "changed") `isThickConnections`/`showKSpaceBG` on every commit -
// contaminating any test that asserts "this field causes zero fan-out" with a harness artifact,
// not a product behaviour (a real `pings` prop is stable unless pings actually changed).
const STABLE_EMPTY_PINGS: never[] = [];
// Stable, module-level - `Map.tsx`'s `Map` export is `memo()`-wrapped (see its header comment),
// which only bails on an ancestor-driven re-render if EVERY prop is referentially stable. An
// inline `() => {}` here would be a fresh function every `ProfiledMap` render, defeating that
// memo for a reason that is a harness artifact, not a real caller's behaviour (a real caller
// wires this through its own `useCallback`, as `MapWrapper.tsx` does).
const noopSystemContextMenu = () => {};

function ProfiledMap({ onRender, refCb }: { onRender: ProfilerOnRenderCallback; refCb: (h: MapHandlers | null) => void }) {
  // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) test support - this
  // plain `useMapRootState()` read is fine here: `ProfiledMap` sits OUTSIDE `Map.tsx`'s own
  // `MapProvider`/node-edge render-perf pipeline (it's test wiring, not part of what the perf
  // suite measures), so it being woken on every `MapRootProvider` write has no bearing on any
  // node/edge render-count assertion.
  const {
    storedSettings: { settingsGroupsUpdate },
  } = useMapRootState();

  return (
    <Profiler id="map" onRender={onRender}>
      <MapCanvas
        ref={refCb}
        onCommand={mockOutCommand}
        onSelectionChange={noopSelectionChange}
        onSystemContextMenu={noopSystemContextMenu}
        pings={STABLE_EMPTY_PINGS}
        settingsGroupsUpdate={settingsGroupsUpdate}
      />
    </Profiler>
  );
}

export function unmount(h: HarnessHandle) {
  act(() => {
    h.root.unmount();
  });
  h.container.remove();
}

export function flushRAF(ticks: number): Promise<void> {
  return act(async () => {
    for (let i = 0; i < ticks; i++) {
      const { promise, resolve } = Promise.withResolvers<void>();
      requestAnimationFrame(() => resolve());
      await promise;
    }
  });
}

// `MapProvider`'s `useContextStore` only applies a queued `update()` on the NEXT animation
// frame (drains the WHOLE pending queue per tick, not one entry per tick, after Hotspot 3 - see
// useContextStore.ts) - real production behaviour, not a jsdom artifact. A synchronous `act(fn)`
// around a DOM dispatch never lets a real rAF fire, so every interaction measured zero renders
// until this was added: dispatch synchronously (matches real event dispatch timing), then flush
// enough animation frames to drain the queue.
export async function timeAct(fn: () => void, flushTicks: number): Promise<number> {
  const start = performance.now();
  act(fn);
  await flushRAF(flushTicks);
  return performance.now() - start;
}

// CORRECTED (see docs/chewy/map-perf-findings.md "Corrected drag measurement"): an earlier
// version of this helper called `update({ visibleNodes: new Set(allSystemIds) })` - claiming
// EVERY node is visible - repeatedly. Since `buildSystems`'s grid (up to 20 cols x 200px =
// 4000px wide) is far bigger than the harness's 1200x800 viewport stub, the REAL post-mount
// `visibleNodes` (computed by the real `useUpdateNodes` hook) is a SMALL SUBSET of all N ids -
// so "claim everyone visible" was a genuine semantic change for most nodes on its first call,
// not the no-op it was meant to represent. Confirmed via an isolated unit test
// (useMapSelector.unit.test.tsx) and a diagnostic (diagnostic.test.tsx) that a truly-unchanged
// `visibleNodes` update produces ZERO renders, and that a REAL drag (moving one node's actual
// ReactFlow position, below) only ever renders the ONE moved node.
//
// Drives a REAL drag: N ReactFlow position changes of ONE node via the same
// `Commands.updateSystems` -> `rf.setNodes` path a system-position update takes in production,
// letting the REAL (fixed) `useUpdateNodes` hook decide whether `visibleNodes` needs touching at
// all - not a direct, synthetic `MapProvider.update()` call.
export async function dragOneNodeViaReactFlow(mapRef: { current: MapHandlers | null }, systems: SolarSystemRawType[], frames: number) {
  await act(async () => {
    for (let frame = 0; frame < frames; frame++) {
      const moved = { ...systems[0], position: { x: 100 + frame * 3, y: 100 + frame * 3 } };
      mapRef.current?.command(Commands.updateSystems, [moved] as CommandUpdateSystems);
    }
    for (let i = 0; i < 15; i++) {
      const { promise, resolve } = Promise.withResolvers<void>();
      requestAnimationFrame(() => resolve());
      await promise;
    }
  });
}

// Queues `count` updates that re-assert the CURRENT `visibleNodes` membership unchanged - the
// genuinely-no-op case (as opposed to the flawed "claim everyone visible" pattern above). Proves
// the store correctly produces ZERO renders for a value that didn't actually change.
export function queueGenuinelyUnchangedVisibleNodes(count: number) {
  const data = mapStateBox.current?.data;
  const update = mapStateBox.current?.update;
  if (!data || !update) {
    throw new Error('MapProvider.update/data not captured');
  }
  const currentIds = Array.from(data.visibleNodes);
  act(() => {
    for (let i = 0; i < count; i++) {
      update({ visibleNodes: new Set(currentIds) });
    }
  });
}

// Mirrors Map.tsx's `onNodeMouseEnter={(_, node) => update({ hoverNodeId: node.id })}` /
// `onNodeMouseLeave={() => update({ hoverNodeId: null })}` directly - as two SEPARATE flushed
// steps (a real hover has non-zero dwell time between enter and leave; queuing both before
// either is drained would let `useContextStore`'s whole-queue-drain coalesce them into a
// net-no-op in the SAME frame, which is not what a real hover does).
export async function hoverEnterThenLeave(nodeId: string, flushTicksEach: number): Promise<number> {
  const update = mapStateBox.current?.update;
  if (!update) {
    throw new Error('MapProvider.update not captured');
  }
  const start = performance.now();
  act(() => update({ hoverNodeId: nodeId }));
  await flushRAF(flushTicksEach);
  act(() => update({ hoverNodeId: null }));
  await flushRAF(flushTicksEach);
  return performance.now() - start;
}

// A REALISTIC pan: unlike drag, panning the viewport legitimately CAN change every node's
// visibility bit (the viewport itself moved), so `useUpdateNodes`'s viewport-change path
// correctly does a full recompute (`recomputeAll`, not the incremental per-node patch drag
// uses) - this is honest O(N) work, not a bug. Computed with the real `isNodeVisible` formula
// against the KNOWN synthetic grid layout (not read back from the harness's own post-mount
// state, which depends on jsdom's non-functional `screenToFlowPosition`/viewport transform) so
// the "before" and "after" sets are a genuine partial change: some nodes enter, some leave, most
// are unaffected - not "everyone becomes visible".
export function queueRealisticPanShift(n: number) {
  const update = mapStateBox.current?.update;
  if (!update) {
    throw new Error('MapProvider.update not captured');
  }
  const shiftedViewport: Viewport = { x: 600, y: 400, width: 1200, height: 800 };
  const nodes = buildSystems(n).map(convertSystem2Node);
  const nextVisible = new Set(nodes.filter(node => isNodeVisible(node, shiftedViewport)).map(node => node.id));
  act(() => {
    update({ visibleNodes: nextVisible });
  });
}

export function snapshotComponentCounts(counts: Map<string, number>): { total: number; distinct: number } {
  let total = 0;
  counts.forEach(v => (total += v));
  const result = { total, distinct: counts.size };
  counts.clear();
  return result;
}

// Drives a REALISTIC server-pushed burst: `Commands.charactersUpdated` and
// `Commands.detailedKillsUpdated`, through the REAL `MapRootProvider` command dispatcher
// (`useMapRootHandlers.ts`, reached via `mapRootRef`) - the same path a LiveView push_event for
// "another tracked character moved" or "a new kill was reported" takes in production, entirely
// independent of anything the LOCAL user's mouse is doing. `Commands.signaturesUpdated` is
// deliberately NOT included here: its real handler (`updateSystemSignatures`) is async and
// fetches over `outCommand`, not a synchronous `update()` call like the other two - burst-testing
// it would be testing the mock network round trip, not the render path. `Commands.killsUpdated`
// is also not used: its real handler is a literal no-op (see `useMapRootHandlers.ts`) -
// `detailedKillsUpdated` is the command that actually writes `MapRootData.detailedKills`.
export function queueRealisticDataBurst(mapRootRef: { current: MapHandlers | null }, systemIds: string[]) {
  const command = mapRootRef.current?.command;
  if (!command) {
    throw new Error('MapRootProvider command dispatcher not captured');
  }
  const charactersPayload: CommandCharactersUpdated = systemIds.slice(0, 5).map((systemId, i) => ({
    eve_id: `burst-char-${i}`,
    location: { solar_system_id: parseInt(systemId, 10), structure_id: null, station_id: null },
    name: `Burst Character ${i}`,
    online: true,
    ship: null,
    alliance_id: null,
    alliance_name: null,
    alliance_ticker: null,
    corporation_id: 1,
    corporation_name: 'Burst Corp',
    corporation_ticker: 'BRST',
  }));
  const killsPayload: Record<string, { killmail_id: number; solar_system_id: number; kill_time?: string }[]> = {
    [systemIds[0]]: [{ killmail_id: 1, solar_system_id: parseInt(systemIds[0], 10), kill_time: new Date().toISOString() }],
  };
  act(() => {
    command(Commands.charactersUpdated, charactersPayload);
    command(Commands.detailedKillsUpdated, killsPayload);
  });
}
