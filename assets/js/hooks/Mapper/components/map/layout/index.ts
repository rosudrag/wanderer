// Map beautifier layout engine — public API.
//
// Pipeline:
//   1. Partition the graph: gate (type 1) edges define k-space clusters;
//      wormhole/bridge (type 0/2) edges define chain structure. A node
//      touched by no gate edge is chain-only.
//   2. Lay out every k-space cluster member that resolves to a GLOBAL
//      lattice cell as ONE geographic box shared across every cluster and
//      region (or every cluster topologically, per options/fallback); any
//      member lacking a lattice entry falls back to a per-cluster
//      topological group — see kspaceLayout.ts.
//   3. Build the wormhole-chain forest out of chain-only nodes plus any
//      k-space node that has a wormhole/bridge edge reaching into it (an
//      "attachment point"), and lay out each component as a tidy tree
//      rooted at pickChainRoot() — see chainLayout.ts. Attachment points
//      and locked nodes are pinned: they seed the tree's translation but
//      never receive a newly-emitted position themselves.
//   4. Hand every component (the geographic box, topological groups, chain
//      trees) to pack.ts as a LayoutBox; it places them on one shared grid
//      without overlap.
//   5. Emit only nodes whose integer-cell position actually changed,
//      excluding every locked node.

import { pickChainRoot, layoutChainTree } from './chainLayout';
import { layoutGeographicSet, layoutTopologicalGroup } from './kspaceLayout';
import { packBoxes, reduceCrossings } from './pack';
import { loadRegionLayouts } from './regionData';
// CHEWY PATCH: mode: 'auto' | 'incremental' | 'full' support (see the
// mode-resolution block in beautifyLayout below and anchor.ts's header).
import { classifyNodes, placeIncrementalNodes, INCREMENTAL_VALID_FRACTION_THRESHOLD } from './anchor';
import type { NodeClassification } from './anchor';
import { CELL_H, CELL_W } from './types';
import type {
  BeautifyAxis,
  BeautifyOptions,
  CellCoord,
  KSpaceMode,
  LayoutBox,
  LayoutEdgeInput,
  LayoutNodeInput,
  LayoutResult,
} from './types';

export { CELL_W, CELL_H, pickChainRoot };
export type { BeautifyAxis, BeautifyOptions, KSpaceMode, LayoutEdgeInput, LayoutNodeInput, LayoutResult };

// ---------------------------------------------------------------------------
// Graph sanitation & partitioning helpers
// ---------------------------------------------------------------------------

