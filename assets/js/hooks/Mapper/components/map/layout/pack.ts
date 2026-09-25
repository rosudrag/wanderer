// Places a set of already-locally-laid-out boxes (wormhole chain trees and
// k-space region groups) onto one shared cell grid without overlap.
//
// Why a two-stage approach (box-level shift search, then a per-cell safety
// net) rather than a single global solver: box shapes are irregular
// (trees are not rectangles, compressed region grids are not rectangles),
// so bounding-box non-overlap is a *sufficient* but not by itself provable
// guarantee once real data and edge cases (data bugs, degenerate 1-cell
// regions, rounding) are considered. The safety net makes "no two nodes
// ever share a cell" a hard invariant regardless of upstream logic.

import { segmentHitsNodeBox } from './geometry';
import type { CellCoord, LayoutBox, LayoutQuality } from './types';

interface Rect {
  minCol: number;
  maxCol: number;
  minRow: number;
  maxRow: number;
}

const rectOf = (cells: Map<string, CellCoord>): Rect => {
  let minCol = Infinity;
  let maxCol = -Infinity;
  let minRow = Infinity;
  let maxRow = -Infinity;
  for (const { col, row } of cells.values()) {
    if (col < minCol) minCol = col;
    if (col > maxCol) maxCol = col;
    if (row < minRow) minRow = row;
    if (row > maxRow) maxRow = row;
  }
  if (!Number.isFinite(minCol)) {
    // Empty box (shouldn't normally happen) — treat as a zero-size rect at the origin.
    return { minCol: 0, maxCol: 0, minRow: 0, maxRow: 0 };
  }
  return { minCol, maxCol, minRow, maxRow };
};

const shiftRect = (r: Rect, dCol: number, dRow: number): Rect => ({
  minCol: r.minCol + dCol,
  maxCol: r.maxCol + dCol,
  minRow: r.minRow + dRow,
  maxRow: r.maxRow + dRow,
});

/** Rects overlap (including the required 1-cell gutter) when they are not separated by at least one empty cell on every axis. */
const overlaps = (a: Rect, b: Rect): boolean =>
  !(a.maxCol + 1 < b.minCol || b.maxCol + 1 < a.minCol || a.maxRow + 1 < b.minRow || b.maxRow + 1 < a.minRow);

/**
 * Deterministic expanding-ring search for the nearest integer shift (dCol,
 * dRow) — starting at (0, 0), i.e. the box's own proposed position — such
 * that the shifted rect no longer overlaps any already-placed rect. Ring
 * order (right, down, left, up per radius) is arbitrary but fixed, which is
 * all determinism requires.
 */
const findFreeShift = (rect: Rect, placed: Rect[], maxRadius = 2000): { dCol: number; dRow: number } => {
  if (!placed.some(p => overlaps(rect, p))) {
    return { dCol: 0, dRow: 0 };
  }

  for (let radius = 1; radius <= maxRadius; radius++) {
    for (let dCol = -radius; dCol <= radius; dCol++) {
      const rowSpan = radius - Math.abs(dCol);
      const rows = rowSpan === 0 ? [0] : [-rowSpan, rowSpan];
      for (const dRow of rows) {
        // Only test points on the ring boundary (Chebyshev distance === radius).
        if (Math.max(Math.abs(dCol), Math.abs(dRow)) !== radius) continue;
        const candidate = shiftRect(rect, dCol, dRow);
        if (!placed.some(p => overlaps(candidate, p))) {
          return { dCol, dRow };
        }
      }
    }
  }

  // Practically unreachable for real map sizes; fall back to "don't move" rather than throwing.
  return { dCol: 0, dRow: 0 };
};

// CHEWY PATCH: box order used to be size-rank (largest area first), so a box
// that merely grew by one node (a new system added to its cluster/branch)
// could jump the rank and reorder every other box's placement — the exact
// packing-side cascade the stability work targets. Order is now a pure
// function of each box's OWN proposed rect origin (col, then row — its
// anchor/seed node's existing position, quantized: the geographic k-space
// box's own compressed-lattice origin, or a chain box's translation off its
// pinned anchor's real current cell) plus its id, never of other boxes'
// current sizes, so adding a system to one component no longer perturbs the
// relative placement order of the others.
const floatBoxOrderKey = (box: LayoutBox): [number, number, string] => {
  const rect = rectOf(box.cells);
  return [rect.minCol, rect.minRow, box.id];
};

