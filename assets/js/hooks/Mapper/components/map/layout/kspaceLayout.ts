// K-space layout. All k-space cluster members (>=2 systems gate-linked)
// that resolve to a GLOBAL cell on the shared New Eden lattice
// (regionLayouts.json) are laid out as ONE geographic box: every member's
// column/row across the WHOLE set is placed by segmenting the OWN axis
// values (see quantizeAxis) into neighbourhoods — never by a member's
// rank among the other members currently on the map — so relative order
// and direction are preserved across region and cluster boundaries, AND
// a node already on the map only ever moves if a node is inserted into
// its own neighbourhood, never because of an insertion somewhere else.
//
// CHEWY PATCH: the previous approach (compressAxis) sorted every occupied
// column/row and mapped RANKS to consecutive local cells. That produces a
// tight, good-looking box, but a node's cell was a function of EVERY
// other node's position: inserting one system between two existing ones
// shifted every node after it by a full cell, cascading across the whole
// map on nearly every add (see dev/layout-bench.mjs stability numbers
// pre-patch). quantizeAxis instead splits each axis's distinct values
// into SEGMENTS wherever a neighbour-to-neighbour gap exceeds
// NEIGHBOURHOOD_GAP_CELLS (see its own comment below) — segments are
// Dotlan's stand-in for "same neighbourhood" vs. "unrelated area". Each
// segment's reserved range of local cells is sized to its OWN final
// capped-running-position (see LOCAL_PACK_CELLS / quantizeAxis). Offsets are
// anchored at the segment containing the axis's OWN median index (see
// pickAnchorSegment) rather than a plain left-to-right cumulative sum from
// segment 0 — so a brand-new segment landing before/after every existing one
// (a real, common case for a "nearest lattice neighbour" insertion) only
// shifts the segments on its OWN side of the anchor, never the anchor
// segment itself (almost always the bulk of the map). *Within* a segment, a
// member's local cell is a running sum of capped real gaps from the
// segment's own minimum, NOT its rank among the other members — real "same
// neighbourhood" spacing is already only a handful of units, so this stays
// exactly as compact as the old rank version for an unchanged member set,
// but an insertion that lands in an already-dense spot (gap <=
// LOCAL_PACK_CELLS, the common case for a genuine nearest-neighbour
// addition) moves NOBODY — the blast radius is bounded to "members after a
// genuinely loose gap that just got split, on the insertion's own side of
// the segment's anchor", never "everyone after it in sort order" or
// "everyone else on the map".
//
// CHEWY PATCH: the segment threshold used to be derived from statistics of
// the CURRENT member set (median neighbour-gap on this axis, ladder-
// snapped) — that made segmentation itself a function of who else is on
// the map, so adding one system anywhere on an axis could shift the
// median enough to move every segment boundary and renumber the whole
// box: exactly the whole-map cascade this rewrite exists to remove, just
// moved one level up (this is what regressed yugen — the smallest, most
// gap-volatile real scenario — to a movedFraction of ~0.92 at k=1).
// NEIGHBOURHOOD_GAP_CELLS below is now a constant baked in from
// data/regionLayouts.json at write time, never recomputed from the live
// member set — a member only ever moves into or out of a segment because
// of where it genuinely sits on the shared galaxy lattice, never because
// of who else got added to the map.
//
// Segments are lossy at their edges (a segment can, rarely, gain more
// members than its reserved width), so two different members can
// legitimately land on the same local cell. resolveCollisions fixes that
// up deterministically and LOCALLY: colliding members are pushed one cell
// rightward, within their own row, until they find a free cell — provably
// safe for stability (a member's row is never touched by this, so it can
// never flip a pair's above/below order; a pushed member's column only
// ever increases, so it can never flip a pair's left/right order either).
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

// CHEWY PATCH: coarse, fixed ladder of gap thresholds (roughly power-of-two/three growth),
// used both to snap segment reserved widths below and as the source of the fixed
// neighbourhood-gap threshold itself.
const GAP_LADDER = [
  1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096,
];
const ladderSnap = (value: number): number => {
  for (const rung of GAP_LADDER) {
    if (rung >= value) return rung;
  }
  return GAP_LADDER[GAP_LADDER.length - 1];
};

