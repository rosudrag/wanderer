// Wormhole chain layout: BFS a rooted spanning tree out of the wormhole
// (type 0) and bridge (type 2) edges of one connected component, then lay
// it out with a parent-anchored tidy tree — depth maps to the primary
// axis (one cell per level); the secondary axis is assigned greedily,
// node by node, anchored at each node's own already-placed parent rather
// than by compacting whole subtree contours against each other.
// CHEWY PATCH: replaces the previous Buchheim–Jünger–Leipert contour
// compaction, which reflowed the whole tree (and could shift every
// unrelated branch) whenever one leaf was added anywhere — see
// placeSecondary() below for the rule and why it is insertion-stable.
// Non-tree edges (loops, K162 back-links, multi-parent cycles) are simply
// never consulted for geometry, per the assignment.

import type { BeautifyAxis, CellCoord, LayoutEdgeInput, LayoutNodeInput } from './types';

// ---------------------------------------------------------------------------
// Root selection
// ---------------------------------------------------------------------------

const KNOWN_SPACE_CLASS_IDS: Record<number, true> = {
  7: true /* hs */,
  8: true /* ls */,
  9: true /* ns */,
  10100: true /* zarzakh */,
};

const isKSpaceLike = (node: LayoutNodeInput): boolean =>
  node.security != null || (node.systemClass != null && KNOWN_SPACE_CLASS_IDS[node.systemClass] === true);

/**
 * Deterministic root selection for a rooted tree layout:
 *   1. first id from `hubs` that is present in `nodes`;
 *   2. else the node with the highest "hub score" (defined below) — ties
 *      are broken by the lexicographically smallest id;
 *   3. else a node whose systemClass/security marks it as k-space (a
 *      natural chain root — chains grow out of a known-space entry);
 *   4. else the lexicographically smallest id.
 *
 * Hub score, and why it is insertion-stable:
 *
 * CHEWY PATCH: previously this compared raw degree first and only used
 * `nonLeafNeighborCount` (a node's count of neighbours that are
 * themselves non-leaves, i.e. degree >= 2) as a tie-break. That let a
 * single new pendant leaf attached to ANY interior node of an otherwise
 * degree-tied run (e.g. every interior node of a long, unbranched chain
 * has raw degree 2) push that one node's raw degree to 3 — strictly
 * ahead of the tie, never even reaching the tie-break — and re-root the
 * whole tree. A 10-node chain with one new leaf hung off node 5 (not
 * the tail) mirrored all 10 positions on the next beautify.
 *
 * The fix promotes that tie-break to the primary key, but a plain
 * `nonLeafNeighborCount`-first comparison would mis-rank a pure "star"
 * hub (one node directly holding several pendant leaves) below its own
 * leaves, because ALL of the hub's neighbours are leaves — its
 * `nonLeafNeighborCount` is 0 even though it is obviously the right
 * root. `hubScore` resolves this: use `nonLeafNeighborCount` whenever it
 * is positive, and only fall back to raw degree when it is zero (i.e.
 * every neighbour of this node is a leaf — the star-hub / degenerate
 * case, where raw degree IS the right signal). A tree can have at most
 * one node with an all-leaf neighbourhood and degree >= 2 — any second
 * such "leaf-collector" would have to connect to the first through some
 * intermediate node, and that intermediate node has degree >= 2 and so
 * counts as a non-leaf neighbour of whichever collector it touches,
 * contradicting the all-leaf assumption — so this fallback never has two
 * competing candidates for a new leaf to tip.
 *
 * This makes hub score immune to a fresh pendant leaf attached ANYWHERE
 * except directly on a current degree-1 tip (extending the tail, which
 * is expected to matter): attaching a leaf L to node p only changes
 * degree(p), never degree of p's existing neighbours, and L itself has
 * degree 1 so it never counts toward anyone's `nonLeafNeighborCount` —
 * not p's (L isn't a non-leaf neighbour of p) and not any other node's
 * (L is only adjacent to p). The one case that DOES shift a score is
 * when p was itself a degree-1 tip before the attachment: p's own
 * leaf/non-leaf status flips, which changes p's *parent's*
 * `nonLeafNeighborCount` — but that is exactly "growing the tail",
 * which is allowed to matter.
 */