export const packBoxes = (boxes: LayoutBox[]): Map<string, CellCoord> => {
  const placedRects: Rect[] = [];
  // (id, cell, priority) triples in deterministic placement order; later
  // entries win ties in the final per-cell dedupe pass below.
  const ordered: Array<{ id: string; cell: CellCoord }> = [];

  const fixedBoxes = [...boxes.filter(b => b.fixed)].sort((a, b) => a.id.localeCompare(b.id));
  const floatBoxes = [...boxes.filter(b => !b.fixed)].sort((a, b) => {
    const [aCol, aRow, aId] = floatBoxOrderKey(a);
    const [bCol, bRow, bId] = floatBoxOrderKey(b);
    return aCol !== bCol ? aCol - bCol : aRow !== bRow ? aRow - bRow : aId.localeCompare(bId);
  });

  for (const box of fixedBoxes) {
    placedRects.push(rectOf(box.cells));
    for (const [id, cell] of box.cells) ordered.push({ id, cell });
  }

  for (const box of floatBoxes) {
    const rect = rectOf(box.cells);
    const { dCol, dRow } = findFreeShift(rect, placedRects);
    placedRects.push(shiftRect(rect, dCol, dRow));
    for (const [id, cell] of box.cells) ordered.push({ id, cell: { col: cell.col + dCol, row: cell.row + dRow } });
  }

  return dedupeCells(ordered);
};

/**
 * Hard safety net: walk the deterministically-ordered candidate list and
 * guarantee no two node ids ever resolve to the same cell. Earlier entries
 * (fixed boxes first, then floating boxes in stable position order) keep their exact
 * cell; a later entry that collides is nudged to the nearest still-free
 * cell via a small expanding search, so the invariant holds even if box-level
 * placement above ever produced a spurious internal collision.
 */
const dedupeCells = (ordered: Array<{ id: string; cell: CellCoord }>): Map<string, CellCoord> => {
  const used = new Set<string>();
  const result = new Map<string, CellCoord>();
  const key = (c: CellCoord) => `${c.col},${c.row}`;

  const nearestFree = (start: CellCoord): CellCoord => {
    if (!used.has(key(start))) return start;
    for (let radius = 1; radius <= 5000; radius++) {
      for (let dCol = -radius; dCol <= radius; dCol++) {
        const rowSpan = radius - Math.abs(dCol);
        const rows = rowSpan === 0 ? [0] : [-rowSpan, rowSpan];
        for (const dRow of rows) {
          if (Math.max(Math.abs(dCol), Math.abs(dRow)) !== radius) continue;
          const candidate = { col: start.col + dCol, row: start.row + dRow };
          if (!used.has(key(candidate))) return candidate;
        }
      }
    }
    return start; // practically unreachable
  };

  for (const { id, cell } of ordered) {
    const finalCell = nearestFree(cell);
    used.add(key(finalCell));
    result.set(id, finalCell);
  }

  return result;
};

// ---------------------------------------------------------------------------
// CHEWY PATCH: final crossing/overlap/occlusion-reduction pass
// ---------------------------------------------------------------------------
//
// A cheap, deterministic local-search cleanup over pack.ts's own output.
// packBoxes places whole boxes (trees, region groups) without overlap, but
// has no notion of edges, so it can leave individual nodes on the wrong
// side of a neighbour — most visibly in `yugen`, which is essentially one
// k-space cluster plus a few short wormhole branches.
//
// CHEWY PATCH (stability fix): the previous version of this pass greedily
// accepted the FIRST trial (nudge, then any nearby swap) that helped, in
// sorted-id order. That made the outcome depend on which nodes happened to
// be candidates and in what order the loop reached them — exactly the kind
// of cascade the rewrite was meant to remove, just moved into this pass.
// `StableKSpace` proved a node's ideal lattice cell could be byte-identical
// before and after an insertion while this pass still changed its final
// row. The pass is now:
//   1. Relocation-first: a node prefers moving into a FREE cell within
//      MAX_NODE_DISPLACEMENT_CELLS of its own current cell over swapping.
//   2. Swaps are restricted to node pairs that are endpoints of the SAME
//      crossing edge pair (one endpoint from each of the two edges that
//      actually cross) — the literal "these two are on the wrong side of
//      each other" case a swap models, not "any two candidates within N
//      cells", which could invert order between nodes that had nothing to
//      do with each other's crossing.
//   3. Acceptance is canonical, not first-come: every sweep evaluates ALL
//      candidate moves against the same starting state, sorts them by
//      (violation score removed desc, displacement asc, id asc), and
//      applies them in that order. The result is a pure function of the
//      current graph + cell layout, never of iteration/insertion order.
//   4. Every move is capped at MAX_NODE_DISPLACEMENT_CELLS away from the
//      node's OWN pre-pass ("origin") cell, for the life of the whole
//      pass — a node this pass touches ends up adjacent to where the
//      geometry put it, never reshuffled across the map.
// Because a rejected trial is always reverted, and moves only ever land on
// already-free cells, `overlaps === 0` and `offGrid === 0` cannot regress;
// locked nodes are simply never included in `movableIds` by the caller, so
// they never move. A hard iteration cap (MAX_CROSSING_ITERATIONS) keeps the
// pass bounded regardless of graph size.
//
// CHEWY PATCH (occlusion fix): "zero crossings" was never the same claim as
// "no connection is hidden". Two edges sharing an endpoint and running along
// the exact same line (Irmalin->Ibani and Ibani->Raihbaka in the real
// `yugen` data, all three on row 675) were deliberately EXCLUDED from
// `countCrossings`/`findCrossingPairs` — "shares an endpoint" is the normal
// signal for "meets at an angle, fine" — so the shorter edge sat invisibly
// inside the longer one, and a third node (`Raihbaka`) landed exactly on
// the midpoint of the edge it wasn't even part of. Both are real defects a
// pure crossing count is blind to, so the objective this pass optimises is
// now a single weighted violation score — crossings, collinear edge-overlap
// pairs (`countEdgeOverlapPairs`, checked WITHOUT the shared-endpoint skip,
// on purpose), and node-on-edge occlusions (`countNodeOcclusions`) — instead
// of a raw crossing count. Every other property above is unchanged: the
// early-exit only fires when the WHOLE score is zero (so a `yugen`-shaped
// map with zero crossings but a live occlusion is no longer left untouched),
// candidate nodes are still only ones that are party to a CURRENT violation
// of any of the three kinds, and moves are still relocation-first,
// canonically accepted, and displacement-capped — so fixing occlusion does
// not reopen the exact cascade the stability rewrite closed.

