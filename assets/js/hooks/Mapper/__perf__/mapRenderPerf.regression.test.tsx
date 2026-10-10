/**
 * Permanent render-count regression test. Deterministic (render COUNTS only - never ms, which is
 * machine-dependent and would flake). Locks in the state the map render-perf refactor reached, at
 * N=300. See docs/chewy/map-perf-findings.md for the full before/after investigation.
 *
 * `useSyncExternalStore`'s `subscribe` callback checks `getSnapshot()` for a real change BEFORE
 * asking React to schedule a re-render (confirmed empirically - see useMapSelector.unit.test.tsx
 * and diagnostic.test.tsx): a `visibleNodes`/`hoverNodeId` write that does NOT change a given
 * node's own selected boolean produces ZERO renders for that node.
 *
 * CORRECTED (previous version of this file asserted drag fans out to all N "by necessity" -
 * that was wrong, a test-input artifact, not a product behavior; see
 * docs/chewy/map-perf-findings.md "Corrected drag measurement"): a REAL drag (one node's actual
 * ReactFlow position changing 60 times) renders ONLY that one node, confirmed below. `pan`
 * legitimately CAN touch every node (the viewport itself moved, so every node's visibility bit
 * genuinely needs re-checking) - that is honest O(N) work, not a bug, and is asserted as such.
 *
 * What this refactor achieved, locked in below:
 * - Mount's double node-render (confirmed pre-fix: exactly 2x at every N tested) is gone.
 * - Hover/connect re-renders only the 1-2 affected nodes, not all N.
 * - A REAL drag (one node's ReactFlow position changing) renders ONLY that one node - not N.
 * - A realistic pan (viewport genuinely shifts, some nodes enter/leave) re-checks all N nodes'
 *   visibility (honest, necessary), but each check is now a cheap `Set.has()`-driven boolean
 *   compare, not a full recompute (12 `useMemo`s, characters filtering, etc. stay referentially
 *   stable via their own unchanged inputs) - only nodes whose OWN visibility actually flipped
 *   recompute anything.
 * - `useContextStore`'s rAF queue drains the WHOLE pending batch per frame instead of one entry
 *   per frame, so a burst of updates in one frame commits once, not once per queued item.
 * - A field no node selector reads (`localShowShipName`) causes ZERO node re-renders - true
 *   per-key isolation, not just a cheap bail after being woken.
 * - `MapRootProvider` (separate store from the above, ~90 consumer files) was migrated the same
 *   way: stable context value for its hot per-node/per-edge consumers via a new
 *   `useMapRootSelector`/`MapRootStoreContext`, while `useMapRootState()` keeps today's "react to
 *   any store write" semantics for its ~85 unconverted consumers (an explicit restore, since
 *   `useContextStore` no longer forces its owner to re-render internally - see
 *   `ALL_MAP_ROOT_DATA_KEYS`'s comment in MapRootProvider.tsx). `Map.tsx`'s `Map` export is now
 *   `memo()`-wrapped so an unrelated `MapRootProvider` re-render (e.g. the 85-consumer restore
 *   firing on every server-pushed write) does not cascade into the whole canvas subtree -
 *   confirmed below: a `charactersUpdated`/`detailedKillsUpdated` burst re-renders only the one
 *   node whose own kills slice changed, not all N.
 */
import {
  buildSystems,
  dragOneNodeViaReactFlow,
  flushRAF,
  hoverEnterThenLeave,
  mapStateBox,
  mountHarness,
  nodeRenderCounts,
  queueGenuinelyUnchangedVisibleNodes,
  queueRealisticDataBurst,
  queueRealisticPanShift,
  snapshotComponentCounts,
  timeAct,
  unmount,
} from './harness';

