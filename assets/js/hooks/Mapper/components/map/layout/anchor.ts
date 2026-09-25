// CHEWY PATCH: incremental beautify — the architectural fix for map
// reshuffling (see index.ts's `mode` doc for the full contract).
//
// Full re-solve (kspaceLayout.ts / chainLayout.ts / pack.ts) recomputes
// EVERY node's cell from the whole graph on every call. That is exactly
// what makes it produce a tight, crossing-free layout — and exactly what
// makes it unstable once a map is already laid out and only gains a
// system or two: kspaceLayout.ts's own header proves a dense
// neighbourhood's members are a function of every other member's
// position by construction, so no amount of threshold tuning inside
// "re-derive everything" can keep a genuinely tight cluster stable under
// insertion (measured directly: yugen's real 15-system core still moved
// ~85%+ of the map per insertion after that tuning work landed).
//
// This module never re-derives an existing, validly-placed node's cell.
// It only decides (classifyNodes) whether each node already sits on a
// trustworthy cell, and (placeIncrementalNodes) works out where to drop
// the ones that don't, anchored to their nearest already-placed neighbour
// — never touching anyone else.

import { getGlobalSystemCell } from './regionData';
import type { RegionLayoutData } from './regionData';
import { CELL_H, CELL_W } from './types';
import type { BeautifyAxis, CellCoord, LayoutEdgeInput, LayoutNodeInput } from './types';

// ---------------------------------------------------------------------------
// Whole-map "auto" decision threshold
// ---------------------------------------------------------------------------

/**
 * `auto` resolves to `incremental` once at least this fraction of the
 * (unlocked) nodes are already validly placed per `classifyNodes`. 0.5 is a
 * plain majority: even the smallest realistic growth step (one existing
 * node gaining a single new neighbour, i.e. 1 new node in an N-node map)
 * clears it for any N >= 2, while a map where HALF or more of the nodes are
 * new/misplaced — the hallmark of a first-ever beautify or a bulk import —
 * correctly falls back to `full`, which is what actually produces a decent
 * layout from scratch.
 */
export const INCREMENTAL_VALID_FRACTION_THRESHOLD = 0.5;

// ---------------------------------------------------------------------------
// Classification — is a node already validly placed?
// ---------------------------------------------------------------------------

export interface NodeClassification {
  /** node id -> current cell, for every unlocked node considered ALREADY validly placed (never touched). */
  validCells: Map<string, CellCoord>;
  /** unlocked node ids that are new or currently invalid and need placement. */
  toPlace: string[];
}

const cellOf = (node: LayoutNodeInput): CellCoord => ({
  col: Math.round(node.x / CELL_W),
  row: Math.round(node.y / CELL_H),
});

const isOnGrid = (node: LayoutNodeInput): boolean =>
  Number.isInteger(node.x / CELL_W) && Number.isInteger(node.y / CELL_H);

const cellKey = (c: CellCoord): string => `${c.col},${c.row}`;