interface CrossingEdge {
  source: string;
  target: string;
}

const orient = (px: number, py: number, qx: number, qy: number, rx: number, ry: number): number =>
  Math.sign((qx - px) * (ry - py) - (qy - py) * (rx - px));

const onSegment = (px: number, py: number, qx: number, qy: number, rx: number, ry: number): boolean =>
  Math.min(px, rx) <= qx && qx <= Math.max(px, rx) && Math.min(py, ry) <= qy && qy <= Math.max(py, ry);

/**
 * Proper segment intersection (including collinear overlap), mirroring
 * dev/layout-bench.mjs's `segmentsIntersect` exactly but operating directly
 * in (col, row) cell space instead of pixels: scaling every point by the
 * same positive per-axis factor (×CELL_W, ×CELL_H) is a linear map with a
 * positive-diagonal matrix, which never changes orientation sign or
 * collinearity, so which segment pairs cross is identical either way —
 * cell space is just cheaper to work in for a search loop.
 */
const segmentsIntersect = (
  ax: number,
  ay: number,
  bx: number,
  by: number,
  cx: number,
  cy: number,
  dx: number,
  dy: number,
): boolean => {
  const o1 = orient(ax, ay, bx, by, cx, cy);
  const o2 = orient(ax, ay, bx, by, dx, dy);
  const o3 = orient(cx, cy, dx, dy, ax, ay);
  const o4 = orient(cx, cy, dx, dy, bx, by);
  if (o1 !== o2 && o3 !== o4) return true;
  if (o1 === 0 && onSegment(ax, ay, cx, cy, bx, by)) return true;
  if (o2 === 0 && onSegment(ax, ay, dx, dy, bx, by)) return true;
  if (o3 === 0 && onSegment(cx, cy, ax, ay, dx, dy)) return true;
  if (o4 === 0 && onSegment(cx, cy, bx, by, dx, dy)) return true;
  return false;
};

const countCrossings = (edges: CrossingEdge[], cells: Map<string, CellCoord>): number => {
  let total = 0;
  for (let i = 0; i < edges.length; i++) {
    const a = edges[i];
    const pa = cells.get(a.source);
    const pb = cells.get(a.target);
    if (!pa || !pb) continue;
    for (let j = i + 1; j < edges.length; j++) {
      const b = edges[j];
      if (a.source === b.source || a.source === b.target || a.target === b.source || a.target === b.target) continue;
      const pc = cells.get(b.source);
      const pd = cells.get(b.target);
      if (!pc || !pd) continue;
      if (segmentsIntersect(pa.col, pa.row, pb.col, pb.row, pc.col, pc.row, pd.col, pd.row)) total++;
    }
  }
  return total;
};

/**
 * CHEWY PATCH: two edges are an "overlap pair" when they are collinear AND
 * their 1-D projections along that shared line cover more than a single
 * point — one edge fully or partially hiding the other, e.g. Ibani->Irmalin
 * with Ibani->Raihbaka running along the exact same row. This is
 * deliberately NOT the same shape as a "crossing": `segmentsIntersect`
 * above (correctly) treats two edges that merely MEET at a shared endpoint,
 * at any angle, as fine, and `countCrossings`/`findCrossingPairs` skip any
 * pair sharing a source/target id for exactly that reason. An overlap pair
 * is checked WITHOUT that skip on purpose — the real yugen defect is two
 * edges that share the endpoint Ibani and run along the same line, which a
 * "shares an endpoint → ignore" rule would hide forever.
 */