/** Drops self-edges, edges referencing unknown nodes, and duplicate (type, unordered endpoint pair) edges. */
const sanitizeEdges = (edges: LayoutEdgeInput[], nodeIds: ReadonlySet<string>): LayoutEdgeInput[] => {
  const seen = new Set<string>();
  const result: LayoutEdgeInput[] = [];
  for (const edge of edges) {
    if (edge.source === edge.target) continue;
    if (!nodeIds.has(edge.source) || !nodeIds.has(edge.target)) continue;
    const [a, b] = edge.source < edge.target ? [edge.source, edge.target] : [edge.target, edge.source];
    const key = `${edge.type}:${a}:${b}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(edge);
  }
  return result;
};

const connectedComponents = (ids: string[], edges: Array<{ source: string; target: string }>): string[][] => {
  const adjacency = new Map<string, string[]>();
  for (const id of ids) adjacency.set(id, []);
  for (const edge of edges) {
    adjacency.get(edge.source)?.push(edge.target);
    adjacency.get(edge.target)?.push(edge.source);
  }

  const visited = new Set<string>();
  const components: string[][] = [];
  for (const id of [...ids].sort()) {
    if (visited.has(id)) continue;
    const component: string[] = [];
    const queue = [id];
    visited.add(id);
    while (queue.length > 0) {
      const current = queue.shift()!;
      component.push(current);
      for (const neighbor of adjacency.get(current) ?? []) {
        if (!visited.has(neighbor)) {
          visited.add(neighbor);
          queue.push(neighbor);
        }
      }
    }
    components.push(component.sort());
  }
  return components;
};

const edgesWithin = (edges: LayoutEdgeInput[], idSet: ReadonlySet<string>): LayoutEdgeInput[] =>
  edges.filter(e => idSet.has(e.source) && idSet.has(e.target));

// ---------------------------------------------------------------------------
// beautifyLayout
// ---------------------------------------------------------------------------

export const beautifyLayout = async (
  nodes: LayoutNodeInput[],
  edges: LayoutEdgeInput[],
  options: BeautifyOptions = {},
): Promise<LayoutResult> => {
  if (nodes.length === 0) {
    return { positions: {}, rootId: null, movedCount: 0, mode: 'full' };
  }

  const axis: BeautifyAxis = options.axis ?? 'left_to_right';
  const kspaceMode: KSpaceMode = options.kspaceMode ?? 'geographic';
  const hubs = options.hubs ?? [];
  const explicitRootId = options.rootId ?? null;
  const requestedMode = options.mode ?? 'auto';

  const nodeById = new Map(nodes.map(n => [n.id, n]));
  const nodeIds = new Set(nodeById.keys());
  const cleanEdges = sanitizeEdges(edges, nodeIds);
  const gateEdges = cleanEdges.filter(e => e.type === 1);
  const chainEdges = cleanEdges.filter(e => e.type === 0 || e.type === 2);

  // --- 1. Partition -------------------------------------------------------

  const gateComponents = connectedComponents([...nodeIds], gateEdges);
  const kspaceClusters = gateComponents.filter(c => c.length >= 2);
  const kspaceMemberIds = new Set<string>(kspaceClusters.flat());

  // CHEWY PATCH: mode resolution. regionData is needed both by the full
  // pipeline's geographic k-space layout (kspaceMode === 'geographic') and
  // by classifyNodes/placeIncrementalNodes' lattice-order check whenever we
  // might not go straight to 'full' — load it once, up front, and reuse it
  // for whichever path actually runs.
  const regionData =
    kspaceClusters.length > 0 && (kspaceMode === 'geographic' || requestedMode !== 'full')
      ? await loadRegionLayouts()
      : null;

  let resolvedMode: 'incremental' | 'full';
  let classification: NodeClassification | null = null;
  if (requestedMode === 'full') {
    resolvedMode = 'full';
  } else {
    classification = classifyNodes(nodes, gateEdges, kspaceMemberIds, regionData);
    const eligibleCount = nodes.filter(n => !n.locked).length;
    const validFraction = eligibleCount > 0 ? classification.validCells.size / eligibleCount : 0;
    resolvedMode =
      requestedMode === 'incremental'
        ? 'incremental'
        : validFraction >= INCREMENTAL_VALID_FRACTION_THRESHOLD
          ? 'incremental'
          : 'full';
  }

  if (resolvedMode === 'incremental') {
    const incremental = placeIncrementalNodes(
      nodes,
      gateEdges,
      chainEdges,
      kspaceMemberIds,
      regionData,
      axis,
      classification!,
    );

    // Lightweight rootId pick — mirrors step 3's partition below, without
    // the tree-layout math full mode needs (nothing here is re-laid-out).
    const chainOnlyIds = new Set([...nodeIds].filter(id => !kspaceMemberIds.has(id)));
    const attachmentIds = new Set<string>();
    for (const edge of chainEdges) {
      const sourceIsK = kspaceMemberIds.has(edge.source);
      const targetIsK = kspaceMemberIds.has(edge.target);
      if (sourceIsK && chainOnlyIds.has(edge.target)) attachmentIds.add(edge.source);
      if (targetIsK && chainOnlyIds.has(edge.source)) attachmentIds.add(edge.target);
    }
    const chainGraphIds = new Set([...chainOnlyIds, ...attachmentIds]);
    const chainGraphEdges = edgesWithin(chainEdges, chainGraphIds);
    const chainComponents = connectedComponents([...chainGraphIds], chainGraphEdges);

    let reportedRootId: string | null = null;
    let reportedRootSize = -1;
    for (const component of chainComponents) {
      const compIdSet = new Set(component);
      const compNodes = component.map(id => nodeById.get(id)!);
      const compEdges = edgesWithin(chainGraphEdges, compIdSet);
      const rootId =
        explicitRootId && compIdSet.has(explicitRootId)
          ? explicitRootId
          : (pickChainRoot(compNodes, compEdges, hubs) ?? component[0]);
      if (component.length > reportedRootSize || (explicitRootId && rootId === explicitRootId)) {
        reportedRootId = rootId;
        reportedRootSize = explicitRootId && rootId === explicitRootId ? Infinity : component.length;
      }
    }

    return {
      positions: incremental.positions,
      rootId: reportedRootId,
      movedCount: incremental.movedCount,
      mode: 'incremental',
    };
  }

  // --- 2. K-space geographic set + topological fallback -------------------

  const boxes: LayoutBox[] = [];
  /** k-space node id -> its proposed (pre-pack) global cell, used to seed wormhole-chain attachment anchors. */
  const kspaceProposedCell = new Map<string, CellCoord>();

  if (kspaceMode === 'geographic') {
    // ONE box for every cluster member that resolves to a GLOBAL lattice
    // cell, regardless of which gate component or region it belongs to —
    // compressing this whole set together (inside layoutGeographicSet) is
    // what keeps relative position meaningful across region boundaries.
    const allMembers = kspaceClusters.flat().map(id => nodeById.get(id)!);
    const geo = layoutGeographicSet('kspace:geo', allMembers, regionData);
    if (geo.result) {
      boxes.push(geo.result.box);
      for (const [id, cell] of geo.result.proposedCells) kspaceProposedCell.set(id, cell);
    }

    // Members with no lattice entry (wormhole space, abyssal, data gaps)
    // fall back to a per-cluster topological group, scoped to just that
    // cluster's missing members, exactly as before.
    kspaceClusters.forEach((cluster, clusterIndex) => {
      const missingIds = cluster.filter(id => geo.missingIds.has(id));
      if (missingIds.length === 0) return;
      const members = missingIds.map(id => nodeById.get(id)!);
      const clusterGateEdges = edgesWithin(gateEdges, new Set(cluster));
      const groupGateEdges = edgesWithin(clusterGateEdges, new Set(missingIds));
      const result = layoutTopologicalGroup(`kspace:topo:${clusterIndex}`, members, groupGateEdges, axis, hubs);
      boxes.push(result.box);
      for (const [id, cell] of result.proposedCells) kspaceProposedCell.set(id, cell);
    });
  } else {
    kspaceClusters.forEach((cluster, clusterIndex) => {
      const members = cluster.map(id => nodeById.get(id)!);
      const clusterGateEdges = edgesWithin(gateEdges, new Set(cluster));
      const result = layoutTopologicalGroup(`kspace:${clusterIndex}`, members, clusterGateEdges, axis, hubs);
      boxes.push(result.box);
      for (const [id, cell] of result.proposedCells) kspaceProposedCell.set(id, cell);
    });
  }

  // CHEWY PATCH: k-space member id -> the box object that already contains
  // it, built once here (before step 3 pushes any chain boxes) so an
  // attached wormhole-chain can fold directly into its anchor's box below
  // instead of becoming a separate obstacle that box has to dodge — see
  // the comment where this map is used.
  const kspaceBoxByMemberId = new Map<string, LayoutBox>();
  for (const box of boxes) {
    for (const id of box.cells.keys()) kspaceBoxByMemberId.set(id, box);
  }

  // --- 3. Wormhole-chain forest --------------------------------------------

  const chainOnlyIds = new Set([...nodeIds].filter(id => !kspaceMemberIds.has(id)));
  const attachmentIds = new Set<string>();
  for (const edge of chainEdges) {
    const sourceIsK = kspaceMemberIds.has(edge.source);
    const targetIsK = kspaceMemberIds.has(edge.target);
    if (sourceIsK && chainOnlyIds.has(edge.target)) attachmentIds.add(edge.source);
    if (targetIsK && chainOnlyIds.has(edge.source)) attachmentIds.add(edge.target);
  }

  const chainGraphIds = new Set([...chainOnlyIds, ...attachmentIds]);
  const chainGraphEdges = edgesWithin(chainEdges, chainGraphIds);
  const chainComponents = connectedComponents([...chainGraphIds], chainGraphEdges);

  let reportedRootId: string | null = null;
  let reportedRootSize = -1;

  for (const component of chainComponents) {
    const compIdSet = new Set(component);
    const compNodes = component.map(id => nodeById.get(id)!);
    const compEdges = edgesWithin(chainGraphEdges, compIdSet);

    // K-space attachment points already have an authoritative position;
    // substitute it in so anchor/tie-break math sees the real location.
    const effectiveNodes: LayoutNodeInput[] = compNodes.map(n => {
      const proposed = kspaceMemberIds.has(n.id) ? kspaceProposedCell.get(n.id) : undefined;
      return proposed ? { ...n, x: proposed.col * CELL_W, y: proposed.row * CELL_H } : n;
    });
    const effectiveById = new Map(effectiveNodes.map(n => [n.id, n]));

    // Anchor = nearest pinned (locked, or an already-positioned k-space
    // attachment) node to the root; falls back to the root itself. Computed
    // before rootId below since a pin, when one exists, now determines the
    // root too (see the CHEWY PATCH comment there).
    const pinnedCandidates = component.filter(id => nodeById.get(id)!.locked || kspaceMemberIds.has(id));

    const rootId =
      explicitRootId && compIdSet.has(explicitRootId)
        ? explicitRootId
        : pinnedCandidates.length > 0
          ? // CHEWY PATCH: root at a pinned node instead of pickChainRoot's
            // centroid-style heuristic whenever one exists. Proven failure
            // mode (dev/layout-bench.mjs "mixed" scenario): pickChainRoot
            // returns a DIFFERENT root for the same chain whenever a new
            // leaf lands anywhere except its current tail, and a different
            // root re-derives the WHOLE tree's local layout from scratch —
            // verified directly to fully mirror a 10-node linear chain's
            // order (every node's relative position reversed) from a single
            // new leaf off its middle node. A pin's identity never changes
            // across growth (growth only adds leaves, never a new
            // attachment point to an already-existing component), so
            // sorting for the smallest id gives a canonical, always-stable
            // choice; rooting there makes the tree's shape a pure function
            // of the tree's own topology, immune to where a new leaf lands.
            [...pinnedCandidates].sort()[0]
          : (pickChainRoot(compNodes, compEdges, hubs) ?? component[0]);

    if (component.length > reportedRootSize || (explicitRootId && rootId === explicitRootId)) {
      reportedRootId = rootId;
      reportedRootSize = explicitRootId && rootId === explicitRootId ? Infinity : component.length;
    }

    const { localCells, depths } = layoutChainTree(effectiveNodes, compEdges, axis, rootId);

    let anchorId = rootId;
    if (pinnedCandidates.length > 0) {
      let bestDepth = Infinity;
      for (const id of pinnedCandidates) {
        const depth = depths.get(id) ?? Infinity;
        if (depth < bestDepth || (depth === bestDepth && id < anchorId)) {
          bestDepth = depth;
          anchorId = id;
        }
      }
    }

    const anchorLocal = localCells.get(anchorId);
    const anchorNode = effectiveById.get(anchorId);
    const dCol = anchorLocal && anchorNode ? Math.round(anchorNode.x / CELL_W) - anchorLocal.col : 0;
    const dRow = anchorLocal && anchorNode ? Math.round(anchorNode.y / CELL_H) - anchorLocal.row : 0;

    const cells = new Map<string, CellCoord>();
    for (const id of component) {
      if (kspaceMemberIds.has(id)) continue; // authoritative position lives in the geographic set or a topological k-space box
      const local = localCells.get(id);
      if (!local) continue; // unreachable in this edge set (shouldn't happen for a real component)
      cells.set(id, { col: local.col + dCol, row: local.row + dRow });
    }

    if (cells.size === 0) continue; // every member was a k-space attachment point; nothing new to place

    // CHEWY PATCH: if this chain is anchored to a k-space member, fold its
    // cells directly into that member's OWN box instead of pushing a
    // separate (fixed, unmovable) box. Proven failure mode: packBoxes'
    // collision search (pack.ts) treats every box as independent, so a
    // tiny fixed chain box sitting right next to its own anchor forced the
    // ENTIRE k-space box (all of its members) to dodge it — and WHICH
    // direction/how far depended on the k-space box's exact proposed rect,
    // which shifts slightly on almost every insertion even though relative
    // order among k-space members never does (verified: layoutGeographicSet's
    // own proposed cells are order-preserving in isolation). That produced
    // a large, direction-flipping whole-cluster relocation on most growth
    // steps, entirely unrelated to any real edge crossing. Folding into one
    // box means the attachment and its anchor now move together as a
    // single unit (or, the common case, don't move at all) instead of the
    // anchor's own box treating its dependent as a foreign obstacle.
    const anchorBox = kspaceMemberIds.has(anchorId) ? kspaceBoxByMemberId.get(anchorId) : undefined;
    if (anchorBox) {
      for (const [id, cell] of cells) anchorBox.cells.set(id, cell);
    } else {
      boxes.push({ id: `chain:${rootId}`, cells, fixed: pinnedCandidates.length > 0 });
    }
  }

  // --- 4. Pack everything onto one grid, then cheaply de-cross it ---------

  const packedCells = packBoxes(boxes);
  // CHEWY PATCH: final deterministic improvement pass (see pack.ts) —
  // relocates movable nodes into free adjacent cells, or swaps a pair that
  // are endpoints of the same crossing, evaluated canonically (not
  // first-come) each sweep and displacement-capped. Only nodes that aren't
  // locked are eligible, so locked nodes never move.
  const movableIds = new Set([...nodeIds].filter(id => !nodeById.get(id)!.locked));
  const globalCells = reduceCrossings(packedCells, cleanEdges, movableIds);

  // --- 5. Emit only genuinely-changed, unlocked nodes ----------------------

  const positions: Record<string, { x: number; y: number }> = {};
  let movedCount = 0;
  for (const [id, cell] of globalCells) {
    const original = nodeById.get(id);
    if (!original || original.locked) continue;
    const x = cell.col * CELL_W;
    const y = cell.row * CELL_H;
    if (x === original.x && y === original.y) continue;
    positions[id] = { x, y };
    movedCount += 1;
  }

  return { positions, rootId: reportedRootId, movedCount, mode: 'full' };
};