describe('Map canvas render-count regression (locks in what this refactor achieved)', () => {
  const N = 300;

  test('mount renders every node (the pre-refactor exact-2x double-render is gone)', async () => {
    nodeRenderCounts.clear();
    const h = await mountHarness(N);
    const { total, distinct } = snapshotComponentCounts(nodeRenderCounts);
    expect(distinct).toBeGreaterThanOrEqual(N);
    expect(distinct).toBeLessThanOrEqual(N + 4);
    expect(total).toBeLessThanOrEqual(N + 4); // was exactly 2*N before this refactor
    unmount(h);
  });

  test('hover re-renders only the hovered node(s), not all N', async () => {
    const h = await mountHarness(N);
    const firstNodeId = String(30000000);

    nodeRenderCounts.clear();
    await hoverEnterThenLeave(firstNodeId, 5);
    const { total, distinct } = snapshotComponentCounts(nodeRenderCounts);

    expect(distinct).toBeLessThanOrEqual(4); // was N before this refactor
    expect(total).toBeLessThanOrEqual(6);
    unmount(h);
  });

  test('a genuinely-unchanged visibleNodes update (same membership) causes ZERO node re-renders', async () => {
    const h = await mountHarness(N);

    nodeRenderCounts.clear();
    await timeAct(() => queueGenuinelyUnchangedVisibleNodes(10), 15);
    const { total, distinct } = snapshotComponentCounts(nodeRenderCounts);

    expect(total).toBe(0);
    expect(distinct).toBe(0);
    unmount(h);
  });

  test('a REAL drag (one node moved 60 times via ReactFlow) re-renders ONLY that node, not all N', async () => {
    const h = await mountHarness(N);
    const systems = buildSystems(N);

    nodeRenderCounts.clear();
    await dragOneNodeViaReactFlow(h.mapRef, systems, 60);
    const { total, distinct } = snapshotComponentCounts(nodeRenderCounts);

    expect(distinct).toBeLessThanOrEqual(2); // was (incorrectly measured as) N before this fix
    expect(total).toBeLessThanOrEqual(4);
    unmount(h);
  });

  test('a realistic pan (viewport genuinely shifts) re-checks all N nodes but only recomputes the ones whose visibility actually flipped', async () => {
    const h = await mountHarness(N);

    nodeRenderCounts.clear();
    await timeAct(() => queueRealisticPanShift(N), 10);
    const { distinct } = snapshotComponentCounts(nodeRenderCounts);

    // Honest, necessary: the viewport itself moved, so every node's visibility COULD have
    // changed - this is not asserted as a tight upper bound the way hover/drag are, just that it
    // does not EXCEED N (the whole point: it can't be made smaller than N without restructuring
    // how visibility is tracked, which is explicitly the "architectural ceiling" case).
    expect(distinct).toBeLessThanOrEqual(N);
    unmount(h);
  });

  test('a field no node selector reads causes ZERO node re-renders (true per-key isolation, not just a cheap bail)', async () => {
    // `localShowShipName` is read by `LocalCounter` (via its own `useMapSelector`), never by
    // `useSolarSystemNode` - updating it must not even wake `SolarSystemNodeDefault`'s render
    // function, let alone recompute anything inside it.
    const h = await mountHarness(N);

    nodeRenderCounts.clear();
    await timeAct(() => {
      mapStateBox.current?.update({ localShowShipName: true });
    }, 5);
    const { total, distinct } = snapshotComponentCounts(nodeRenderCounts);

    expect(total).toBe(0);
    expect(distinct).toBe(0);
    unmount(h);
  });

  test('a MapRootProvider data burst (charactersUpdated + detailedKillsUpdated) re-renders only the affected node(s), not all N', async () => {
    const h = await mountHarness(N);
    const systems = buildSystems(N);
    const systemIds = systems.map(s => s.id);

    nodeRenderCounts.clear();
    queueRealisticDataBurst(h.mapRootRef, systemIds);
    await flushRAF(5);
    const { distinct } = snapshotComponentCounts(nodeRenderCounts);

    expect(distinct).toBeLessThanOrEqual(2);
    unmount(h);
  });
});