const edgesOverlap = (
  ax: number,
  ay: number,
  bx: number,
  by: number,
  cx: number,
  cy: number,
  dx: number,
  dy: number,
): boolean => {
  const dirCol = bx - ax;
  const dirRow = by - ay;
  if (dirCol === 0 && dirRow === 0) return false; // degenerate edge, no line to share
  if (orient(ax, ay, bx, by, cx, cy) !== 0) return false;
  if (orient(ax, ay, bx, by, dx, dy) !== 0) return false;

  // Both segments are collinear, so a single scalar parameter along
  // (dirCol, dirRow) — computed with exact integer dot products, no epsilon
  // needed in cell space — orders every point on the shared line
  // consistently for both edges. Overlap is a real (>0), not just touching
  // (=0), stretch.
  const paramOf = (x: number, y: number): number => (x - ax) * dirCol + (y - ay) * dirRow;
  const aHi = paramOf(bx, by); // > 0 since (dirCol, dirRow) !== (0, 0)
  const cParam = paramOf(cx, cy);
  const dParam = paramOf(dx, dy);
  const bLo = Math.min(cParam, dParam);
  const bHi = Math.max(cParam, dParam);
  return Math.min(aHi, bHi) > Math.max(0, bLo);
};

const countEdgeOverlapPairs = (edges: CrossingEdge[], cells: Map<string, CellCoord>): number => {
  let total = 0;
  for (let i = 0; i < edges.length; i++) {
    const a = edges[i];
    if (a.source === a.target) continue;
    const pa = cells.get(a.source);
    const pb = cells.get(a.target);
    if (!pa || !pb) continue;
    for (let j = i + 1; j < edges.length; j++) {
      const b = edges[j];
      if (b.source === b.target) continue;
      const pc = cells.get(b.source);
      const pd = cells.get(b.target);
      if (!pc || !pd) continue;
      if (edgesOverlap(pa.col, pa.row, pb.col, pb.row, pc.col, pc.row, pd.col, pd.row)) total++;
    }
  }
  return total;
};

/**
 * CHEWY PATCH: a node "occludes" an edge when the edge's drawn line passes
 * through that node's RENDERED BOX and the node is not one of the edge's own
 * two endpoints — e.g. Raihbaka sitting on Ibani->Irmalin.
 *
 * This used to be an exact point-on-segment test on cell coordinates, which
 * matched only the rare case of a node landing precisely on the line, and so
 * scored the live `yugen` map as occlusion-free while six of its connections
 * ran under a foreign node box. The rule (and the evidence behind it) now
 * lives in ./geometry.ts, shared with anchor.ts and the benchmark so all
 * three judge "hidden connection" identically.
 *
 * Endpoint exclusion is free here: `dedupeCells` and the occupied-cell
 * bookkeeping below guarantee no two node ids share a cell, so a non-endpoint
 * node can never coincide with an endpoint's cell — but its BOX can now
 * overlap an endpoint's box, which is exactly the "drawn on top of a
 * neighbour's link" case we want counted.
 */
const nodeOccludesEdge = (px: number, py: number, ax: number, ay: number, bx: number, by: number): boolean =>
  segmentHitsNodeBox({ col: ax, row: ay }, { col: bx, row: by }, { col: px, row: py });

const countNodeOcclusions = (edges: CrossingEdge[], cells: Map<string, CellCoord>): number => {
  let total = 0;
  for (const edge of edges) {
    if (edge.source === edge.target) continue;
    const pa = cells.get(edge.source);
    const pb = cells.get(edge.target);
    if (!pa || !pb) continue;
    for (const [nodeId, p] of cells) {
      if (nodeId === edge.source || nodeId === edge.target) continue;
      if (nodeOccludesEdge(p.col, p.row, pa.col, pa.row, pb.col, pb.row)) total++;
    }
  }
  return total;
};

const MAX_CROSSING_ITERATIONS = 20000;

// CHEWY PATCH: a node's displacement is measured from its OWN post-pack
// cell (the cell packBoxes handed it, before this pass ever touches it)
// and capped for the WHOLE pass, not per move. This is the fix for the
// proven failure mode: a node whose ideal lattice cell never changed still
// ended up on a different final row because an unbounded chain of accepted
// swaps/nudges could walk it arbitrarily far from where the geometry put
// it. With the cap, the worst this pass can do to any single node is leave
// it MAX_NODE_DISPLACEMENT_CELLS away from its geometric position — "the
// neighbour that was on the wrong side", never "reshuffled". Relocation
// candidates are searched directly out to this same radius as ONE move
// (not a chain of 1-cell steps), so the pass can still find the cell that
// actually clears a crossing instead of stalling short of it.
const MAX_NODE_DISPLACEMENT_CELLS = 2;