/**
 * A node is already validly placed iff:
 *  1. its position is an EXACT multiple of the cell grid — the one thing
 *     every position that has ever gone through this engine, or the app's
 *     own manual-placement snapping (map_position_calculator.ex), always
 *     satisfies; a node "just dropped" at an arbitrary discovery pixel
 *     never is;
 *  2. no other node (on-grid or locked) occupies the same cell;
 *  3. if it's an ESTABLISHED k-space cluster member (see ESTABLISHED
 *     below) with a GLOBAL lattice entry, its left/right and above/below
 *     order against every OTHER on-grid, ESTABLISHED lattice member
 *     agrees with the real lattice order — zero rank inversions beyond
 *     MAX_TOLERATED_INVERSIONS, using the exact "both signs nonzero and
 *     different" flip definition dev/layout-bench.mjs's own
 *     rankInversionCount uses, not merely "close enough". A k-space
 *     member that ISN'T established yet (see below) skips this check
 *     entirely and is judged on 1-2 alone — a one-cycle grace period, not
 *     a free pass forever (see ESTABLISHED).
 * Locked nodes are ground truth: they're never classified (a caller never
 * needs to place or keep them — they're excluded from output entirely,
 * exactly like every other layout box in this engine already treats them)
 * but they DO occupy their cell for everyone else's collision check.
 *
 * CHEWY PATCH: ESTABLISHED gate + one-cycle grace period. A k-space
 * member only enters the lattice-order check — as a judge (comparison
 * evidence against its peers) or as a defendant (its own order judged) —
 * once it has at least one gate-edge neighbour that is itself already
 * on-grid and non-colliding. Without this, a node that has spent this
 * whole map's life as a wormhole-chain attachment (positioned by
 * chainLayout.ts's tree math, which has zero relationship to the
 * geographic lattice) starts counting as "already validly placed
 * k-space" the INSTANT it gains a single new, still-unplaced gate
 * neighbour — its own chain-derived cell then gets compared against the
 * real lattice order of every genuinely-established member, and because
 * that cell has no geographic meaning at all, it racks up a near-maximal
 * inversion count against essentially everyone. The symmetric "condemns
 * both" rule then drags otherwise-perfect, topologically-unrelated core
 * members over MAX_TOLERATED_INVERSIONS too — measured directly on yugen
 * (dev/_diag_throwaway.mjs, deleted): inserting one new gate neighbour
 * onto chain-positioned system 30000070 alone pushed genuinely-untouched
 * core members 30002092/30002537 from their normal baseline of exactly 3
 * inversions (right at the tolerance ceiling, per the comment below) up
 * to 5 — tipping them from valid to invalid though their relative order
 * with every OTHER core member never changed. Across repeats this was
 * the entire cause of yugen's auto fallback to 'full' (validFraction
 * dropping under the 0.5 threshold).
 *
 * A not-yet-established member is judged ONLY on 1 (on-grid) and 2
 * (non-colliding) — it is NOT forced into `toPlace` just for lacking an
 * established neighbour, and it is NOT re-derived. It keeps whatever
 * position it already validly held (this module's whole reason to exist:
 * never re-derive an existing, validly-placed node's cell). The freshly
 * ATTACHED node (still off-grid, always in `toPlace`) is what gets
 * anchored near it instead — see placeLatticeNode. This is deliberately a
 * grace period, not a permanent exemption: the moment that new neighbour
 * itself gets placed (this call or a later one) it becomes on-grid, so
 * the previously-unestablished member becomes established and its order
 * gets judged for real on the NEXT beautify — one connection reshuffling
 * the map immediately, before the map has had a chance to settle around
 * it, was the actual measured cause of yugen's residual incremental-mode
 * movement (rankInv up to 15 from a single reclassified node jumping
 * across the map to its "ideal" lattice-anchored cell) even on repeats
 * that already correctly resolved 'incremental'.
 */
