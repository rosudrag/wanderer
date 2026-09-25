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
import { packBoxes } from './pack';
import { loadRegionLayouts } from './regionData';
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
    return { positions: {}, rootId: null, movedCount: 0 };
  }

  const axis: BeautifyAxis = options.axis ?? 'left_to_right';
  const kspaceMode: KSpaceMode = options.kspaceMode ?? 'geographic';
  const hubs = options.hubs ?? [];
  const explicitRootId = options.rootId ?? null;

  const nodeById = new Map(nodes.map(n => [n.id, n]));
  const nodeIds = new Set(nodeById.keys());
  const cleanEdges = sanitizeEdges(edges, nodeIds);
  const gateEdges = cleanEdges.filter(e => e.type === 1);
  const chainEdges = cleanEdges.filter(e => e.type === 0 || e.type === 2);

  // --- 1. Partition -------------------------------------------------------

  const gateComponents = connectedComponents([...nodeIds], gateEdges);
  const kspaceClusters = gateComponents.filter(c => c.length >= 2);
  const kspaceMemberIds = new Set<string>(kspaceClusters.flat());

  // --- 2. K-space geographic set + topological fallback -------------------

  const boxes: LayoutBox[] = [];
  /** k-space node id -> its proposed (pre-pack) global cell, used to seed wormhole-chain attachment anchors. */
  const kspaceProposedCell = new Map<string, CellCoord>();

  const regionData = kspaceMode === 'geographic' && kspaceClusters.length > 0 ? await loadRegionLayouts() : null;

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

    const rootId =
      explicitRootId && compIdSet.has(explicitRootId)
        ? explicitRootId
        : (pickChainRoot(compNodes, compEdges, hubs) ?? component[0]);

    if (component.length > reportedRootSize || (explicitRootId && rootId === explicitRootId)) {
      reportedRootId = rootId;
      reportedRootSize = explicitRootId && rootId === explicitRootId ? Infinity : component.length;
    }

    const { localCells, depths } = layoutChainTree(effectiveNodes, compEdges, axis, rootId);

    // Anchor = nearest pinned (locked, or an already-positioned k-space
    // attachment) node to the root; falls back to the root itself.
    const pinnedCandidates = component.filter(id => nodeById.get(id)!.locked || kspaceMemberIds.has(id));
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

    boxes.push({ id: `chain:${rootId}`, cells, fixed: pinnedCandidates.length > 0 });
  }

  // --- 4. Pack everything onto one grid ------------------------------------

  const globalCells = packBoxes(boxes);

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

  return { positions, rootId: reportedRootId, movedCount };
};