/** Every candidate offset within MAX_NODE_DISPLACEMENT_CELLS of a node's CURRENT cell, nearest first then column/row for fully deterministic trial generation (final acceptance order is the canonical sort below regardless — this just keeps the trial list itself reproducible). */
const NUDGE_OFFSETS: ReadonlyArray<readonly [number, number]> = (() => {
  const radius = Math.ceil(MAX_NODE_DISPLACEMENT_CELLS);
  const offsets: Array<[number, number]> = [];
  for (let dCol = -radius; dCol <= radius; dCol++) {
    for (let dRow = -radius; dRow <= radius; dRow++) {
      if (dCol === 0 && dRow === 0) continue;
      if (Math.hypot(dCol, dRow) > MAX_NODE_DISPLACEMENT_CELLS) continue;
      offsets.push([dCol, dRow]);
    }
  }
  offsets.sort(([aCol, aRow], [bCol, bRow]) => {
    const da = Math.hypot(aCol, aRow);
    const db = Math.hypot(bCol, bRow);
    return da - db || aCol - bCol || aRow - bRow;
  });
  return offsets;
})();

interface CrossingPair {
  a: CrossingEdge;
  b: CrossingEdge;
}

/**
 * Every pair of edges that currently properly intersect (same definition as
 * countCrossings). Used both to derive the candidate node pool for a sweep
 * and — for swaps — to restrict partners to nodes that actually belong to
 * the SAME crossing, instead of any two candidates that happen to be near
 * each other.
 */
const findCrossingPairs = (edges: CrossingEdge[], cells: Map<string, CellCoord>): CrossingPair[] => {
  const pairs: CrossingPair[] = [];
  for (let i = 0; i < edges.length; i++) {
    const a = edges[i];
    const pa = cells.get(a.source);
    const pb = cells.get(a.target);
    if (!pa || !pb) continue;
    for (let j = i + 1; j < edges.length; j++) {
      const b = edges[j];
      if (a.source === b.source || a.source === b.target || a.target === b.source || a.target === b.target) continue;
      const pc = cells.get(b.source);
      const pd = cells.get(b.target);
      if (!pc || !pd) continue;
      if (segmentsIntersect(pa.col, pa.row, pb.col, pb.row, pc.col, pc.row, pd.col, pd.row)) {
        pairs.push({ a, b });
      }
    }
  }
  return pairs;
};

interface OverlapPair {
  a: CrossingEdge;
  b: CrossingEdge;
}

/** Same predicate as `countEdgeOverlapPairs`, collected as pairs for candidate-node derivation below. */
const findEdgeOverlapPairs = (edges: CrossingEdge[], cells: Map<string, CellCoord>): OverlapPair[] => {
  const pairs: OverlapPair[] = [];
  for (let i = 0; i < edges.length; i++) {
    const a = edges[i];
    if (a.source === a.target) continue;
    const pa = cells.get(a.source);
    const pb = cells.get(a.target);
    if (!pa || !pb) continue;
    for (let j = i + 1; j < edges.length; j++) {
      const b = edges[j];
      if (b.source === b.target) continue;
      const pc = cells.get(b.source);
      const pd = cells.get(b.target);
      if (!pc || !pd) continue;
      if (edgesOverlap(pa.col, pa.row, pb.col, pb.row, pc.col, pc.row, pd.col, pd.row)) {
        pairs.push({ a, b });
      }
    }
  }
  return pairs;
};

interface NodeOcclusion {
  nodeId: string;
  edge: CrossingEdge;
}

/** Same predicate as `countNodeOcclusions`, collected for candidate-node derivation (see reduceCrossings below). */
const findNodeOcclusions = (edges: CrossingEdge[], cells: Map<string, CellCoord>): NodeOcclusion[] => {
  const occlusions: NodeOcclusion[] = [];
  for (const edge of edges) {
    if (edge.source === edge.target) continue;
    const pa = cells.get(edge.source);
    const pb = cells.get(edge.target);
    if (!pa || !pb) continue;
    for (const [nodeId, p] of cells) {
      if (nodeId === edge.source || nodeId === edge.target) continue;
      if (nodeOccludesEdge(p.col, p.row, pa.col, pa.row, pb.col, pb.row)) {
        occlusions.push({ nodeId, edge });
      }
    }
  }
  return occlusions;
};