export const classifyNodes = (
  nodes: LayoutNodeInput[],
  gateEdges: LayoutEdgeInput[],
  kspaceMemberIds: ReadonlySet<string>,
  regionData: RegionLayoutData | null,
): NodeClassification => {
  const nodeById = new Map(nodes.map(n => [n.id, n]));

  // Collision check over every node (locked or on-grid unlocked) that
  // claims an exact cell; only unlocked occupants of a shared cell are
  // marked invalid — a locked node is ground truth and never re-judged.
  const cellGroups = new Map<string, string[]>();
  for (const n of nodes) {
    if (!n.locked && !isOnGrid(n)) continue;
    const key = cellKey(cellOf(n));
    const list = cellGroups.get(key);
    if (list) list.push(n.id);
    else cellGroups.set(key, [n.id]);
  }
  const collidingIds = new Set<string>();
  for (const ids of cellGroups.values()) {
    if (ids.length <= 1) continue;
    for (const id of ids) {
      if (!nodeById.get(id)!.locked) collidingIds.add(id);
    }
  }

  // on-grid, non-colliding node ids — the pool ESTABLISHED-ness and
  // lattice candidacy both draw from.
  const placedIds = new Set<string>();
  for (const n of nodes) {
    if (!collidingIds.has(n.id) && isOnGrid(n)) placedIds.add(n.id);
  }
  // ESTABLISHED: a k-space member with >=1 gate-edge neighbour that is
  // itself already placed — see the CHEWY PATCH doc above for why this
  // gate exists. Locked neighbours count too (they occupy a real,
  // trustworthy cell even though they're never classified themselves).
  const establishedIds = new Set<string>();
  for (const e of gateEdges) {
    if (placedIds.has(e.source) && (placedIds.has(e.target) || nodeById.get(e.target)?.locked)) {
      establishedIds.add(e.source);
    }
    if (placedIds.has(e.target) && (placedIds.has(e.source) || nodeById.get(e.source)?.locked)) {
      establishedIds.add(e.target);
    }
  }

  // Rank-order check, restricted to on-grid, non-colliding, unlocked,
  // ESTABLISHED k-space members with a GLOBAL lattice entry. A genuine
  // order conflict between two otherwise-fine candidates condemns both —
  // neither's position can be trusted without knowing which one is
  // actually wrong.
  const latticeCandidates: Array<{ id: string; cell: CellCoord; lattice: CellCoord }> = [];
  if (regionData) {
    for (const n of nodes) {
      if (n.locked || collidingIds.has(n.id) || !isOnGrid(n) || !kspaceMemberIds.has(n.id) || !establishedIds.has(n.id))
        continue;
      const lattice = getGlobalSystemCell(regionData, n.id);
      if (lattice) latticeCandidates.push({ id: n.id, cell: cellOf(n), lattice });
    }
  }
  // CHEWY PATCH: tolerate up to MAX_TOLERATED_INVERSIONS per node rather
  // than zero — pack.ts's own resolveCollisions (kspaceLayout.ts) can
  // legitimately push a colliding member rightward past a neighbour with a
  // slightly larger lattice column to resolve a shared cell (documented
  // there as safe for stability, not for global order), so even a FRESH,
  // genuinely good full-mode layout of a dense real cluster (yugen's own
  // 12-system core) can carry a handful of such residual inversions.
  // Demanding zero would make classifyNodes reject its own engine's best
  // output as "not laid out", defeating incremental mode for exactly the
  // dense maps that need it most.
  //
  // 3 was picked by direct measurement, not guessed: laying out yugen's
  // real seed.ex data once (full mode) and counting each k-space member's
  // own inversions against the raw lattice gives a max of 3 (the two
  // members resolveCollisions actually pushed); every other member sits
  // at 0-2. The SAME map's raw, never-beautified input (what auto must
  // keep rejecting) gives a max of 9 and only 3 of 12 members at <=3 —
  // nowhere near enough to cross classifyNodes' whole-map valid-fraction
  // threshold. 3 is therefore the smallest tolerance that accepts a
  // genuine full-mode output wholesale while still rejecting raw input.
  // Still 3 with the ESTABLISHED gate above — that gate never touches the
  // 12-core's own baseline (every member already has multiple established
  // gate neighbours), it only stops an unrelated unestablished outlier
  // from inflating it.
  const MAX_TOLERATED_INVERSIONS = 3;
  const inversionCount = new Map<string, number>();
  for (let i = 0; i < latticeCandidates.length; i++) {
    for (let j = i + 1; j < latticeCandidates.length; j++) {
      const a = latticeCandidates[i];
      const b = latticeCandidates[j];
      const sx1 = Math.sign(a.cell.col - b.cell.col);
      const sx2 = Math.sign(a.lattice.col - b.lattice.col);
      const sy1 = Math.sign(a.cell.row - b.cell.row);
      const sy2 = Math.sign(a.lattice.row - b.lattice.row);
      const xFlip = sx1 !== 0 && sx2 !== 0 && sx1 !== sx2;
      const yFlip = sy1 !== 0 && sy2 !== 0 && sy1 !== sy2;
      if (xFlip || yFlip) {
        inversionCount.set(a.id, (inversionCount.get(a.id) ?? 0) + 1);
        inversionCount.set(b.id, (inversionCount.get(b.id) ?? 0) + 1);
      }
    }
  }
  const invertedIds = new Set(
    [...inversionCount.entries()].filter(([, count]) => count > MAX_TOLERATED_INVERSIONS).map(([id]) => id),
  );

  const validCells = new Map<string, CellCoord>();
  const toPlace: string[] = [];
  for (const n of nodes) {
    if (n.locked) continue;
    const valid = isOnGrid(n) && !collidingIds.has(n.id) && !invertedIds.has(n.id);
    if (valid) validCells.set(n.id, cellOf(n));
    else toPlace.push(n.id);
  }
  return { validCells, toPlace };
};

// ---------------------------------------------------------------------------
// Placement — where does a new/invalid node go, without touching anyone else?
// ---------------------------------------------------------------------------

