// K-space layout. All k-space cluster members (>=2 systems gate-linked)
// that resolve to a GLOBAL cell on the shared New Eden lattice
// (regionLayouts.json) are laid out as ONE geographic box: every occupied
// column/row across the WHOLE set is compressed together (see
// compressAxis), so relative order and direction are preserved across
// region and cluster boundaries — a system's position next to its gate
// neighbour in another region is now meaningful, and a region whose
// systems only vary slightly in one axis no longer collapses on its own.
//
// Any cluster member that has no lattice entry (wormhole space, abyssal,
// or a data gap) falls back to the same BFS + tidy-tree code chains use,
// walking gate edges instead of wormhole/bridge edges, scoped to just that
// cluster's missing members — exactly as the old per-region fallback did.
//
// Locked nodes act as anchors exactly as in chain layout: if a group has a
// locked member, the whole group is translated so that member keeps its
// exact current position and the resulting box is marked `fixed` (pack.ts
// must not move it). Otherwise the box is a soft `target` seeded from
// (0,0) for the geographic set (already at its own compressed origin) or
// the group's current average position for a topological fallback group —
// pack.ts may nudge it to avoid collisions.

import { layoutChainTree, pickChainRoot } from './chainLayout';
import { getGlobalSystemCell } from './regionData';
import type { RegionLayoutData } from './regionData';
import { CELL_H, CELL_W } from './types';
import type { BeautifyAxis, CellCoord, LayoutBox, LayoutEdgeInput, LayoutNodeInput } from './types';

export interface KSpaceGroupResult {
  box: LayoutBox;
  /** node id -> proposed global cell (same values as in box.cells); exposed separately so index.ts can seed wormhole-chain attachment points even for locked members that box.cells still carries for anchoring purposes. */
  proposedCells: Map<string, CellCoord>;
}

/** Collapse runs of more than 2 unused rows/columns down to exactly 2, preserving order and relative spacing otherwise. */
const compressAxis = (usedValues: number[]): Map<number, number> => {
  const sorted = [...new Set(usedValues)].sort((a, b) => a - b);
  const mapping = new Map<number, number>();
  let cursor = 0;
  sorted.forEach((value, i) => {
    if (i === 0) {
      mapping.set(value, 0);
      cursor = 0;
      return;
    }
    const gap = value - sorted[i - 1];
    // Pure rank packing: consecutive occupied ranks land in adjacent cells, so a grid step is
    // one node box plus its margin (180x75 for a 130x34 box) — the density Dotlan draws at.
    // Leaving empty cells in the gaps only stretches the map and lengthens every line; the gap
    // is ordinal anyway, it says "not neighbours", never how far apart. Measured on a real
    // 15-system map: one empty cell gave 2590x1654 px, none gives 1870x979.
    cursor += Math.min(gap, 1);
    mapping.set(value, cursor);
  });
  return mapping;
};

const roundToCell = (node: LayoutNodeInput): CellCoord => ({
  col: Math.round(node.x / CELL_W),
  row: Math.round(node.y / CELL_H),
});

/** Builds the fixed/target box + proposed cell map from a set of already-computed *local* cells, exactly mirroring the anchor-translation rule used for chain trees. */
const finalizeGroup = (
  groupId: string,
  members: LayoutNodeInput[],
  localCells: Map<string, CellCoord>,
  softTarget: CellCoord,
): KSpaceGroupResult => {
  const locked = members.filter(n => n.locked).sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const anchor = locked[0] ?? null;

  let dCol = 0;
  let dRow = 0;
  let fixed = false;
  if (anchor) {
    const anchorLocal = localCells.get(anchor.id);
    if (anchorLocal) {
      const anchorGlobal = roundToCell(anchor);
      dCol = anchorGlobal.col - anchorLocal.col;
      dRow = anchorGlobal.row - anchorLocal.row;
      fixed = true;
    }
  } else {
    // Soft placement: shift so the group's local origin lands on the target hint.
    dCol = softTarget.col;
    dRow = softTarget.row;
  }

  const proposedCells = new Map<string, CellCoord>();
  for (const [id, cell] of localCells) {
    proposedCells.set(id, { col: cell.col + dCol, row: cell.row + dRow });
  }

  return {
    box: { id: groupId, cells: proposedCells, fixed },
    proposedCells,
  };
};

export interface GeographicSetResult {
  /** null when none of `members` resolved to a lattice cell (e.g. regionLayouts.json failed to load). */
  result: KSpaceGroupResult | null;
  /** ids from `members` that have no lattice entry and must go through layoutTopologicalGroup instead. */
  missingIds: Set<string>;
}

/**
 * Lays out every k-space cluster member that resolves to a GLOBAL lattice
 * cell as ONE box, compressed once across the whole set (not per region,
 * not per cluster) — this is what keeps a system's position relative to a
 * gate neighbour in another region meaningful.
 */
export const layoutGeographicSet = (
  groupId: string,
  members: LayoutNodeInput[],
  regionData: RegionLayoutData | null,
): GeographicSetResult => {
  const raw = new Map<string, CellCoord>();
  const missingIds = new Set<string>();
  for (const node of members) {
    const cell = getGlobalSystemCell(regionData, node.id);
    if (cell) raw.set(node.id, cell);
    else missingIds.add(node.id);
  }

  if (raw.size === 0) return { result: null, missingIds };

  const colMap = compressAxis([...raw.values()].map(c => c.col));
  const rowMap = compressAxis([...raw.values()].map(c => c.row));

  const localCells = new Map<string, CellCoord>();
  for (const [id, cell] of raw) {
    localCells.set(id, { col: colMap.get(cell.col)!, row: rowMap.get(cell.row)! });
  }

  const placedMembers = members.filter(n => raw.has(n.id));
  const result = finalizeGroup(groupId, placedMembers, localCells, { col: 0, row: 0 });
  return { result, missingIds };
};

const averagePosition = (members: LayoutNodeInput[]): CellCoord => {
  const sum = members.reduce((acc, n) => ({ col: acc.col + n.x / CELL_W, row: acc.row + n.y / CELL_H }), {
    col: 0,
    row: 0,
  });
  return { col: Math.round(sum.col / members.length), row: Math.round(sum.row / members.length) };
};

/**
 * Lays out a group of cluster members lacking a lattice entry via the
 * same BFS + tidy-tree code chains use, walking gate edges. `gateEdges`
 * should already be filtered to edges between members of this group.
 */
export const layoutTopologicalGroup = (
  groupId: string,
  members: LayoutNodeInput[],
  gateEdges: LayoutEdgeInput[],
  axis: BeautifyAxis,
  hubs: string[] | undefined,
): KSpaceGroupResult => {
  const rootId = pickChainRoot(members, gateEdges, hubs) ?? [...members].map(n => n.id).sort()[0];
  const { localCells } = layoutChainTree(members, gateEdges, axis, rootId);

  // Any member the BFS couldn't reach (disconnected within this group,
  // e.g. gate edges to it weren't included on the map) keeps a
  // deterministic fallback slot appended to the row so it's still placed.
  let fallbackRow = 0;
  for (const node of members) {
    if (!localCells.has(node.id)) {
      localCells.set(node.id, { col: 0, row: fallbackRow });
      fallbackRow += 1;
    }
  }

  return finalizeGroup(groupId, members, localCells, averagePosition(members));
};
