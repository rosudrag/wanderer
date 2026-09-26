// CHEWY PATCH: new file. Angle discipline — the last pass over a laid-out
// map, which nudges nodes so that connections run along a SMALL FIXED SET of
// directions instead of whatever angle the geometry happened to produce.
//
// Why this is a readability win and not decoration: a viewer reads a diagram
// by grouping parallel lines. Forty edges at forty different angles give the
// eye nothing to group, so the map reads as noise even when it is objectively
// untangled (no crossings, no hidden links). Metro maps, circuit schematics
// and org charts all solve this the same way: quantize every line's direction
// (the classic term is an "octilinear" layout).
//
// WHICH directions, on THIS grid: the cell pitch is 180x75 px (CELL_W/CELL_H),
// so a cell-space direction of (1,1) is NOT drawn at 45 degrees — it is drawn
// at atan(75/180) = 22.6. The useful thing to quantize is therefore the set of
// cell-space steps, not the on-screen angle: the step set below renders as a
// handful of repeated, obviously-parallel screen angles, which is what the eye
// groups by. Targeting literal 30/45/60 degree screen angles instead would
// need steps like (2,5) or (1,4) — 5 cells of horizontal run to raise one
// node, on a map whose typical edge is 1-2 cells long. Unreachable for almost
// every edge, so almost nothing would snap.
//
// DIRECTIONS is the whole aesthetic, in one place:
//   (1,0)  ->    0 deg   horizontal
//   (0,1)  ->   90 deg   vertical
//   (1,1)  -> ±22.6 deg  shallow diagonal
//   (1,2)  -> ±39.8 deg  steep diagonal ("the 45")
// Anything else counts as off-angle and the pass tries to fix it.
//
// The pass is a strict improver: a move is accepted only when it lowers
// `violationScore*DEFECT_WEIGHT + offAngleEdges`, using the exact single-node
// delta from pack.ts's localViolationScore. So it can never trade a crossing
// or a hidden link for a prettier angle, the global score falls monotonically
// (=> it terminates), and re-running it on its own output changes nothing
// (=> beautify stays idempotent, which earlier passes learned the hard way).

import { ANGLE_DIRECTIONS, isOnAngle } from './geometry';
import { localViolationScore } from './pack';
import type { CellCoord } from './types';

interface AngleEdge {
  source: string;
  target: string;
}