/** Deterministic expanding-ring search for the nearest free cell to `target` (Euclidean distance, then column, then row for reproducible ties). */
const nearestFreeCell = (target: CellCoord, occupied: ReadonlySet<string>): CellCoord => {
  if (!occupied.has(cellKey(target))) return target;
  for (let radius = 1; radius <= 4000; radius++) {
    let best: CellCoord | null = null;
    let bestDist = Infinity;
    for (let dCol = -radius; dCol <= radius; dCol++) {
      for (let dRow = -radius; dRow <= radius; dRow++) {
        if (Math.max(Math.abs(dCol), Math.abs(dRow)) !== radius) continue; // only this ring
        const candidate: CellCoord = { col: target.col + dCol, row: target.row + dRow };
        if (occupied.has(cellKey(candidate))) continue;
        const dist = Math.hypot(dCol, dRow);
        const better =
          dist < bestDist ||
          (dist === bestDist &&
            best !== null &&
            (candidate.col < best.col || (candidate.col === best.col && candidate.row < best.row)));
        if (better || best === null) {
          best = candidate;
          bestDist = dist;
        }
      }
    }
    if (best) return best;
  }
  return target; // unreachable in practice (radius 4000 covers any real map)
};

const buildAdjacency = (edges: LayoutEdgeInput[]): Map<string, string[]> => {
  const adj = new Map<string, string[]>();
  for (const e of edges) {
    if (!adj.has(e.source)) adj.set(e.source, []);
    if (!adj.has(e.target)) adj.set(e.target, []);
    adj.get(e.source)!.push(e.target);
    adj.get(e.target)!.push(e.source);
  }
  return adj;
};

interface PlacementCtx {
  /** node id -> cell, for every node placed so far (originally-valid plus everything placed earlier in this same pass). */
  cells: Map<string, CellCoord>;
  occupied: Set<string>;
}

const commit = (ctx: PlacementCtx, id: string, cell: CellCoord): void => {
  ctx.cells.set(id, cell);
  ctx.occupied.add(cellKey(cell));
};

/**
 * K-space node with a GLOBAL lattice cell: anchored to its nearest
 * ALREADY-PLACED lattice neighbour (by real lattice distance — exactly how
 * a new system's gate edge always runs to its nearest not-yet-used lattice
 * neighbour, see dev/layout-bench.mjs's own extendGraph), one cell further
 * out in the same left/right + above/below direction that neighbour is
 * from this node on the lattice, landed on the nearest free cell. Falls
 * back to the node's own current pixel (rounded) if no other lattice
 * member has been placed yet — there is nothing to order against.
 */
const placeLatticeNode = (
  node: LayoutNodeInput,
  lattice: CellCoord,
  latticeById: ReadonlyMap<string, CellCoord>,
  ctx: PlacementCtx,
): CellCoord => {
  let anchorId: string | null = null;
  let bestDist = Infinity;
  for (const [id, otherLattice] of latticeById) {
    if (!ctx.cells.has(id)) continue;
    const d = Math.hypot(otherLattice.col - lattice.col, otherLattice.row - lattice.row);
    if (d < bestDist || (d === bestDist && (anchorId === null || id < anchorId))) {
      bestDist = d;
      anchorId = id;
    }
  }
  if (anchorId === null) {
    return nearestFreeCell({ col: Math.round(node.x / CELL_W), row: Math.round(node.y / CELL_H) }, ctx.occupied);
  }
  const anchorCell = ctx.cells.get(anchorId)!;
  const anchorLattice = latticeById.get(anchorId)!;
  const dCol = Math.sign(lattice.col - anchorLattice.col);
  const dRow = Math.sign(lattice.row - anchorLattice.row);
  const ideal: CellCoord = { col: anchorCell.col + dCol, row: anchorCell.row + dRow };
  return nearestFreeCell(ideal, ctx.occupied);
};

/**
 * Wormhole/chain (or lattice-less gate) node: anchored to its nearest
 * ALREADY-PLACED neighbour via `adjacency`, one cell further out in the
 * direction that neighbour's own established neighbour extends from it
 * (i.e. keep growing the branch the same way it's already growing);
 * defaults to the primary layout axis if the neighbour has no established
 * direction of its own (it's a lone anchor, e.g. a fresh attachment point).
 */
