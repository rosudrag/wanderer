/**
 * Map render-path perf measurement: mount / drag / hover / pan at N = 50/150/300/600. Logs
 * wall-clock + render counts to the console for manual comparison; see docs/chewy/map-perf-
 * findings.md for the methodology and recorded numbers. For a deterministic CI-safe assertion on
 * the same render-count metric, see mapRenderPerf.regression.test.tsx.
 *
 * `drag` drives a REAL ReactFlow position change (not a synthetic `update({visibleNodes: <every
 * node>})` call - see harness.tsx's `dragOneNodeViaReactFlow` for why that was corrected).
 * `pan` uses a realistic viewport-shift visible-set computation (some nodes enter, some leave,
 * most unaffected), not "everyone becomes visible".
 */
import {
  HarnessHandle,
  RenderCounts,
  buildSystems,
  dragOneNodeViaReactFlow,
  edgeRenderCounts,
  flushRAF,
  hoverEnterThenLeave,
  mountHarness,
  nodeRenderCounts,
  queueRealisticDataBurst,
  queueRealisticPanShift,
  snapshotComponentCounts,
  timeAct,
  unmount,
} from './harness';

const SCENARIOS = [50, 150, 300, 600];

describe('Map canvas render perf (real ReactFlow mount)', () => {
  for (const n of SCENARIOS) {
    test(
      `N=${n}`,
      async () => {
        const firstNodeId = String(30000000);

        // Each scenario mounts FRESH: an earlier scenario's pending rAF-queue drain can otherwise
        // bleed into the next scenario's measurement window.
        nodeRenderCounts.clear();
        edgeRenderCounts.clear();
        const mountStart = performance.now();
        const mountHandle: HarnessHandle = await mountHarness(n);
        const mountMs = performance.now() - mountStart;
        const mountCounts: RenderCounts = JSON.parse(JSON.stringify(mountHandle.counts));
        const mountNodeEdge = { node: snapshotComponentCounts(nodeRenderCounts), edge: snapshotComponentCounts(edgeRenderCounts) };
        unmount(mountHandle);

        nodeRenderCounts.clear();
        edgeRenderCounts.clear();
        const dragHandle = await mountHarness(n);
        Object.keys(dragHandle.counts).forEach(k => delete dragHandle.counts[k]);
        const systems = buildSystems(n);
        const dragStart = performance.now();
        await dragOneNodeViaReactFlow(dragHandle.mapRef, systems, 60);
        const dragMs = performance.now() - dragStart;
        const dragCounts: RenderCounts = JSON.parse(JSON.stringify(dragHandle.counts));
        const dragNodeEdge = { node: snapshotComponentCounts(nodeRenderCounts), edge: snapshotComponentCounts(edgeRenderCounts) };
        unmount(dragHandle);

        nodeRenderCounts.clear();
        edgeRenderCounts.clear();
        const hoverHandle = await mountHarness(n);
        Object.keys(hoverHandle.counts).forEach(k => delete hoverHandle.counts[k]);
        const hoverMs = await hoverEnterThenLeave(firstNodeId, 5);
        const hoverCounts: RenderCounts = JSON.parse(JSON.stringify(hoverHandle.counts));
        const hoverNodeEdge = { node: snapshotComponentCounts(nodeRenderCounts), edge: snapshotComponentCounts(edgeRenderCounts) };
        unmount(hoverHandle);

        nodeRenderCounts.clear();
        edgeRenderCounts.clear();
        const panHandle = await mountHarness(n);
        Object.keys(panHandle.counts).forEach(k => delete panHandle.counts[k]);
        const panMs = await timeAct(() => queueRealisticPanShift(n), 5);
        const panCounts: RenderCounts = JSON.parse(JSON.stringify(panHandle.counts));
        const panNodeEdge = { node: snapshotComponentCounts(nodeRenderCounts), edge: snapshotComponentCounts(edgeRenderCounts) };
        unmount(panHandle);

        const edgeCount = n - 1;
        // eslint-disable-next-line no-console
        console.log(
          `\n=== N=${n} systems, ${edgeCount} edges ===\n` +
            `mount:  ${mountMs.toFixed(2)}ms | root=${mountCounts['root']?.count ?? 0} map=${mountCounts['map']?.count ?? 0} | node renders: ${mountNodeEdge.node.total} total / ${mountNodeEdge.node.distinct} distinct (of ${n}) | edge renders: ${mountNodeEdge.edge.total} total / ${mountNodeEdge.edge.distinct} distinct (of ${edgeCount})\n` +
            `drag(60 real ReactFlow position changes of 1 node): ${dragMs.toFixed(2)}ms | root=${dragCounts['root']?.count ?? 0} map=${dragCounts['map']?.count ?? 0} | node renders: ${dragNodeEdge.node.total} total / ${dragNodeEdge.node.distinct} distinct (of ${n}) | edge renders: ${dragNodeEdge.edge.total} total / ${dragNodeEdge.edge.distinct} distinct (of ${edgeCount})\n` +
            `hover:  ${hoverMs.toFixed(2)}ms | root=${hoverCounts['root']?.count ?? 0} map=${hoverCounts['map']?.count ?? 0} | node renders: ${hoverNodeEdge.node.total} total / ${hoverNodeEdge.node.distinct} distinct (of ${n}) | edge renders: ${hoverNodeEdge.edge.total} total / ${hoverNodeEdge.edge.distinct} distinct (of ${edgeCount})\n` +
            `pan (realistic viewport shift): ${panMs.toFixed(2)}ms | root=${panCounts['root']?.count ?? 0} map=${panCounts['map']?.count ?? 0} | node renders: ${panNodeEdge.node.total} total / ${panNodeEdge.node.distinct} distinct (of ${n}) | edge renders: ${panNodeEdge.edge.total} total / ${panNodeEdge.edge.distinct} distinct (of ${edgeCount})\n`,
        );

        expect(mountMs).toBeGreaterThan(0);
      },
      20000,
    );
  }

  // Measures the scenario that motivated converting `useSolarSystemNode.ts`/`SolarSystemEdge.tsx`
  // /`useNodeKillsCount.ts`/`useMapGetOption.ts` to `useMapRootSelector`: a server-pushed
  // `charactersUpdated`/`detailedKillsUpdated` burst landing while the map is busy, entirely
  // independent of anything the local user's mouse is doing - see docs/chewy/map-perf-findings.md
  // "useMapRootState() fix". Driven through the REAL `MapRootProvider` command dispatcher
  // (`mapRootRef`), not a hand-rolled `update()` call.
  test('N=300 MapRootProvider data burst (charactersUpdated + detailedKillsUpdated)', async () => {
    const n = 300;
    nodeRenderCounts.clear();
    edgeRenderCounts.clear();
    const handle = await mountHarness(n);
    Object.keys(handle.counts).forEach(k => delete handle.counts[k]);
    const systems = buildSystems(n);
    const systemIds = systems.map(s => s.id);
    // Isolates the burst's OWN effect: mount itself renders every node once (~N, see the "mount"
    // scenario above) - clearing again here means `burstNodeEdge` below counts ONLY renders
    // caused by the burst, not mount's.
    nodeRenderCounts.clear();
    edgeRenderCounts.clear();
    const burstStart = performance.now();
    queueRealisticDataBurst(handle.mapRootRef, systemIds);
    // `update()` is rAF-queued (see useContextStore.ts), not applied synchronously - a bare
    // `await Promise.resolve()` is one microtask, not one animation frame, and would read counts
    // before the queued writes are even applied.
    await flushRAF(5);
    const burstMs = performance.now() - burstStart;
    const burstCounts: RenderCounts = JSON.parse(JSON.stringify(handle.counts));
    const burstNodeEdge = { node: snapshotComponentCounts(nodeRenderCounts), edge: snapshotComponentCounts(edgeRenderCounts) };
    unmount(handle);

    // eslint-disable-next-line no-console
    console.log(
      `\n=== N=${n} MapRootProvider data burst ===\n` +
        `burst: ${burstMs.toFixed(2)}ms | root=${burstCounts['root']?.count ?? 0} map=${burstCounts['map']?.count ?? 0} | ` +
        `node renders: ${burstNodeEdge.node.total} total / ${burstNodeEdge.node.distinct} distinct (of ${n}) | ` +
        `edge renders: ${burstNodeEdge.edge.total} total / ${burstNodeEdge.edge.distinct} distinct (of ${n - 1})\n`,
    );

    // Only the nodes whose OWN slice changed (the burst wrote 5 characters across up to 5
    // distinct systems, plus 1 system's kills) should re-render - not all 300. This is the
    // concrete, measured answer to "does useMapRootSelector actually isolate a data burst", not
    // hand-waving.
    expect(burstNodeEdge.node.distinct).toBeLessThanOrEqual(10);
  }, 20000);
});