// CHEWY PATCH: the pass's objective generalises from "number of crossings"
// to a weighted violation score. A hidden connection (one edge's line
// swallowing another, or a node sitting on top of a line it doesn't touch)
// is worse for a user than two lines visibly crossing, so both new
// violation kinds are weighted far above a single crossing: 1000 vs 1 means
// no plausible single-move swing in crossing count (bounded by the graph's
// max node degree, nowhere near 1000 for any real map) can ever outweigh
// clearing one overlap/occlusion. This makes the score a strict
// lexicographic priority — eliminate every hidden-connection violation
// first, and only break remaining ties by crossing count — while staying a
// single scalar so the existing canonical-sort/acceptance machinery below
// needs no changes.
const CROSSING_WEIGHT = 1;
const OVERLAP_WEIGHT = 1000;
const OCCLUSION_WEIGHT = 1000;

const violationScore = (edges: CrossingEdge[], cells: Map<string, CellCoord>): number =>
  countCrossings(edges, cells) * CROSSING_WEIGHT +
  countEdgeOverlapPairs(edges, cells) * OVERLAP_WEIGHT +
  countNodeOcclusions(edges, cells) * OCCLUSION_WEIGHT;

// CHEWY PATCH: total drawn edge length (in cells), used ONLY to choose
// between repair moves that remove the same violations (see
// candidateCompare). It matters because the move that clears an occlusion is
// rarely unique: preferring the shorter-edge variant took the live `yugen`
// snapshot from 106.7 to 89.3 cells of total edge while fixing the same six
// hidden connections.

const totalEdgeLength = (edges: CrossingEdge[], cells: Map<string, CellCoord>): number => {
  let total = 0;
  for (const edge of edges) {
    const a = cells.get(edge.source);
    const b = cells.get(edge.target);
    if (!a || !b) continue;
    total += Math.hypot(a.col - b.col, a.row - b.row);
  }
  return total;
};

type CrossingCandidate =
  | {
      kind: 'relocate';
      id: string;
      to: CellCoord;
      delta: number;
      lengthDelta: number;
      displacement: number;
      tieId: string;
    }
  | {
      kind: 'swap';
      idLo: string;
      idHi: string;
      cellForLo: CellCoord;
      cellForHi: CellCoord;
      delta: number;
      lengthDelta: number;
      displacement: number;
      tieId: string;
    };

/**
 * Canonical acceptance order: violations removed desc, then edge length
 * removed desc, then displacement asc, then id asc — a pure function of the
 * candidate's own numbers, never of discovery order.
 *
 * CHEWY PATCH: `lengthDelta` is a TIE-BREAK ONLY, never an acceptance
 * criterion. A move must still strictly reduce the violation score to be
 * accepted at all; among moves that remove the same violations, the one that
 * also shortens the drawn edges wins. Making length part of the accepted
 * objective instead was measured to destroy idempotence: with any crossing
 * left anywhere on the map (score > 0, e.g. the live yugen map's 5), the pass
 * kept finding equal-violation/shorter-length moves forever, so beautifying
 * an already-beautified map moved 7-11 nodes every time and eventually
 * wandered into MORE crossings (5 -> 12 over four passes).
 */
const candidateCompare = (x: CrossingCandidate, y: CrossingCandidate): number =>
  y.delta - x.delta ||
  y.lengthDelta - x.lengthDelta ||
  x.displacement - y.displacement ||
  (x.tieId < y.tieId ? -1 : x.tieId > y.tieId ? 1 : 0);

// CHEWY PATCH: the same numbers the repair objective optimises, exposed so a
// caller can compare two candidate layouts (see index.ts's auto-mode guard:
// a full re-solve that scores WORSE than the map the user already has is
// never applied) and so the UI can tell the user what changed.

export const measureLayout = (edges: CrossingEdge[], cells: Map<string, CellCoord>): LayoutQuality => ({
  crossings: countCrossings(edges, cells),
  overlaps: countEdgeOverlapPairs(edges, cells),
  occlusions: countNodeOcclusions(edges, cells),
  edgeLength: totalEdgeLength(edges, cells),
});

/**
 * Weight of total edge length when COMPARING two whole layouts of the same
 * graph (index.ts's auto-mode guard). Small enough to never outrank a single
 * crossing: length only settles ties between layouts with identical hidden
 * connections and crossings.
 */
const LENGTH_WEIGHT = 1e-6;

/** Single comparable scalar for two layouts of the SAME graph: hidden connections first, then crossings, then edge length. */
export const qualityScore = (quality: LayoutQuality): number =>
  quality.occlusions * OCCLUSION_WEIGHT +
  quality.overlaps * OVERLAP_WEIGHT +
  quality.crossings * CROSSING_WEIGHT +
  quality.edgeLength * LENGTH_WEIGHT;

