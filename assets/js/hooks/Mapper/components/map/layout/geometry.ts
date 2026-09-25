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