export const pickChainRoot = (nodes: LayoutNodeInput[], edges: LayoutEdgeInput[], hubs?: string[]): string | null => {
  if (nodes.length === 0) return null;

  const idSet = new Set(nodes.map(n => n.id));

  if (hubs) {
    for (const hub of hubs) {
      if (idSet.has(hub)) return hub;
    }
  }

  const degree = new Map<string, number>();
  for (const id of idSet) degree.set(id, 0);
  const neighbors = new Map<string, string[]>();
  for (const id of idSet) neighbors.set(id, []);
  for (const edge of edges) {
    if (edge.type !== 0 && edge.type !== 2) continue;
    if (edge.source === edge.target) continue;
    if (!idSet.has(edge.source) || !idSet.has(edge.target)) continue;
    degree.set(edge.source, (degree.get(edge.source) ?? 0) + 1);
    degree.set(edge.target, (degree.get(edge.target) ?? 0) + 1);
    neighbors.get(edge.source)!.push(edge.target);
    neighbors.get(edge.target)!.push(edge.source);
  }
  // How many of a node's neighbours are themselves connected to something
  // else (degree >= 2), i.e. not a bare pendant leaf. A freshly-attached
  // system is always a leaf at the moment it's added, so this count is
  // immune to it, unlike raw degree.
  const nonLeafNeighborCount = (id: string): number => neighbors.get(id)!.filter(n => (degree.get(n) ?? 0) >= 2).length;

  // CHEWY PATCH: primary key described above the function — prefer
  // nonLeafNeighborCount (immune to a fresh pendant leaf), falling back
  // to raw degree only for a node whose neighbours are all leaves.
  const hubScore = (id: string): number => {
    const nl = nonLeafNeighborCount(id);
    return nl > 0 ? nl : (degree.get(id) ?? 0);
  };

  let best: string | null = null;
  let bestScore = -1;
  for (const node of nodes) {
    const score = hubScore(node.id);
    if (score > bestScore || (score === bestScore && best !== null && node.id < best)) {
      best = node.id;
      bestScore = score;
    }
  }
  if (bestScore > 0 && best !== null) return best;

  const kspaceCandidates = nodes
    .filter(isKSpaceLike)
    .map(n => n.id)
    .sort();
  if (kspaceCandidates.length > 0) return kspaceCandidates[0];

  return [...idSet].sort()[0] ?? null;
};

// ---------------------------------------------------------------------------
// Tidy tree — parent-anchored placement
// ---------------------------------------------------------------------------

interface TNode {
  id: string;
  parent: TNode | null;
  children: TNode[];
  subtreeSize: number;
  /**
   * Original secondary-axis input coordinate: a real position for a node
   * already on the map, a deterministic drop-point jitter for a brand-new
   * one. Used for sibling-order tie-breaking (see sortChildren below) and
   * as the anchor for placeSecondary()'s local free-cell search.
   */
  secondaryHint: number;

  // Results.
  depth: number;
  secondary: number;
}

const makeNode = (id: string, parent: TNode | null, secondaryHint: number): TNode => ({
  id,
  parent,
  children: [],
  subtreeSize: 1,
  secondaryHint,
  depth: 0,
  secondary: 0,
});

/**
 * BFS from `rootId` over wormhole/bridge edges to build a spanning tree,
 * ordering each node's children by ascending original secondary-axis
 * coordinate (insertion-stable: this value never changes when a sibling
 * is added or grows), then descending subtree size as a tie-break, then id
 * (final deterministic tie-break) — see sortChildren below.
 *
 * Depth-stability rule: a node's depth is simply which BFS layer first
 * discovers it, and a brand-new system is always attached with exactly
 * one edge to something already on the map (that's what "discovering a
 * system" means, here and in every caller). A degree-1 newcomer can never
 * shorten the graph distance between two nodes that were already present
 * — doing that requires being a bridge with two or more edges into the
 * existing graph — so every existing node keeps the exact depth it had
 * before the new node arrived; there is nothing to "prefer the old depth"
 * over, because the BFS can't produce a different one. This holds
 * regardless of root, as long as root selection itself doesn't change
 * (see pickChainRoot's non-leaf-neighbour tie-break above, which is what
 * keeps *that* stable too).
 */
