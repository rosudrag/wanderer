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
import { segmentHitsNodeBox } from './geometry';
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
 *     a free pass forever (see ESTABLISHED);
 *  4. CHEWY PATCH: it does not sit ON another connection's line — i.e. it
 *     doesn't `nodeOccludesEdge` any gate or chain edge it isn't itself an
 *     endpoint of (see the Placement section's geometry predicates below
 *     for the exact rule and why this alone also catches every genuine
 *     edge-overlap pair: if two edges collinearly overlap by more than a
 *     point, at least one of them's endpoints necessarily sits strictly
 *     inside the other's span). Unlike 3, this applies unconditionally —
 *     no ESTABLISHED gate, no grace period — because occlusion is a
 *     purely geometric fact, not a lattice-order judgement call: a node
 *     sitting on top of a connection hides it right now regardless of
 *     whether its neighbours are "established". This is exactly how
 *     production map "yugen" got a real, live system (Raihbaka) sitting
 *     precisely on another connection's line with its own edge fully
 *     swallowed by that same line — copied straight off the live database
 *     row, on-grid, non-colliding, yet clearly wrong. Without this check
 *     such a node reads as "already validly placed" and is never even
 *     offered to placeIncrementalNodes, so pickPlacementCell's clean-cell
 *     search (see below) never gets a chance to rescue it.
 * Locked nodes are ground truth: they're never classified (a caller never
 * needs to place or keep them — they're excluded from output entirely,
 * exactly like every other layout box in this engine already treats them)
 * but they DO occupy their cell, and participate in edge geometry, for
 * everyone else's checks.
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
  chainEdges: LayoutEdgeInput[],
  kspaceMemberIds: ReadonlySet<string>,
  regionData: RegionLayoutData | null,
  /** CHEWY PATCH: see BeautifyOptions.chainStandoff — 0 keeps upstream validity rules exactly. */
  chainStandoff = 0,
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

  // CHEWY PATCH: rule 4 above — a node occluding a connection it isn't an
  // endpoint of is never "already validly placed", ESTABLISHED or not.
  // Uses each node's EXACT pixel-derived cell (not the rounded `cellOf`
  // above): occlusion is a real, rendered-geometry fact, and a locked
  // node's edge can be genuinely off-grid.
  const exactCellOf = (n: LayoutNodeInput): CellCoord => ({ col: n.x / CELL_W, row: n.y / CELL_H });
  const occludingIds = new Set<string>();
  for (const e of [...gateEdges, ...chainEdges]) {
    const source = nodeById.get(e.source);
    const target = nodeById.get(e.target);
    if (!source || !target) continue;
    const a = exactCellOf(source);
    const b = exactCellOf(target);
    for (const n of nodes) {
      if (n.id === e.source || n.id === e.target || occludingIds.has(n.id)) continue;
      if (nodeOccludesEdge(exactCellOf(n), a, b)) occludingIds.add(n.id);
    }
  }

  // CHEWY PATCH (chain standoff): a wormhole-chain system sitting inside the
  // k-space lattice is not "validly placed" either. Without this rule the
  // incremental path — which is what the sparkles button actually runs on a
  // map that is already laid out — left every existing chain exactly where it
  // was, so turning the feature on only affected brand-new systems and full
  // re-solves (measured on live yugen: auto mode kept every chain 1 cell from
  // the lattice while a full re-solve moved them out to 2).
  const crowdedIds = new Set<string>();
  if (chainStandoff > 0) {
    const latticeCells: CellCoord[] = [];
    for (const n of nodes) {
      if (kspaceMemberIds.has(n.id)) latticeCells.push(cellOf(n));
    }
    for (const n of nodes) {
      if (n.locked || kspaceMemberIds.has(n.id)) continue;
      const cell = cellOf(n);
      for (const lattice of latticeCells) {
        const distance = Math.max(Math.abs(cell.col - lattice.col), Math.abs(cell.row - lattice.row));
        if (distance < chainStandoff) {
          crowdedIds.add(n.id);
          break;
        }
      }
    }
  }

  const validCells = new Map<string, CellCoord>();
  const toPlace: string[] = [];
  for (const n of nodes) {
    if (n.locked) continue;
    const valid =
      isOnGrid(n) &&
      !collidingIds.has(n.id) &&
      !invertedIds.has(n.id) &&
      !occludingIds.has(n.id) &&
      !crowdedIds.has(n.id);
    if (valid) validCells.set(n.id, cellOf(n));
    else toPlace.push(n.id);
  }
  return { validCells, toPlace };
};