// CHEWY PATCH: fixed, data-derived neighbourhood-gap threshold. Replaces the old
// `median(consecutive gaps on THIS axis, for THIS call's member set) * 3` adaptive
// threshold, which made segmentation a function of the whole member set (see the
// file header for why that regressed stability). This is now a constant, computed
// once from data/regionLayouts.json (the shipped global lattice, 5485 systems) and
// baked in — it is never recomputed at call time.
//
// Derivation: regionLayouts.json carries no explicit gate-connection graph, so the
// Euclidean distance from every system to its nearest OTHER system on the lattice is
// used as the proxy for "one gate hop, same neighbourhood" — Dotlan (the data's
// source) draws directly-connected systems close together, and this is literally how
// dev/layout-bench.mjs's own kspace-wide scenario builds gate edges (buildMST treats
// nearest-lattice-neighbour as a gate). Percentiles over all 5485 nearest-neighbour
// distances: p50=2.24, p90=5.10, p95=6.08, p99=8.00, max=12.37 (the single sparsest
// pair in the whole galaxy).
//
// Cross-checked directly against the two real scenarios this threshold has to serve:
// kspace-wide's three real 13-14-system clusters (around Jita/The Forge, Amarr/Domain,
// Rens/Heimatar) never have an internal same-axis gap above 4; yugen's real 15-system
// map has one dense 10-system core whose worst internal gap is 6 — while every gap
// that actually crosses into a different area of the galaxy in both scenarios is >=8
// (yugen's two outlier systems) or in the tens-to-hundreds (kspace-wide's
// cluster-to-cluster separation, yugen's other region-to-region jumps: 15, 32, 45, 51).
//
// 6 is therefore the ladder rung that sits just above the 95th percentile of genuine
// same-neighbourhood gaps galaxy-wide AND above every real same-neighbourhood gap
// measured directly in both scenarios, while staying strictly below every real
// cross-neighbourhood gap measured directly in both scenarios.
const NEIGHBOURHOOD_GAP_CELLS = 6;

// CHEWY PATCH: within a segment, a raw gap between two consecutive members is
// clamped to at most LOCAL_PACK_CELLS local cells before being added to the running
// local position — this is the direct generalization of the old compressAxis rule
// ("every gap becomes exactly 1 local cell", i.e. LOCAL_PACK_CELLS == 1) up to a cap
// wide enough that it almost never needs to trigger. LOCAL_PACK_CELLS is pinned at 1
// (i.e. exactly the old compressAxis rule): measured directly against
// dev/layout-bench.mjs, any larger cap preserves more of a segment's real spacing
// but reliably reintroduces edge crossings (yugen's real internal gate/wormhole
// geometry is dense enough that a merely "looser" box, not just a differently
// segmented one, crosses edges a bounded local cleanup pass can't fully absorb) —
// so the within-segment rule stays exactly as tight as before the stability work
// and all of the stability gain here comes from NEIGHBOURHOOD_GAP_CELLS (item 1)
// and the anchor-segment offset scheme below (item 2), not from loosening packing.
const LOCAL_PACK_CELLS = 1;

interface AxisSegment {
  start: number;
  end: number;
}

/**
 * Splits the sorted distinct raw values into segments wherever a neighbour-to-
 * neighbour gap exceeds NEIGHBOURHOOD_GAP_CELLS. Pure function of `sorted` alone.
 */
const splitSegments = (sorted: number[]): AxisSegment[] => {
  const segments: AxisSegment[] = [];
  let start = 0;
  for (let i = 1; i <= sorted.length; i++) {
    if (i === sorted.length || sorted[i] - sorted[i - 1] > NEIGHBOURHOOD_GAP_CELLS) {
      segments.push({ start, end: i });
      start = i;
    }
  }
  return segments;
};

/**
 * CHEWY PATCH: picks the anchor segment by which one contains the MEDIAN index of
 * `sorted`, not by which segment currently has the most members. Population is a
 * discrete "winner take all" comparison — when two segments are close in size (a
 * common case: dev/layout-bench.mjs's kspace-wide has three real clusters of 13, 13,
 * 14 members), a handful of insertions into the smaller one flips which is "biggest",
 * and flipping the anchor renumbers literally everyone relative to the new one
 * (verified directly: kspace-wide k=5 — some repeats moved all 40/40 members by up
 * to 17 cells once two clusters' populations crossed). The median index of the whole
 * sorted value list moves by at most half of however many NEW values landed in THIS
 * call, so a handful of insertions shifts it by only a couple of positions — nowhere
 * near enough to cross from one well-separated real cluster into another unless the
 * median was already sitting right at the boundary between two nearly-equal-sized
 * ones, which is itself rare and no worse than the old population comparison's own
 * worst case there.
 */
const pickAnchorSegment = (segments: AxisSegment[], sortedLength: number): number => {
  const medianIndex = Math.floor((sortedLength - 1) / 2);
  for (let i = 0; i < segments.length; i++) {
    if (medianIndex < segments[i].end) return i;
  }
  return segments.length - 1;
};