const buildTree = (
  nodes: LayoutNodeInput[],
  edges: LayoutEdgeInput[],
  rootId: string,
  axis: BeautifyAxis,
): TNode | null => {
  const byId = new Map(nodes.map(n => [n.id, n]));
  if (!byId.has(rootId)) return null;

  const adjacency = new Map<string, Set<string>>();
  for (const id of byId.keys()) adjacency.set(id, new Set());
  for (const edge of edges) {
    if (edge.type !== 0 && edge.type !== 2) continue;
    if (edge.source === edge.target) continue;
    if (!byId.has(edge.source) || !byId.has(edge.target)) continue;
    adjacency.get(edge.source)!.add(edge.target);
    adjacency.get(edge.target)!.add(edge.source);
  }

  const secondaryOf = (id: string): number => {
    const n = byId.get(id)!;
    return axis === 'left_to_right' ? n.y : n.x;
  };

  const nodeById = new Map<string, TNode>();
  const root = makeNode(rootId, null, secondaryOf(rootId));
  nodeById.set(rootId, root);

  const visited = new Set<string>([rootId]);
  const queue: TNode[] = [root];
  while (queue.length > 0) {
    const current = queue.shift()!;
    const neighborIds = [...(adjacency.get(current.id) ?? [])].filter(id => !visited.has(id));
    // Deterministic traversal order; final sibling order is re-applied below anyway.
    neighborIds.sort();
    for (const id of neighborIds) {
      visited.add(id);
      const child = makeNode(id, current, secondaryOf(id));
      current.children.push(child);
      nodeById.set(id, child);
      queue.push(child);
    }
  }

  // Any node unreachable from the root (shouldn't happen for a true
  // connected component, but guard defensively) is dropped — it keeps
  // whatever position it already has.

  // Bottom-up subtree size, then sort children and fix up indices.
  const order = [...nodeById.values()].sort((a, b) => depthOfPath(b) - depthOfPath(a));
  for (const node of order) {
    node.subtreeSize = 1 + node.children.reduce((sum, c) => sum + c.subtreeSize, 0);
  }
  const sortChildren = (node: TNode): void => {
    node.children.sort((a, b) => {
      // Primary key: the child's own secondary-axis input coordinate. This
      // is a per-node quantity that never changes when a sibling is added
      // or a sibling's subtree grows, so — unlike sorting by subtreeSize —
      // it cannot reorder already-placed siblings. For a node that already
      // has a real position on the map this is that position; for a
      // brand-new node it is the caller-supplied (deterministic, jittered)
      // drop point near its parent, which still yields a stable, decided
      // key with no extra bookkeeping required.
      if (a.secondaryHint !== b.secondaryHint) return a.secondaryHint - b.secondaryHint;
      // subtreeSize is demoted to a tie-break at most: it only matters
      // between two siblings whose input coordinates coincide exactly.
      if (a.subtreeSize !== b.subtreeSize) return b.subtreeSize - a.subtreeSize;
      return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
    });
    node.children.forEach(sortChildren);
  };
  sortChildren(root);

  return root;
};

/** Path-length-to-root helper used only to process subtreeSize bottom-up without recursion depth concerns. */
const depthOfPath = (node: TNode): number => {
  let d = 0;
  let cur: TNode | null = node;
  while (cur.parent) {
    d++;
    cur = cur.parent;
  }
  return d;
};

