// K-space layout: one gate-connected cluster (>=2 systems linked by
// stargates) is split into per-region groups — "systems of the same region
// form one cluster" — because the precomputed layout data is region-local.
// Each region group is laid out either:
//   - geographically: region-local [col,row] straight out of
//     regionLayouts.json, with the empty rows/columns the map doesn't use
//     compressed away, or
//   - topologically: the same BFS + tidy-tree code chains use, but walking
//     gate edges instead of wormhole/bridge edges, for any group where the
//     data is missing or the caller asked for kspaceMode: 'topological'.
//
// Locked nodes act as anchors exactly as in chain layout: if a group has a
// locked member, the whole group is translated so that member keeps its
// exact current position and the resulting box is marked `fixed` (pack.ts
// must not move it). Otherwise the box is a soft `target` seeded from the
// region's centroid (geographic) or the group's current average position
// (topological, region unknown) — pack.ts may nudge it to avoid collisions.

import { layoutChainTree, pickChainRoot } from './chainLayout';
import { getRegionEntry, getSystemCell } from './regionData';
import type { RegionLayoutData, RegionLayoutEntry } from './regionData';
import { CELL_H, CELL_W } from './types';
import type { BeautifyAxis, CellCoord, KSpaceMode, LayoutBox, LayoutEdgeInput, LayoutNodeInput } from './types';

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
    cursor += Math.min(gap, 3); // at most 2 empty cells between two used ones
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

const layoutGeographicGroup = (
  groupId: string,
  members: LayoutNodeInput[],
  entry: RegionLayoutEntry,
): KSpaceGroupResult | null => {
  const raw = new Map<string, [number, number]>();
  for (const node of members) {
    const cell = getSystemCell(entry, node.id);
    if (!cell) return null; // caller falls back to topological for this group
    raw.set(node.id, cell);
  }

  const colMap = compressAxis([...raw.values()].map(([col]) => col));
  const rowMap = compressAxis([...raw.values()].map(([, row]) => row));

  const localCells = new Map<string, CellCoord>();
  for (const [id, [col, row]] of raw) {
    localCells.set(id, { col: colMap.get(col)!, row: rowMap.get(row)! });
  }

  const softTarget: CellCoord = { col: Math.round(entry.centroid[0]), row: Math.round(entry.centroid[1]) };
  return finalizeGroup(groupId, members, localCells, softTarget);
};

const layoutTopologicalGroup = (
  groupId: string,
  members: LayoutNodeInput[],
  gateEdges: LayoutEdgeInput[],
  axis: BeautifyAxis,
  hubs: string[] | undefined,
  regionCentroid: [number, number] | null,
): KSpaceGroupResult => {
  const rootId = pickChainRoot(members, gateEdges, hubs) ?? [...members].map(n => n.id).sort()[0];
  const { localCells } = layoutChainTree(members, gateEdges, axis, rootId);

  // Any member the BFS couldn't reach (disconnected within this region
  // group, e.g. gate edges to it weren't included on the map) keeps a
  // deterministic fallback slot appended to the row so it's still placed.
  let fallbackRow = 0;
  for (const node of members) {
    if (!localCells.has(node.id)) {
      localCells.set(node.id, { col: 0, row: fallbackRow });
      fallbackRow += 1;
    }
  }

  const softTarget: CellCoord = regionCentroid
    ? { col: Math.round(regionCentroid[0]), row: Math.round(regionCentroid[1]) }
    : averagePosition(members);

  return finalizeGroup(groupId, members, localCells, softTarget);
};

const averagePosition = (members: LayoutNodeInput[]): CellCoord => {
  const sum = members.reduce((acc, n) => ({ col: acc.col + n.x / CELL_W, row: acc.row + n.y / CELL_H }), {
    col: 0,
    row: 0,
  });
  return { col: Math.round(sum.col / members.length), row: Math.round(sum.row / members.length) };
};

/**
 * Lays out one region-group (all cluster members sharing the same
 * regionId). `gateEdges` should already be filtered to edges between
 * members of this group.
 */
export const layoutKSpaceGroup = (
  groupId: string,
  members: LayoutNodeInput[],
  gateEdges: LayoutEdgeInput[],
  regionId: number | undefined,
  regionData: RegionLayoutData | null,
  mode: KSpaceMode,
  axis: BeautifyAxis,
  hubs: string[] | undefined,
): KSpaceGroupResult => {
  const entry = getRegionEntry(regionData, regionId);

  if (mode === 'geographic' && entry) {
    const geo = layoutGeographicGroup(groupId, members, entry);
    if (geo) return geo;
  }

  return layoutTopologicalGroup(groupId, members, gateEdges, axis, hubs, entry ? entry.centroid : null);
};