/**
 * Final improvement pass: mutates a copy of `cells` toward a lower weighted
 * violation score (crossings + collinear edge-overlap pairs + node-on-edge
 * occlusions — see `violationScore` and the file header) among `edges`,
 * touching only ids in `movableIds`, and returns the result.
 *
 * The candidate pool for every sweep is NOT "every movable node" — it's
 * recomputed each sweep from the union of `findCrossingPairs()`,
 * `findEdgeOverlapPairs()`, and `findNodeOcclusions()`, intersected with
 * `movableIds`, i.e. only nodes that are currently party to an actual
 * violation. A scenario with a zero score (or a part of the map with none)
 * is never touched at all, and a new node only perturbs the pass if it
 * actually creates a new violation.
 *
 * Within a sweep, every candidate move (a relocation onto a free adjacent
 * cell, or a swap between two nodes that are endpoints of the SAME
 * crossing pair — see the file header) is trialled against the SAME
 * starting state and kept only if it strictly reduces the violation score.
 * All keepers are then sorted canonically (candidateCompare) and applied in
 * that order, skipping any a higher-priority move already invalidated (its
 * target cell got taken, or one of its nodes already moved this sweep) or
 * that no longer helps once re-checked against the live state. Every move
 * is also rejected up front if it would push a node more than
 * `MAX_NODE_DISPLACEMENT_CELLS` from its own pre-pass cell.
 *
 * Runs to a local fixed point (a sweep with zero accepted changes) or
 * `MAX_CROSSING_ITERATIONS` trials, whichever comes first.
 */