/** Every signed step of ANGLE_DIRECTIONS, deduplicated, in a fixed order. */
const SIGNED_DIRECTIONS: ReadonlyArray<readonly [number, number]> = (() => {
  const seen = new Set<string>();
  const out: Array<[number, number]> = [];
  for (const [col, row] of ANGLE_DIRECTIONS) {
    for (const dCol of [col, -col]) {
      for (const dRow of [row, -row]) {
        if (dCol === 0 && dRow === 0) continue;
        const key = `${dCol},${dRow}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push([dCol, dRow]);
      }
    }
  }
  return out;
})();

/**
 * How far a node may end up from the cell the layout gave it, for the whole
 * pass (not per move). Same reasoning as pack.ts's MAX_NODE_DISPLACEMENT_CELLS:
 * angle discipline is a polish step, and a node that walks across the map to
 * square up one line has destroyed the structure it was polishing. 3 because
 * the longest primitive step is (1,2) and a node frequently has to clear its
 * own row/column to reach one; 2 was measured on the bench to leave a third
 * of the off-angle edges unsnapped and lose the crossing reductions (yugen 1
 * crossing at 3, 4 at 2).
 */
const MAX_ANGLE_DISPLACEMENT_CELLS = 3;

/**
 * Weight of one violation point (see pack.ts: a crossing is 1, a hidden
 * connection 1000) against one off-angle edge. 100 means no realistic number
 * of angle fixes can buy a single crossing: a node would have to square up 100
 * of its own edges at once.
 */
const DEFECT_WEIGHT = 100;

/** Sweeps over the whole node set; each one is a full pass in id order. Hit only by pathological inputs — real maps settle in 2-4. */
const MAX_SWEEPS = 200;

export interface AngleSnapOptions {
  /** Ids the pass may move. Locked/pinned nodes must be excluded by the caller. */
  movableIds: ReadonlySet<string>;
  /** Hard constraint on where a node may land (chain standoff — see BeautifyOptions.chainStandoff). */
  isCellAllowed?: (id: string, cell: CellCoord) => boolean;
  /**
   * The layout the user is looking at right now. Order is preserved against
   * THIS as well as against the live state: preserving it only against the
   * live state is not enough, because everything else in the pipeline is
   * moving at the same time, and two individually-legal moves still add up to
   * a swap the user sees (bench `occlusion` round-trip: a mean of 5.1
   * reordered pairs after adding one system, against a budget of 2).
   */
  referenceCells?: Map<string, CellCoord>;
}

interface Candidate {
  cell: CellCoord;
  cost: number;
  length: number;
  displacement: number;
}

/** Sum of the drawn length of the edges incident to `nodeId` — tie-break only, never an acceptance criterion (pack.ts's candidateCompare documents why). */
const incidentLength = (incident: AngleEdge[], cells: Map<string, CellCoord>, nodeId: string): number => {
  let total = 0;
  for (const edge of incident) {
    const otherId = edge.source === nodeId ? edge.target : edge.source;
    const a = cells.get(nodeId);
    const b = cells.get(otherId);
    if (!a || !b) continue;
    total += Math.hypot(a.col - b.col, a.row - b.row);
  }
  return total;
};

const offAngleIncident = (incident: AngleEdge[], cells: Map<string, CellCoord>, nodeId: string): number => {
  let total = 0;
  for (const edge of incident) {
    const otherId = edge.source === nodeId ? edge.target : edge.source;
    const a = cells.get(nodeId);
    const b = cells.get(otherId);
    if (!a || !b) continue;
    if (!isOnAngle(a, b)) total++;
  }
  return total;
};

/**
 * True when moving `nodeId` from `from` to `to` would flip its left/right or
 * above/below relationship with ANY other system on the map. Such a move is
 * refused outright, whatever it does for angles.
 *
 * This is the stability rule, and it is not optional: without it the pass was
 * a net loss on the bench's round-trip test (beautify, add k systems,
 * beautify again) — adding ONE system to the `occlusion` scenario reordered a
 * mean of 7 system pairs, against a budget of 2, because a 2-3 cell diagonal
 * nudge easily carries a node past a neighbour. A user navigates by "Amamake
 * is above Auga"; a prettier angle is not worth invalidating that.
 *
 * Becoming level (sign 0) is allowed — that is what snapping to a shared row
 * or column IS.
 */
const reordersMap = (
  cells: Map<string, CellCoord>,
  nodeId: string,
  from: CellCoord,
  to: CellCoord,
): boolean => {
  for (const [otherId, other] of cells) {
    if (otherId === nodeId) continue;
    const colBefore = Math.sign(from.col - other.col);
    const colAfter = Math.sign(to.col - other.col);
    if (colBefore !== 0 && colAfter !== 0 && colBefore !== colAfter) return true;
    const rowBefore = Math.sign(from.row - other.row);
    const rowAfter = Math.sign(to.row - other.row);
    if (rowBefore !== 0 && rowAfter !== 0 && rowBefore !== rowAfter) return true;
  }
  return false;
};

/**
 * Nudges nodes onto cells that put their connections on one of DIRECTIONS,
 * returning a new cell map. Never moves a node more than
 * MAX_ANGLE_DISPLACEMENT_CELLS from where it started, never onto an occupied
 * cell, never onto a cell `isCellAllowed` rejects, and never at the cost of a
 * crossing or a hidden connection.
 */
export const snapAngles = (
  cells: Map<string, CellCoord>,
  edges: AngleEdge[],
  options: AngleSnapOptions,
): Map<string, CellCoord> => {
  const { movableIds, isCellAllowed, referenceCells } = options;
  const result = new Map(cells);
  if (movableIds.size === 0 || edges.length === 0) return result;

  const incidentByNode = new Map<string, AngleEdge[]>();
  for (const edge of edges) {
    if (edge.source === edge.target) continue;
    if (!result.has(edge.source) || !result.has(edge.target)) continue;
    for (const id of [edge.source, edge.target]) {
      const list = incidentByNode.get(id);
      if (list) list.push(edge);
      else incidentByNode.set(id, [edge]);
    }
  }

  const key = (cell: CellCoord): string => `${cell.col},${cell.row}`;
  const occupied = new Set<string>();
  for (const cell of result.values()) occupied.add(key(cell));

  const origin = new Map(result);
  // Fixed order, and only nodes that actually have an edge to straighten.
  const order = [...movableIds].filter(id => incidentByNode.has(id)).sort();

  for (let sweep = 0; sweep < MAX_SWEEPS; sweep++) {
    let accepted = 0;

    for (const id of order) {
      const incident = incidentByNode.get(id)!;
      const from = result.get(id)!;
      const start = origin.get(id)!;

      const baseCost = localViolationScore(edges, result, id) * DEFECT_WEIGHT + offAngleIncident(incident, result, id);
      if (baseCost === 0) continue;

      // Candidate cells: for every neighbour and every allowed direction, the
      // cells that put THAT edge on angle, at a length close to the one it
      // already has. This is a tiny, targeted set (deg * 20 * 3) — searching a
      // disc of cells instead would be ~50x the work for candidates that are
      // mostly off-angle anyway.
      const seen = new Set<string>();
      let best: Candidate | null = null;

      for (const edge of incident) {
        const otherId = edge.source === id ? edge.target : edge.source;
        const anchor = result.get(otherId);
        if (!anchor) continue;
        const span = Math.max(Math.abs(from.col - anchor.col), Math.abs(from.row - anchor.row));

        for (const [dCol, dRow] of SIGNED_DIRECTIONS) {
          const maxSteps = Math.max(1, span + 1);
          for (let steps = 1; steps <= maxSteps; steps++) {
            const cell: CellCoord = { col: anchor.col + dCol * steps, row: anchor.row + dRow * steps };
            const cellKey = key(cell);
            if (cellKey === key(from)) continue;
            if (seen.has(cellKey)) continue;
            seen.add(cellKey);
            if (occupied.has(cellKey)) continue;
            const displacement = Math.hypot(cell.col - start.col, cell.row - start.row);
            if (displacement > MAX_ANGLE_DISPLACEMENT_CELLS) continue;
            if (isCellAllowed && !isCellAllowed(id, cell)) continue;
            if (reordersMap(result, id, from, cell)) continue;
            const reference = referenceCells?.get(id);
            if (reference && reordersMap(referenceCells!, id, reference, cell)) continue;

            result.set(id, cell);
            const cost =
              localViolationScore(edges, result, id) * DEFECT_WEIGHT + offAngleIncident(incident, result, id);
            const length = incidentLength(incident, result, id);
            result.set(id, from);

            if (cost >= baseCost) continue;
            if (
              best === null ||
              cost < best.cost ||
              (cost === best.cost && length < best.length) ||
              (cost === best.cost && length === best.length && displacement < best.displacement)
            ) {
              best = { cell, cost, length, displacement };
            }
          }
        }
      }

      if (!best) continue;

      occupied.delete(key(from));
      occupied.add(key(best.cell));
      result.set(id, best.cell);
      accepted++;
    }

    if (accepted === 0) break;
  }

  return result;
};