/**
 * Maps every used raw value on one axis to a quantized local cell.
 *
 * CHEWY PATCH (replaces the old rank-bijection compressAxis, and later the
 * adaptive-median version of this function): sort the distinct raw values and split
 * them into SEGMENTS wherever a neighbour-to-neighbour gap exceeds the fixed
 * NEIGHBOURHOOD_GAP_CELLS threshold — "same neighbourhood" vs. "unrelated area" per
 * the analysis above, independent of whatever else happens to be in `usedValues`
 * this call. WITHIN a segment, each member's local cell is the running sum of every
 * earlier gap in that segment, each capped at LOCAL_PACK_CELLS — so a member's
 * position only ever depends on its own segment's own earlier members.
 *
 * CHEWY PATCH: segment OFFSETS used to be a pure left-to-right cumulative sum
 * starting at segment 0 — which meant a brand-new segment landing before every
 * existing one (a real, common case: a "nearest lattice neighbour" insertion can
 * legitimately be a fraction of a unit outside the current minimum) pushed the
 * offset of EVERY OTHER segment, i.e. every other member on the map, even though
 * not one of their own raw values changed (verified directly: dev/layout-bench.mjs
 * kspace-wide k=1 — one specific edge-of-cluster insertion moved all 40/40 members).
 * Offsets are now anchored at the segment containing the MEDIAN index of the whole
 * sorted value list (see pickAnchorSegment's own comment for why median, not
 * population) — the segment statistically least likely to change identity from a
 * handful of insertions. That segment sits at local offset 0 and never moves; every
 * OTHER segment's offset is the cumulative reserved width of every segment strictly
 * between it and the anchor (walking outward in both directions, negative before the
 * anchor) — so a brand-new boundary segment only ever shifts the segments on ITS OWN
 * side of the anchor, and the anchor segment's own members (almost always the bulk
 * of the map) never move at all because of it.
 */
const quantizeAxis = (usedValues: number[]): Map<number, number> => {
  const sorted = [...new Set(usedValues)].sort((a, b) => a - b);
  const mapping = new Map<number, number>();
  if (sorted.length === 0) return mapping;

  const segments = splitSegments(sorted);
  const anchorIdx = pickAnchorSegment(segments, sorted.length);

  const offsets = new Array<number>(segments.length);
  offsets[anchorIdx] = 0;
  for (let i = anchorIdx + 1; i < segments.length; i++) {
    const prev = segments[i - 1];
    offsets[i] = offsets[i - 1] + ladderSnap(prev.end - prev.start);
  }
  for (let i = anchorIdx - 1; i >= 0; i--) {
    offsets[i] = offsets[i + 1] - ladderSnap(segments[i].end - segments[i].start);
  }

  for (let s = 0; s < segments.length; s++) {
    const { start, end } = segments[s];
    let local = 0;
    mapping.set(sorted[start], offsets[s]);
    for (let i = start + 1; i < end; i++) {
      local += Math.min(sorted[i] - sorted[i - 1], LOCAL_PACK_CELLS);
      mapping.set(sorted[i], offsets[s] + local);
    }
  }
  return mapping;
};

/**
 * Quantization is lossy, so two different members can legitimately share
 * an ideal local cell; resolve any such collision deterministically and
 * LOCALLY.
 *
 * CHEWY PATCH: a full 2D spiral search (tried first) occasionally solved
 * one collision by displacing a member into a cell that belonged, in
 * spirit, to a THIRD member somewhere else in the box — rare (kspace-wide
 * has none in its base layout, ~1 in 30 seeded growth repeats hit it) but
 * enough to flip that pair's left/right order, which rankInversions in
 * dev/layout-bench.mjs treats as a hard failure. Pushing rightward
 * WITHIN THE SAME ROW instead is provably safe for row order (a member's
 * row is never touched, ever) and safe for column order too (a pushed
 * member's column only ever increases, and it only ever displaces a
 * member that already had a column at least as large, which then gets
 * pushed further right in turn) — so this can still cascade through a
 * crowded row, but strictly forward, never crossing anyone.
 */
const resolveCollisions = (ideal: Map<string, CellCoord>): Map<string, CellCoord> => {
  const order = [...ideal.entries()].sort(
    ([idA, a], [idB, b]) => a.col - b.col || a.row - b.row || (idA < idB ? -1 : idA > idB ? 1 : 0),
  );
  const key = (c: CellCoord) => `${c.col},${c.row}`;
  const occupied = new Set<string>();
  const resolved = new Map<string, CellCoord>();
  for (const [id, cell] of order) {
    let placed = cell;
    while (occupied.has(key(placed))) {
      placed = { col: placed.col + 1, row: placed.row };
    }
    occupied.add(key(placed));
    resolved.set(id, placed);
  }
  return resolved;
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
 * cell as ONE box, quantized once across the whole set (not per region,
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

  const colMap = quantizeAxis([...raw.values()].map(c => c.col));
  const rowMap = quantizeAxis([...raw.values()].map(c => c.row));

  const idealCells = new Map<string, CellCoord>();
  for (const [id, cell] of raw) {
    idealCells.set(id, { col: colMap.get(cell.col)!, row: rowMap.get(cell.row)! });
  }
  const localCells = resolveCollisions(idealCells);

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