const placeAdjacentNode = (
  nodeId: string,
  neighbourIds: readonly string[],
  adjacency: ReadonlyMap<string, string[]>,
  axis: BeautifyAxis,
  ctx: PlacementCtx,
): CellCoord => {
  const neighbourId = [...neighbourIds].sort()[0];
  const neighbourCell = ctx.cells.get(neighbourId)!;
  const grandparentId = (adjacency.get(neighbourId) ?? []).filter(id => id !== nodeId && ctx.cells.has(id)).sort()[0];

  let dCol: number;
  let dRow: number;
  const grandparentCell = grandparentId ? ctx.cells.get(grandparentId) : undefined;
  if (grandparentCell) {
    dCol = Math.sign(neighbourCell.col - grandparentCell.col);
    dRow = Math.sign(neighbourCell.row - grandparentCell.row);
  } else {
    dCol = 0;
    dRow = 0;
  }
  if (dCol === 0 && dRow === 0) {
    dCol = axis === 'left_to_right' ? 1 : 0;
    dRow = axis === 'top_to_bottom' ? 1 : 0;
  }
  const ideal: CellCoord = { col: neighbourCell.col + dCol, row: neighbourCell.row + dRow };
  return nearestFreeCell(ideal, ctx.occupied);
};

export interface IncrementalLayoutResult {
  positions: Record<string, { x: number; y: number }>;
  movedCount: number;
}

/**
 * Places every node in `classification.toPlace`, keeping every node in
 * `classification.validCells` exactly where it is (they never appear in
 * `positions`). See classifyNodes for what "valid" means and the module
 * header for why this never re-derives an already-good node's cell.
 */
export const placeIncrementalNodes = (
  nodes: LayoutNodeInput[],
  gateEdges: LayoutEdgeInput[],
  chainEdges: LayoutEdgeInput[],
  kspaceMemberIds: ReadonlySet<string>,
  regionData: RegionLayoutData | null,
  axis: BeautifyAxis,
  classification: NodeClassification,
): IncrementalLayoutResult => {
  const nodeById = new Map(nodes.map(n => [n.id, n]));
  const chainAdj = buildAdjacency(chainEdges);
  const gateAdj = buildAdjacency(gateEdges);

  const latticeById = new Map<string, CellCoord>();
  if (regionData) {
    for (const id of kspaceMemberIds) {
      const cell = getGlobalSystemCell(regionData, id);
      if (cell) latticeById.set(id, cell);
    }
  }

  const ctx: PlacementCtx = { cells: new Map(classification.validCells), occupied: new Set() };
  for (const cell of ctx.cells.values()) ctx.occupied.add(cellKey(cell));
  // Locked nodes are pinned ground truth: never placed, but their cell is
  // off-limits to everyone else.
  for (const n of nodes) {
    if (n.locked) ctx.occupied.add(cellKey({ col: Math.round(n.x / CELL_W), row: Math.round(n.y / CELL_H) }));
  }

  const positions: Record<string, { x: number; y: number }> = {};
  let movedCount = 0;

  // Fixed, deterministic processing order. A node placed earlier in this
  // same pass is immediately available as an anchor/neighbour for a later
  // one (e.g. two new systems chained onto each other), so single-pass
  // alphabetical order is enough — it never stalls (every case below has
  // an unconditional fallback) and never depends on Map/Set iteration order.
  for (const id of [...classification.toPlace].sort()) {
    const node = nodeById.get(id)!;

    const lattice = latticeById.get(id);
    let target: CellCoord;
    if (lattice) {
      target = placeLatticeNode(node, lattice, latticeById, ctx);
    } else {
      const viaChain = (chainAdj.get(id) ?? []).filter(n2 => ctx.cells.has(n2));
      const viaGate = (gateAdj.get(id) ?? []).filter(n2 => ctx.cells.has(n2));
      if (viaChain.length > 0) {
        target = placeAdjacentNode(id, viaChain, chainAdj, axis, ctx);
      } else if (viaGate.length > 0) {
        target = placeAdjacentNode(id, viaGate, gateAdj, axis, ctx);
      } else {
        target = nearestFreeCell({ col: Math.round(node.x / CELL_W), row: Math.round(node.y / CELL_H) }, ctx.occupied);
      }
    }

    commit(ctx, id, target);
    positions[id] = { x: target.col * CELL_W, y: target.row * CELL_H };
    movedCount += 1;
  }

  return { positions, movedCount };
};