// ---------------------------------------------------------------------------
// Placement — where does a new/invalid node go, without touching anyone else?
// ---------------------------------------------------------------------------

/** Deterministic expanding-ring search for the nearest cell satisfying `isAcceptable`, starting at `target` itself (Euclidean distance, then column, then row for reproducible ties). Returns null when nothing within `maxRadius` rings qualifies. */
const nearestAcceptableCell = (
  target: CellCoord,
  isAcceptable: (cell: CellCoord) => boolean,
  maxRadius: number,
): CellCoord | null => {
  if (isAcceptable(target)) return target;
  for (let radius = 1; radius <= maxRadius; radius++) {
    let best: CellCoord | null = null;
    let bestDist = Infinity;
    for (let dCol = -radius; dCol <= radius; dCol++) {
      for (let dRow = -radius; dRow <= radius; dRow++) {
        if (Math.max(Math.abs(dCol), Math.abs(dRow)) !== radius) continue; // only this ring
        const candidate: CellCoord = { col: target.col + dCol, row: target.row + dRow };
        if (!isAcceptable(candidate)) continue;
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
  return null;
};

// ---------------------------------------------------------------------------
// CHEWY PATCH: the two geometry predicates this task exists to enforce.
// Both operate in CELL space (col, row) = (x / CELL_W, y / CELL_H) — exact
// integers for every candidate/committed/valid cell, floating point for a
// locked node's real (possibly off-grid) position. dev/layout-bench.mjs's
// new `occlusion` scenario and pack.ts implement the same two rules
// independently for their own paths; all three MUST agree on the rules
// themselves (see the ticket), which is exactly what's written out below.
// ---------------------------------------------------------------------------

const GEOMETRY_EPS = 1e-6;

/** True when a, b, c are collinear in cell space (cross-product test). */
const cellsCollinear = (a: CellCoord, b: CellCoord, c: CellCoord): boolean =>
  Math.abs((b.col - a.col) * (c.row - a.row) - (b.row - a.row) * (c.col - a.col)) < GEOMETRY_EPS;

const isSameCell = (a: CellCoord, b: CellCoord): boolean =>
  Math.abs(a.col - b.col) < GEOMETRY_EPS && Math.abs(a.row - b.row) < GEOMETRY_EPS;

/**
 * Node-occlusion rule: `node` occludes edge [a,b] when the drawn line passes
 * under its rendered box but it is NOT one of the edge's own two endpoints —
 * touching an endpoint means it IS one of that edge's own systems, which is
 * fine; anything else hides part of the connection (the yugen defect:
 * Raihbaka on Ibani->Irmalin).
 *
 * CHEWY PATCH: the test is the node's BOX, not its cell centre — see
 * ./geometry.ts for why (the point rule scored the live yugen map as
 * occlusion-free while six connections ran under a node box) and for the one
 * shared implementation that pack.ts and dev/layout-bench.mjs also use.
 */
const nodeOccludesEdge = (node: CellCoord, a: CellCoord, b: CellCoord): boolean =>
  !isSameCell(node, a) && !isSameCell(node, b) && segmentHitsNodeBox(a, b, node);

/**
 * Edge-overlap rule: two edges overlap when they are COLLINEAR (every
 * endpoint on the same line) AND their 1-D projections along that line
 * share MORE than a single point — two edges that merely touch at a
 * shared endpoint, at any angle (including running the same direction
 * from it, as long as they don't share any further stretch beyond that
 * one point), are fine; lying along the same line and sharing any
 * positive-length stretch is not (the yugen defect: Ibani->Raihbaka fully
 * inside Ibani->Irmalin).
 */
const edgesOverlap = (a1: CellCoord, b1: CellCoord, a2: CellCoord, b2: CellCoord): boolean => {
  if (isSameCell(a1, b1) || isSameCell(a2, b2)) return false; // degenerate edge can't overlap anything
  if (!cellsCollinear(a1, b1, a2) || !cellsCollinear(a1, b1, b2)) return false;
  // Project onto whichever axis edge1 spreads more along — avoids
  // collapsing a purely-vertical or purely-horizontal line to one point.
  const useCol = Math.abs(b1.col - a1.col) >= Math.abs(b1.row - a1.row);
  const project = (p: CellCoord): number => (useCol ? p.col : p.row);
  const lo1 = Math.min(project(a1), project(b1));
  const hi1 = Math.max(project(a1), project(b1));
  const lo2 = Math.min(project(a2), project(b2));
  const hi2 = Math.max(project(a2), project(b2));
  return Math.min(hi1, hi2) - Math.max(lo1, lo2) > GEOMETRY_EPS;
};

/**
 * How far outward pickPlacementCell (below) widens its search for a CLEAN
 * cell before giving up and falling back to the nearest merely-free cell
 * (radius 4000, "any real map"). Every real placement branch's `ideal`
 * target is one cell from an already-placed anchor, so a genuinely clean
 * alternative — if the local neighbourhood has one at all — is found
 * within a handful of rings in practice; 256 is generous headroom for a
 * dense cluster while staying trivially cheap (worst case a few hundred
 * thousand candidate checks, sub-millisecond for the graph sizes this
 * engine ever sees).
 */
const CLEAN_SEARCH_RADIUS = 256;

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
  // CHEWY PATCH: fixed for the whole placeIncrementalNodes call — geometry
  // inputs pickPlacementCell needs to keep a newly placed node from ever
  // hiding, or being hidden behind, an existing connection (see its own
  // header below). `allEdges` is gate + chain together: the overlap rule
  // cares about ANY two collinear edges regardless of connection type
  // (the yugen defect this task fixes is a gate edge swallowing a
  // wormhole edge). `lockedPositions` uses each locked node's EXACT
  // (possibly off-grid) pixel-derived cell, never rounded — a locked
  // node's real edge geometry must be judged on its real position.
  gateAdj: ReadonlyMap<string, string[]>;
  chainAdj: ReadonlyMap<string, string[]>;
  allEdges: readonly LayoutEdgeInput[];
  lockedPositions: ReadonlyMap<string, CellCoord>;
  /**
   * CHEWY PATCH: hard "this node may not go here" filter, used for chain
   * standoff — otherwise the nearest-acceptable-cell search happily walks a
   * chain system back toward the lattice when its ideal band cell is taken
   * (measured on live yugen: J165815 ended 1 cell from Ibani).
   */
  isCellAllowed?: (id: string, cell: CellCoord) => boolean;
}

const commit = (ctx: PlacementCtx, id: string, cell: CellCoord): void => {
  ctx.cells.set(id, cell);
  ctx.occupied.add(cellKey(cell));
};

/** `id`'s own cell if already committed this pass, else its cell if it's a locked ground-truth node — the two sources of a "real, trustworthy" position pickPlacementCell can build edge geometry from. */
const knownCellOf = (ctx: PlacementCtx, id: string): CellCoord | undefined =>
  ctx.cells.get(id) ?? ctx.lockedPositions.get(id);

/**
 * CHEWY PATCH: the actual fix. Every placement branch below used to hand
 * its `ideal` anchor cell straight to nearestFreeCell, whose only notion
 * of "free" was "no other node's cell" — exactly how yugen's Raihbaka
 * ended up sitting ON Ibani->Irmalin's line (node occlusion) with its own
 * Ibani->Raihbaka edge fully swallowed by that same line (edge overlap).
 * This widens the search: a candidate cell is acceptable only when it is
 * unoccupied AND placing `id` there introduces neither defect against any
 * OTHER node/edge with an already-known (committed-this-pass, valid, or
 * locked) position:
 *   - `id` itself must not land ON any existing edge (nodeOccludesEdge);
 *   - no existing node may end up ON one of `id`'s own new edges (one per
 *     already-known graph neighbour, gate or chain);
 *   - none of `id`'s new edges may collinearly overlap an existing edge,
 *     OR another of `id`'s own new edges (two edges sharing `id` as an
 *     endpoint but extending the same way past each other still hide one
 *     behind the other from that point on).
 * Widens outward up to CLEAN_SEARCH_RADIUS; if nothing within that radius
 * qualifies, falls back to the nearest merely-free cell — an imperfect
 * placement beats no placement — but a further CLEAN cell always wins
 * over a nearer dirty one, since the clean search exhausts its whole
 * radius before that fallback ever runs.
 */
const pickPlacementCell = (id: string, ideal: CellCoord, ctx: PlacementCtx): CellCoord => {
  const knownIds = new Set<string>([...ctx.cells.keys(), ...ctx.lockedPositions.keys()]);
  knownIds.delete(id);

  const knownEdges: Array<readonly [CellCoord, CellCoord]> = [];
  for (const e of ctx.allEdges) {
    if (e.source === id || e.target === id) continue;
    const a = knownCellOf(ctx, e.source);
    const b = knownCellOf(ctx, e.target);
    if (a && b) knownEdges.push([a, b]);
  }

  const neighbourEntries: Array<{ id: string; cell: CellCoord }> = [];
  const neighbourIdSet = new Set<string>([...(ctx.gateAdj.get(id) ?? []), ...(ctx.chainAdj.get(id) ?? [])]);
  for (const neighbourId of neighbourIdSet) {
    const cell = knownCellOf(ctx, neighbourId);
    if (cell) neighbourEntries.push({ id: neighbourId, cell });
  }

  const isClean = (candidate: CellCoord): boolean => {
    for (const [a, b] of knownEdges) {
      if (nodeOccludesEdge(candidate, a, b)) return false;
    }
    for (let i = 0; i < neighbourEntries.length; i++) {
      const neighbour = neighbourEntries[i];
      for (const otherId of knownIds) {
        if (otherId === neighbour.id) continue;
        if (nodeOccludesEdge(knownCellOf(ctx, otherId)!, candidate, neighbour.cell)) return false;
      }
      for (const [a, b] of knownEdges) {
        if (edgesOverlap(candidate, neighbour.cell, a, b)) return false;
      }
      for (let j = i + 1; j < neighbourEntries.length; j++) {
        if (edgesOverlap(candidate, neighbour.cell, candidate, neighbourEntries[j].cell)) return false;
      }
    }
    return true;
  };

  // CHEWY PATCH: `ctx.isCellAllowed` is a hard constraint (chain standoff), so
  // it gates BOTH the clean search and the "any free cell" fallback; only if
  // even that finds nothing does the ideal cell get used as-is.
  const allowed = (cell: CellCoord): boolean => !ctx.isCellAllowed || ctx.isCellAllowed(id, cell);
  const clean = nearestAcceptableCell(
    ideal,
    cell => !ctx.occupied.has(cellKey(cell)) && allowed(cell) && isClean(cell),
    CLEAN_SEARCH_RADIUS,
  );
  return (
    clean ??
    nearestAcceptableCell(ideal, cell => !ctx.occupied.has(cellKey(cell)) && allowed(cell), 4000) ??
    ideal
  );
};

/**
 * K-space node with a GLOBAL lattice cell: anchored to the nearest
 * ALREADY-PLACED, lattice-resolved neighbour — preferring an actual GRAPH
 * neighbour (`graphNeighbourIds`: gate or chain edge) over any other
 * lattice member, so the node lands next to the system it is actually
 * connected to rather than whichever already-placed member merely
 * happens to sit closest on the real-world lattice while sharing no edge
 * with it at all (the exact quality gap dev/layout-bench.mjs's
 * `newAnchorCells` metric is built to catch — see dev/layout-bench.README.md).
 * Only when none of its own graph neighbours are both placed AND
 * lattice-resolved does it fall back to the nearest ANY already-placed
 * lattice member (by real lattice distance — exactly how a new system's
 * gate edge usually runs to its nearest not-yet-used lattice neighbour,
 * see dev/layout-bench.mjs's own extendGraph). Either way, lands one cell
 * further out in the same left/right + above/below direction the anchor
 * is from this node on the lattice, on the nearest CLEAN free cell (see
 * pickPlacementCell).
 *
 * CHEWY PATCH: returns `null` — never a raw, unsnapped fallback — when no
 * already-placed lattice member exists anywhere yet, instead of reaching
 * straight for the node's own current pixel. Having a lattice entry used
 * to be a dead end of its own: a node with real lattice data but no
 * lattice-resolved anchor yet available NEVER got to try its plain graph
 * neighbours (gate/chain) before this, even when one of those was
 * already placed — the exact "fell through to the no-information-at-all
 * branch despite having a real neighbour" defect. The caller now tries
 * plain graph adjacency next, and only reaches its own snapped-to-current
 * -position fallback if that also comes up empty.
 */
const placeLatticeNode = (
  id: string,
  lattice: CellCoord,
  latticeById: ReadonlyMap<string, CellCoord>,
  graphNeighbourIds: readonly string[],
  ctx: PlacementCtx,
): CellCoord | null => {
  const nearestAnchor = (candidateIds: Iterable<string>): string | null => {
    let anchorId: string | null = null;
    let bestDist = Infinity;
    for (const candidateId of candidateIds) {
      const otherLattice = latticeById.get(candidateId);
      if (!otherLattice || !ctx.cells.has(candidateId)) continue;
      const d = Math.hypot(otherLattice.col - lattice.col, otherLattice.row - lattice.row);
      if (d < bestDist || (d === bestDist && (anchorId === null || candidateId < anchorId))) {
        bestDist = d;
        anchorId = candidateId;
      }
    }
    return anchorId;
  };

  const anchorId = nearestAnchor(graphNeighbourIds) ?? nearestAnchor(latticeById.keys());
  if (anchorId === null) return null;

  const anchorCell = ctx.cells.get(anchorId)!;
  const anchorLattice = latticeById.get(anchorId)!;
  const dCol = Math.sign(lattice.col - anchorLattice.col);
  const dRow = Math.sign(lattice.row - anchorLattice.row);
  const ideal: CellCoord = { col: anchorCell.col + dCol, row: anchorCell.row + dRow };
  return pickPlacementCell(id, ideal, ctx);
};

/**
 * Wormhole/chain (or lattice-less gate) node: anchored to its nearest
 * ALREADY-PLACED neighbour via `adjacency`, one cell further out in the
 * direction that neighbour's own established neighbour extends from it
 * (i.e. keep growing the branch the same way it's already growing);
 * defaults to the primary layout axis if the neighbour has no established
 * direction of its own (it's a lone anchor, e.g. a fresh attachment point).
 *
 * CHEWY PATCH: `standoff` adds that many extra cells when the neighbour is a
 * k-space system — a chain must not start inside the Dotlan-geometry lattice
 * the user navigates by (see BeautifyOptions.chainStandoff). It is deliberately
 * NOT applied chain-to-chain: inside a chain, adjacent hops are the readable
 * thing.
 */
const placeAdjacentNode = (
  nodeId: string,
  neighbourIds: readonly string[],
  adjacency: ReadonlyMap<string, string[]>,
  axis: BeautifyAxis,
  ctx: PlacementCtx,
  standoff: number,
  kspaceMemberIds: ReadonlySet<string>,
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
  const reach = kspaceMemberIds.has(neighbourId) && !kspaceMemberIds.has(nodeId) ? 1 + standoff : 1;
  const ideal: CellCoord = { col: neighbourCell.col + dCol * reach, row: neighbourCell.row + dRow * reach };
  return pickPlacementCell(nodeId, ideal, ctx);
};

/**
 * CHEWY PATCH: a chain node whose neighbour is a k-space system is placed OUT
 * past the lattice edge, in that neighbour's own column (row, for
 * top_to_bottom), `chainStandoff` cells clear of it — the incremental twin of
 * the band placement full mode does in layout/index.ts. Growing the chain
 * further from there is ordinary chain-to-chain adjacency, so only this first
 * hop needs the special case.
 */
const placeChainBandNode = (
  nodeId: string,
  neighbourCell: CellCoord,
  latticeCells: readonly CellCoord[],
  axis: BeautifyAxis,
  standoff: number,
  ctx: PlacementCtx,
): CellCoord => {
  const alongRows = axis !== 'top_to_bottom';
  const values = latticeCells.map(cell => (alongRows ? cell.row : cell.col));
  const low = Math.min(...values);
  const high = Math.max(...values);
  const anchorValue = alongRows ? neighbourCell.row : neighbourCell.col;
  // Nearest lattice edge keeps the connector back to the anchor short; ties go
  // to the high side so chains read as "hanging below the map".
  const useHighSide = high - anchorValue <= anchorValue - low;
  const edgeValue = useHighSide ? high + standoff + 1 : low - standoff - 1;
  const ideal: CellCoord = alongRows
    ? { col: neighbourCell.col, row: edgeValue }
    : { col: edgeValue, row: neighbourCell.row };
  return pickPlacementCell(nodeId, ideal, ctx);
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
  /** CHEWY PATCH: extra cells between a chain node and a k-space neighbour — see BeautifyOptions.chainStandoff. */
  chainStandoff = 0,
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

  // Locked nodes are pinned ground truth: never placed, but their cell is
  // off-limits to everyone else (`occupied`) and their EXACT — possibly
  // off-grid — real position feeds pickPlacementCell's geometry checks
  // (`lockedPositions`), since a locked node's real edges are real too.
  const lockedPositions = new Map<string, CellCoord>();
  // CHEWY PATCH: a chain system may never be placed within `chainStandoff` of
  // the k-space lattice, whatever the search would otherwise prefer. Lattice
  // cells are read from each member's own current cell (they are never moved
  // by this pass).
  const latticeCellList: CellCoord[] = [];
  if (chainStandoff > 0) {
    for (const n of nodes) {
      if (kspaceMemberIds.has(n.id)) {
        latticeCellList.push({ col: Math.round(n.x / CELL_W), row: Math.round(n.y / CELL_H) });
      }
    }
  }
  const ctx: PlacementCtx = {
    cells: new Map(classification.validCells),
    occupied: new Set(),
    gateAdj,
    chainAdj,
    allEdges: [...gateEdges, ...chainEdges],
    lockedPositions,
    isCellAllowed:
      latticeCellList.length > 0
        ? (id, cell) => {
            if (kspaceMemberIds.has(id)) return true;
            return !latticeCellList.some(
              member =>
                Math.max(Math.abs(cell.col - member.col), Math.abs(cell.row - member.row)) < chainStandoff,
            );
          }
        : undefined,
  };
  for (const cell of ctx.cells.values()) ctx.occupied.add(cellKey(cell));
  for (const n of nodes) {
    if (!n.locked) continue;
    ctx.occupied.add(cellKey({ col: Math.round(n.x / CELL_W), row: Math.round(n.y / CELL_H) }));
    lockedPositions.set(n.id, { col: n.x / CELL_W, row: n.y / CELL_H });
  }

  const positions: Record<string, { x: number; y: number }> = {};
  let movedCount = 0;

  // Fixed, deterministic processing order. A node placed earlier in this
  // same pass is immediately available as an anchor/neighbour for a later
  // one (e.g. two new systems chained onto each other), so single-pass
  // alphabetical order is enough — it never stalls (every case below has
  // an unconditional fallback) and never depends on Map/Set iteration order.
  // CHEWY PATCH: place in waves — every pass places only the nodes that
  // already have a placed neighbour, so a chain is always laid out outward
  // from its attachment instead of a deep member being placed first (sorted
  // id order alone put `Anckee` at its raw lattice cell because its chain
  // parent had not been placed yet). Remaining nodes (no placed neighbour at
  // all) are handled by the final unconditional pass, exactly as before.
  const pending = [...classification.toPlace].sort();
  const placeOne = (id: string): void => {
    const node = nodeById.get(id)!;

    // CHEWY PATCH: graph adjacency is now computed unconditionally (not
    // just when there's no lattice cell) so it can serve BOTH as the
    // lattice branch's preferred anchor pool AND as this node's own
    // fallback if the lattice branch can't find any lattice-resolved
    // anchor at all — no code path dead-ends straight to the raw,
    // unsnapped current-position fallback while a real graph neighbour
    // sits right there already placed. See placeLatticeNode's header for
    // the failure this closes.
    const viaChain = (chainAdj.get(id) ?? []).filter(n2 => ctx.cells.has(n2));
    const viaGate = (gateAdj.get(id) ?? []).filter(n2 => ctx.cells.has(n2));

    // CHEWY PATCH: a chain system attached to the lattice goes OUT to the band
    // first — before the lattice branch, which would otherwise park a k-space
    // system that is only reachable by wormhole (Anckee, Gomati, Toon on the
    // live yugen map) right back inside the lattice it is not gated to.
    const isChainNode = chainStandoff > 0 && !kspaceMemberIds.has(id);
    const latticeNeighbour = viaChain.find(n2 => kspaceMemberIds.has(n2));
    const latticeCells: CellCoord[] = [];
    if (isChainNode && latticeNeighbour) {
      for (const memberId of kspaceMemberIds) {
        const cell = ctx.cells.get(memberId) ?? lockedPositions.get(memberId);
        if (cell) latticeCells.push({ col: Math.round(cell.col), row: Math.round(cell.row) });
      }
    }

    const lattice = isChainNode ? undefined : latticeById.get(id);
    let target: CellCoord | null =
      latticeCells.length > 0 && latticeNeighbour
        ? placeChainBandNode(id, ctx.cells.get(latticeNeighbour)!, latticeCells, axis, chainStandoff, ctx)
        : lattice
          ? placeLatticeNode(id, lattice, latticeById, [...viaGate, ...viaChain], ctx)
          : null;
    if (!target) {
      if (viaChain.length > 0) {
        target = placeAdjacentNode(id, viaChain, chainAdj, axis, ctx, chainStandoff, kspaceMemberIds);
      } else if (viaGate.length > 0) {
        target = placeAdjacentNode(id, viaGate, gateAdj, axis, ctx, chainStandoff, kspaceMemberIds);
      }
    }
    if (!target) {
      target = pickPlacementCell(id, { col: Math.round(node.x / CELL_W), row: Math.round(node.y / CELL_H) }, ctx);
    }

    commit(ctx, id, target);
    positions[id] = { x: target.col * CELL_W, y: target.row * CELL_H };
    movedCount += 1;
  };

  let remaining = pending;
  while (remaining.length > 0) {
    const ready = remaining.filter(
      id =>
        (chainAdj.get(id) ?? []).some(n2 => ctx.cells.has(n2)) ||
        (gateAdj.get(id) ?? []).some(n2 => ctx.cells.has(n2)),
    );
    const wave = ready.length > 0 ? ready : remaining.slice(0, 1);
    for (const id of wave) placeOne(id);
    const placed = new Set(wave);
    remaining = remaining.filter(id => !placed.has(id));
  }

  return { positions, movedCount };
};