/**
 * Assigns every node's secondary-axis coordinate one BFS level at a time
 * (so a parent is always placed before its children), anchored on that
 * parent's own already-decided cell rather than on any subtree-width
 * bookkeeping:
 *
 *   - the root sits at 0;
 *   - a lone child continues straight out from its parent (same cell);
 *   - when two or more children want the same cell (a fork, or two
 *     unrelated branches landing on the same row/column), whichever one
 *     sits closest to the parent in the *original* input coordinates
 *     claims it, and the rest are pushed to the nearest still-free cell at
 *     that depth, searching outward in the direction their own input
 *     coordinate points (so a branch still reads as growing "away from"
 *     its parent). A node that already has a real position on the map
 *     sits at a fixed distance from its parent that never changes just
 *     because a sibling is added, so it reliably keeps first claim over a
 *     brand-new sibling whose jittered "just discovered it" coordinate
 *     only coincidentally lands close to the parent.
 *
 * CHEWY PATCH: this is the whole fix for "adding one leaf moves the whole
 * map". A node's cell is a pure function of (its parent's already-fixed
 * cell, which other nodes happen to already occupy at its own depth) —
 * never of a sibling subtree's size or a global compaction pass. Adding a
 * brand-new leaf can therefore only ever perturb the direct siblings it
 * collides with (and their own descendants, re-anchored one cell over) —
 * it cannot ripple into an unrelated branch, because branches never share
 * a "width budget" that has to be renegotiated when one of them grows.
 * One cell of separation between any two same-depth nodes is guaranteed
 * structurally (occupancy is tracked as a set of distinct integers), so
 * the contour-separation guarantee holds without any contour math.
 */
const placeSecondary = (root: TNode): void => {
  root.secondary = 0;
  root.depth = 0;

  let frontier: TNode[] = [root];
  let depth = 0;
  while (frontier.length > 0) {
    depth++;
    // Visit each already-placed parent's children, closest-to-parent
    // first (in the original input coordinates), so a child that already
    // has a real position claims the parent's cell before an unrelated
    // newcomer's jitter can steal it.
    const level: TNode[] = [];
    for (const parent of frontier) {
      const kids = [...parent.children].sort((a, b) => {
        const da = Math.abs(a.secondaryHint - parent.secondaryHint);
        const db = Math.abs(b.secondaryHint - parent.secondaryHint);
        if (da !== db) return da - db;
        if (a.secondaryHint !== b.secondaryHint) return a.secondaryHint - b.secondaryHint;
        return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
      });
      level.push(...kids);
    }
    if (level.length === 0) break;

    const occupied = new Set<number>();
    for (const node of level) {
      const parent = node.parent!;
      const anchor = parent.secondary;
      const towardPositive = node.secondaryHint >= parent.secondaryHint;
      let cell = anchor;
      if (occupied.has(cell)) {
        for (let step = 1; ; step++) {
          const forward = anchor + (towardPositive ? step : -step);
          if (!occupied.has(forward)) {
            cell = forward;
            break;
          }
          const backward = anchor + (towardPositive ? -step : step);
          if (!occupied.has(backward)) {
            cell = backward;
            break;
          }
        }
      }
      node.secondary = cell;
      node.depth = depth;
      occupied.add(cell);
    }
    frontier = level;
  }
};

export interface ChainTreeLayout {
  /** node id -> local cell coordinate, for every node in the component (including those the caller may choose not to emit). */
  localCells: Map<string, CellCoord>;
  /** node id -> BFS depth from the root, for anchor-distance lookups. */
  depths: Map<string, number>;
}

/**
 * Lays out one already-identified connected component as a rooted tidy
 * tree. Returns local (untranslated) cell coordinates for every node the
 * BFS could reach from `rootId`; nodes unreachable in this edge set (should
 * not occur for a true connected component) are simply absent.
 */
export const layoutChainTree = (
  nodes: LayoutNodeInput[],
  edges: LayoutEdgeInput[],
  axis: BeautifyAxis,
  rootId: string,
): ChainTreeLayout => {
  const root = buildTree(nodes, edges, rootId, axis);
  if (!root) return { localCells: new Map(), depths: new Map() };

  placeSecondary(root);

  const localCells = new Map<string, CellCoord>();
  const depths = new Map<string, number>();
  const collect = (node: TNode): void => {
    const cell: CellCoord =
      axis === 'left_to_right' ? { col: node.depth, row: node.secondary } : { col: node.secondary, row: node.depth };
    localCells.set(node.id, cell);
    depths.set(node.id, node.depth);
    node.children.forEach(collect);
  };
  collect(root);

  return { localCells, depths };
};