export const reduceCrossings = (
  cells: Map<string, CellCoord>,
  edges: CrossingEdge[],
  movableIds: ReadonlySet<string>,
  /**
   * CHEWY PATCH: optional hard constraint on where a node may be put. Used for
   * chain standoff: without it this pass happily pulled a chain system back to
   * within one cell of the k-space lattice it had just been moved clear of
   * (measured on live yugen: Raihbaka and J165815, 2 cells back in).
   */
  isCellAllowed?: (id: string, cell: CellCoord) => boolean,
): Map<string, CellCoord> => {
  const result = new Map(cells);

  let hard = violationScore(edges, result);
  if (hard === 0) return result;

  // Reference cell for MAX_NODE_DISPLACEMENT_CELLS: each node's cell as
  // packBoxes handed it, fixed for the life of this whole pass (not reset
  // sweep to sweep), so displacement never silently accumulates past the cap
  // through a chain of individually-small moves.
  const origin = new Map(cells);

  const key = (c: CellCoord) => `${c.col},${c.row}`;
  const occupied = new Set<string>();
  for (const c of result.values()) occupied.add(key(c));

  const displacementFrom = (id: string, cell: CellCoord): number => {
    const o = origin.get(id);
    if (!o) return 0;
    return Math.hypot(cell.col - o.col, cell.row - o.row);
  };

  let iterations = 0;

  while (hard > 0 && iterations < MAX_CROSSING_ITERATIONS) {
    const crossingPairs = findCrossingPairs(edges, result);
    const overlapPairs = findEdgeOverlapPairs(edges, result);
    const occlusions = findNodeOcclusions(edges, result);
    if (crossingPairs.length === 0 && overlapPairs.length === 0 && occlusions.length === 0) break;
    const currentLength = totalEdgeLength(edges, result);

    // CHEWY PATCH: candidate pool now spans every kind of violation, not
    // just crossings — the endpoints of an overlapping edge pair, and both
    // the occluding node and the occluded edge's own endpoints, are exactly
    // as much "party to a violation" as a crossing's endpoints, per the
    // rule that a node NOT involved in any current violation is never
    // touched.
    const candidateIds = new Set<string>();
    for (const { a, b } of crossingPairs) {
      candidateIds.add(a.source);
      candidateIds.add(a.target);
      candidateIds.add(b.source);
      candidateIds.add(b.target);
    }
    for (const { a, b } of overlapPairs) {
      candidateIds.add(a.source);
      candidateIds.add(a.target);
      candidateIds.add(b.source);
      candidateIds.add(b.target);
    }
    for (const { nodeId, edge } of occlusions) {
      candidateIds.add(nodeId);
      candidateIds.add(edge.source);
      candidateIds.add(edge.target);
    }
    const movableCandidates = [...candidateIds].filter(id => movableIds.has(id)).sort();
    if (movableCandidates.length === 0) break;

    const candidates: CrossingCandidate[] = [];

    // Relocation trials: every candidate node x every free adjacent cell.
    for (const id of movableCandidates) {
      const cellNow = result.get(id)!;
      for (const [dCol, dRow] of NUDGE_OFFSETS) {
        if (iterations >= MAX_CROSSING_ITERATIONS) break;
        const to = { col: cellNow.col + dCol, row: cellNow.row + dRow };
        if (occupied.has(key(to))) continue;
        const displacement = displacementFrom(id, to);
        if (displacement > MAX_NODE_DISPLACEMENT_CELLS) continue;
        if (isCellAllowed && !isCellAllowed(id, to)) continue;
        result.set(id, to);
        const next = violationScore(edges, result);
        const nextLength = totalEdgeLength(edges, result);
        iterations++;
        result.set(id, cellNow);
        if (next < hard) {
          candidates.push({
            kind: 'relocate',
            id,
            to,
            delta: hard - next,
            lengthDelta: currentLength - nextLength,
            displacement,
            tieId: id,
          });
        }
      }
    }

    // Swap trials: ONLY between nodes that are endpoints of the SAME
    // crossing edge pair — one node from each of the two edges that
    // actually cross. This is the literal "swap two neighbours that are on
    // the wrong side of each other" case; it excludes the previous, much
    // broader "any two candidates within N cells" search, which could
    // invert order between nodes that had nothing to do with each other's
    // crossing.
    const seenSwapPairs = new Set<string>();
    for (const { a, b } of crossingPairs) {
      for (const rawLo of [a.source, a.target]) {
        for (const rawHi of [b.source, b.target]) {
          if (rawLo === rawHi) continue;
          if (!movableIds.has(rawLo) || !movableIds.has(rawHi)) continue;
          const [lo, hi] = rawLo < rawHi ? [rawLo, rawHi] : [rawHi, rawLo];
          const pairKey = `${lo}|${hi}`;
          if (seenSwapPairs.has(pairKey)) continue;
          seenSwapPairs.add(pairKey);
          if (iterations >= MAX_CROSSING_ITERATIONS) continue;

          const cellLo = result.get(lo)!;
          const cellHi = result.get(hi)!;
          if (displacementFrom(lo, cellHi) > MAX_NODE_DISPLACEMENT_CELLS) continue;
          if (displacementFrom(hi, cellLo) > MAX_NODE_DISPLACEMENT_CELLS) continue;
          if (isCellAllowed && (!isCellAllowed(lo, cellHi) || !isCellAllowed(hi, cellLo))) continue;

          result.set(lo, cellHi);
          result.set(hi, cellLo);
          const next = violationScore(edges, result);
          const nextLength = totalEdgeLength(edges, result);
          iterations++;
          result.set(lo, cellLo);
          result.set(hi, cellHi);

          if (next < hard) {
            candidates.push({
              kind: 'swap',
              idLo: lo,
              idHi: hi,
              cellForLo: cellHi,
              cellForHi: cellLo,
              delta: hard - next,
              lengthDelta: currentLength - nextLength,
              // Consistent with the relocate branch and the cap check above:
              // "displacement" is each moved node's post-move distance from
              // its OWN origin cell, not the distance between the two swap
              // partners (which is a different, unrelated number).
              displacement: Math.max(displacementFrom(lo, cellHi), displacementFrom(hi, cellLo)),
              tieId: lo,
            });
          }
        }
      }
    }

    if (candidates.length === 0) break;

    // Canonical acceptance: sort every candidate found against this sweep's
    // shared starting state and apply in that order — never "first trial
    // that happened to help" — so the outcome is a pure function of the
    // graph and current cell layout, not of which node the sweep happened
    // to reach first.
    candidates.sort(candidateCompare);

    const touched = new Set<string>();
    let appliedAny = false;

    for (const candidate of candidates) {
      if (hard === 0 || iterations >= MAX_CROSSING_ITERATIONS) break;

      if (candidate.kind === 'relocate') {
        if (touched.has(candidate.id)) continue;
        if (occupied.has(key(candidate.to))) continue; // target taken by an earlier accepted move this sweep
        const cellNow = result.get(candidate.id)!;
        result.set(candidate.id, candidate.to);
        const next = violationScore(edges, result);
        iterations++;
        if (next < hard) {
          occupied.delete(key(cellNow));
          occupied.add(key(candidate.to));
          hard = next;
          touched.add(candidate.id);
          appliedAny = true;
        } else {
          result.set(candidate.id, cellNow);
        }
      } else {
        if (touched.has(candidate.idLo) || touched.has(candidate.idHi)) continue;
        const cellLo = result.get(candidate.idLo)!;
        const cellHi = result.get(candidate.idHi)!;
        result.set(candidate.idLo, candidate.cellForLo);
        result.set(candidate.idHi, candidate.cellForHi);
        const next = violationScore(edges, result);
        iterations++;
        if (next < hard) {
          hard = next;
          touched.add(candidate.idLo);
          touched.add(candidate.idHi);
          appliedAny = true;
        } else {
          result.set(candidate.idLo, cellLo);
          result.set(candidate.idHi, cellHi);
        }
      }
    }

    if (!appliedAny) break;
  }

  return result;
};
