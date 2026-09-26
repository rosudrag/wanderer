// CHEWY PATCH: new file. The one definition of "this node's box hides that
// connection", shared by every path that judges layout quality: anchor.ts
// (is an existing node validly placed / is a candidate cell acceptable),
// pack.ts (the repair pass's objective) and dev/layout-bench.mjs (the
// benchmark metric). The layout header in anchor.ts requires all of them to
// agree on the geometry rules; sharing the predicate is how that is kept
// true rather than asserted.
//
// Why a box and not a point: connections are drawn by DotlanEdge as one
// straight centre-to-centre line, clipped only to the two ENDPOINT boxes —
// any other node's 130x34 box sits on top of whatever passes under it. The
// previous rule ("the node's cell lies exactly on the segment") only fires
// when a node lands precisely on the line, which on real data almost never
// happens: the live production map `yugen` (2026-09-25 snapshot, 32 systems,
// 36 connections) scored ZERO occlusions under the point rule while six
// connections ran under a foreign node box — `Toon` swallowing 102px of
// Auga->Siseide and 62px of Dal->Amamake, `Dal` 43px of Auga->Kourmonen,
// `Olfeim` 30px of Dal->Auga, `Ualkin` 38px of Amamake->Gulmorogod.
//
// The point rule is a strict subset of this one (a point exactly on the
// segment is inside the box), so nothing the old rule caught is lost.

import { CELL_H, CELL_W, NODE_H_PX, NODE_W_PX } from './types';
import type { CellCoord } from './types';

/**
 * Half-extents of a node's rendered box in CELL units. Every node is drawn
 * at its cell origin with the same fixed size, so in cell space every box is
 * the same rectangle centred on the node's own cell coordinate: the
 * centre offset (NODE_W_PX/2/CELL_W, NODE_H_PX/2/CELL_H) is identical for
 * every node and for both endpoints of every edge, so it cancels and raw
 * cell coordinates can be used directly as the line's endpoints.
 */
export const NODE_HALF_W_CELLS = NODE_W_PX / 2 / CELL_W;
export const NODE_HALF_H_CELLS = NODE_H_PX / 2 / CELL_H;

/**
 * True when segment [a,b] passes through the rendered box of a node sitting
 * at cell `node` — Liang-Barsky clip, positive remaining length only, so a
 * line merely grazing the box corner (zero-length intersection) does not
 * count.
 *
 * Endpoint handling is the caller's job: an edge always "hits" the boxes of
 * its own two endpoints, which is not occlusion.
 */
export const segmentHitsNodeBox = (a: CellCoord, b: CellCoord, node: CellCoord): boolean => {
  const dCol = b.col - a.col;
  const dRow = b.row - a.row;

  const p = [-dCol, dCol, -dRow, dRow];
  const q = [
    a.col - (node.col - NODE_HALF_W_CELLS),
    node.col + NODE_HALF_W_CELLS - a.col,
    a.row - (node.row - NODE_HALF_H_CELLS),
    node.row + NODE_HALF_H_CELLS - a.row,
  ];

  let t0 = 0;
  let t1 = 1;
  for (let i = 0; i < 4; i++) {
    if (p[i] === 0) {
      // Parallel to this boundary pair: outside it means no intersection at all.
      if (q[i] < 0) return false;
      continue;
    }
    const t = q[i] / p[i];
    if (p[i] < 0) {
      if (t > t1) return false;
      if (t > t0) t0 = t;
    } else {
      if (t < t0) return false;
      if (t < t1) t1 = t;
    }
  }

  return t1 > t0;
};

// ---------------------------------------------------------------------------
// CHEWY PATCH: angle vocabulary. Lives here, next to the occlusion rule, for
// the same reason: it is a statement about how a connection is DRAWN, and
// every path that judges or optimises a layout has to agree on it —
// octilinear.ts (the pass that enforces it), pack.ts (measureLayout, so the
// UI and the bench can report it) and dev/layout-bench.mjs.
// ---------------------------------------------------------------------------

/**
 * Primitive cell-space steps a connection is allowed to run along, as
 * (dCol, dRow) with no common factor; both signs and the transpose of each
 * entry are implied.
 *
 * These are CELL steps, not screen angles, because the grid is not square
 * (180x75 px): a (1,1) step is drawn at atan(75/180) = 22.6 degrees, not 45.
 * What the eye groups by is repetition — a handful of directions used over
 * and over — so quantizing the step set is what buys readability. Chasing
 * literal 30/45/60 degree screen angles instead would require steps like
 * (2,5) or (1,4): five cells of horizontal run to raise a node by two, on a
 * map whose typical connection spans one or two cells. Almost no edge could
 * reach one, so almost nothing would snap.
 *
 * The set is EXPLICIT — (2,1) is deliberately not in it. Its screen angle is
 * 11.8 deg, close enough to horizontal that the eye reads it as a wonky
 * horizontal rather than as its own direction, which is exactly the "mash of
 * angles" look this pass exists to remove.
 *
 *   (1,0)  ->     0 deg   horizontal
 *   (0,1)  ->    90 deg   vertical
 *   (1,1)  -> +-22.6 deg  shallow diagonal
 *   (1,2)  -> +-39.8 deg  steep diagonal — this is "the 45" on this grid
 */
export const ANGLE_DIRECTIONS: ReadonlyArray<readonly [number, number]> = [
  [1, 0],
  [0, 1],
  [1, 1],
  [1, 2],
];

const gcd = (a: number, b: number): number => (b === 0 ? a : gcd(b, a % b));

/** True when the straight line from `a` to `b` runs along one of ANGLE_DIRECTIONS (at any length). */
export const isOnAngle = (a: CellCoord, b: CellCoord): boolean => {
  const dCol = Math.abs(b.col - a.col);
  const dRow = Math.abs(b.row - a.row);
  if (dCol === 0 && dRow === 0) return true;
  const divisor = gcd(Math.max(dCol, dRow), Math.min(dCol, dRow)) || 1;
  const col = dCol / divisor;
  const row = dRow / divisor;
  return ANGLE_DIRECTIONS.some(([dirCol, dirRow]) => col === dirCol && row === dirRow);
};

/** How many of `edges` are drawn at an angle outside ANGLE_DIRECTIONS. */
export const countOffAngleEdges = (
  edges: ReadonlyArray<{ source: string; target: string }>,
  cells: Map<string, CellCoord>,
): number => {
  let total = 0;
  for (const edge of edges) {
    if (edge.source === edge.target) continue;
    const a = cells.get(edge.source);
    const b = cells.get(edge.target);
    if (!a || !b) continue;
    if (!isOnAngle(a, b)) total++;
  }
  return total;
};
