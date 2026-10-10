/**
 * Acceptance tests for the map region/wormhole-chain collapse feature (WANDERER_MAP_GROUPS),
 * mounted through the REAL `MapRootProvider` -> `MapProvider` -> ReactFlow -> `Map.tsx` stack
 * (same harness the render-perf suite uses), not a shallow/mocked render. See
 * docs/chewy/map-groups.md for the full design and these numbers.
 *
 * Collapse state is seeded directly into the SAME localStorage key/shape `useMapUserSettings`
 * reads (keyed by `map_slug`, passed through `mountHarness`'s `mapSlug` option so `useMapInit`
 * actually writes `MapRootData.map_slug`) rather than clicking through the UI - this is exactly
 * the state "collapse all regions, then reload the page" leaves behind, which is what
 * `deriveCollapsedView` has to render correctly regardless of how it got there.
 */
import {
  buildMultiRegionSystems,
  buildConnections,
  flushRAF,
  nodeRenderCounts,
  mountHarness,
  snapshotComponentCounts,
  unmount,
} from './harness';

const N = 300;
const REGION_COUNT = 10;
const MAP_SLUG = 'test-map-groups';
const LS_KEY = 'map-user-settings-v3';

function seedCollapsedGroups(collapsedGroups: string[]) {
  localStorage.setItem(
    LS_KEY,
    JSON.stringify({
      [MAP_SLUG]: {
        version: 11,
        migratedFromOld: true,
        // `useMapUserSettings.ts` resets ALL settings (and reloads) if `widgets` comes back
        // empty ("someone cleared settings at runtime" safety net) - a non-empty placeholder
        // here avoids that firing and wiping the seeded `groups` value straight back out.
        widgets: { visible: [], windows: {} },
        groups: { collapsedGroups, groupPositions: {} },
      },
    }),
  );
}

afterEach(() => {
  localStorage.clear();
});

describe('Map region collapse (WANDERER_MAP_GROUPS)', () => {
  test('flag off: every system renders as itself, no group tiles, regardless of stored collapse state', async () => {
    const systems = buildMultiRegionSystems(N, REGION_COUNT);
    const connections = buildConnections(systems);
    seedCollapsedGroups(Array.from({ length: REGION_COUNT }, (_, i) => `region:${11000000 + i}`));

    nodeRenderCounts.clear();
    const handle = await mountHarness(N, { systems, connections, groupsEnabled: false, mapSlug: MAP_SLUG });

    const { distinct } = snapshotComponentCounts(nodeRenderCounts);
    expect(distinct).toBe(N); // flag off: deriveCollapsedView is never even consulted

    unmount(handle);
  });

  test('N=300 across 10 regions: collapsing every region drops rendered node count to the group count', async () => {
    const systems = buildMultiRegionSystems(N, REGION_COUNT);
    const connections = buildConnections(systems);
    seedCollapsedGroups(Array.from({ length: REGION_COUNT }, (_, i) => `region:${11000000 + i}`));

    const handle = await mountHarness(N, { systems, connections, groupsEnabled: true, mapSlug: MAP_SLUG });
    await flushRAF(20);

    // Inspects the FINAL DOM state directly (ReactFlow assigns `react-flow__node-<type>` to each
    // node wrapper) rather than `nodeRenderCounts`'s cumulative distinct-id tracking - a member
    // system renders ONCE as itself before settings finish loading and collapse applies, so it's
    // already in that Set and would stay there even after being hidden; this is "how many nodes
    // does ReactFlow actually have mounted right now", which is what the acceptance criterion
    // means by "rendered node count".
    const realSystemNodes = handle.container.querySelectorAll('.react-flow__node-custom');
    const groupNodes = handle.container.querySelectorAll('.react-flow__node-group');

    expect(realSystemNodes.length).toBe(0); // every one of the 300 systems is a collapsed member
    expect(groupNodes.length).toBe(REGION_COUNT); // replaced by exactly 10 group tiles

    unmount(handle);
  });

  test('expand-all (collapsedGroups: []) renders exactly N real systems - same as never having collapsed', async () => {
    const systems = buildMultiRegionSystems(N, REGION_COUNT);
    const connections = buildConnections(systems);
    seedCollapsedGroups([]); // the "expand all" end state

    nodeRenderCounts.clear();
    const handle = await mountHarness(N, { systems, connections, groupsEnabled: true, mapSlug: MAP_SLUG });

    const { distinct } = snapshotComponentCounts(nodeRenderCounts);
    expect(distinct).toBe(N);

    unmount(handle);
  });

  test('a collapsed group whose key is not in the current migration-up-to-date default stored blob is simply not collapsed (migration-from-old-blob safety)', async () => {
    const systems = buildMultiRegionSystems(N, REGION_COUNT);
    const connections = buildConnections(systems);
    // A blob written before this feature existed: no `groups` key at all, old version number -
    // forces the full migration chain (to_1..to_11) to run, including `to_11`'s default.
    localStorage.setItem(
      LS_KEY,
      JSON.stringify({
        [MAP_SLUG]: {
          version: 6,
          migratedFromOld: true,
          interface: {},
        },
      }),
    );

    nodeRenderCounts.clear();
    const handle = await mountHarness(N, { systems, connections, groupsEnabled: true, mapSlug: MAP_SLUG });

    // to_11's default (`collapsedGroups: []`) applied - nothing collapsed, every system renders.
    const { distinct } = snapshotComponentCounts(nodeRenderCounts);
    expect(distinct).toBe(N);

    unmount(handle);
  });
});
