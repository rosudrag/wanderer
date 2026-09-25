// Wormhole chain layout: BFS a rooted spanning tree out of the wormhole
// (type 0) and bridge (type 2) edges of one connected component, then lay
// it out with the Reingold–Tilford / Buchheim–Jünger–Leipert "linear time"
// tidy-tree algorithm — depth maps to the primary axis (one cell per
// level), siblings are packed along the secondary axis with exactly one
// cell of contour separation, and every subtree is centred over its
// children. Non-tree edges (loops, K162 back-links, multi-parent cycles)
// are simply never consulted for geometry, per the assignment.

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
 *   2. else the node with the most wormhole/bridge connections;
 *   3. else a node whose systemClass/security marks it as k-space (a
 *      natural chain root — chains grow out of a known-space entry);
 *   4. else the lexicographically smallest id.
 *
 * Operates on whatever node/edge set it is given, so callers laying out
 * several disconnected components must call this once per component with
 * pre-filtered inputs (it does not itself partition the graph).
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
  for (const edge of edges) {
    if (edge.type !== 0 && edge.type !== 2) continue;
    if (edge.source === edge.target) continue;
    if (!idSet.has(edge.source) || !idSet.has(edge.target)) continue;
    degree.set(edge.source, (degree.get(edge.source) ?? 0) + 1);
    degree.set(edge.target, (degree.get(edge.target) ?? 0) + 1);
  }

  let best: string | null = null;
  let bestDegree = -1;
  for (const node of nodes) {
    const d = degree.get(node.id) ?? 0;
    if (d > bestDegree || (d === bestDegree && best !== null && node.id < best)) {
      best = node.id;
      bestDegree = d;
    }
  }
  if (bestDegree > 0 && best !== null) return best;

  const kspaceCandidates = nodes
    .filter(isKSpaceLike)
    .map(n => n.id)
    .sort();
  if (kspaceCandidates.length > 0) return kspaceCandidates[0];

  return [...idSet].sort()[0] ?? null;
};

// ---------------------------------------------------------------------------
// Tidy tree (Buchheim, Jünger & Leipert 2002)
// ---------------------------------------------------------------------------

/** One unit of separation between adjacent nodes/subtree contours, in cells. */
const DISTANCE = 1;

interface TNode {
  id: string;
  parent: TNode | null;
  children: TNode[];
  /** Index among parent's (already-sorted) children. */
  index: number;
  subtreeSize: number;
  /** Original secondary-axis input coordinate, used only for sibling-order tie-breaking. */
  secondaryHint: number;

  // Buchheim algorithm working state.
  prelim: number;
  mod: number;
  shift: number;
  change: number;
  ancestor: TNode;
  thread: TNode | null;

  // Results.
  depth: number;
  secondary: number; // float, pre-integerization
}

const makeNode = (id: string, parent: TNode | null, index: number, secondaryHint: number): TNode => {
  const node: TNode = {
    id,
    parent,
    children: [],
    index,
    subtreeSize: 1,
    secondaryHint,
    prelim: 0,
    mod: 0,
    shift: 0,
    change: 0,
    ancestor: null as unknown as TNode,
    thread: null,
    depth: 0,
    secondary: 0,
  };
  node.ancestor = node;
  return node;
};

/**
 * BFS from `rootId` over wormhole/bridge edges to build a spanning tree,
 * ordering each node's children by descending subtree size (fat branches
 * to the outside) then ascending original secondary-axis coordinate (so a
 * beautify preserves the user's existing top-to-bottom / left-to-right
 * reading order), then id (final deterministic tie-break).
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
  const root = makeNode(rootId, null, 0, secondaryOf(rootId));
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
      const child = makeNode(id, current, current.children.length, secondaryOf(id));
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
      if (a.subtreeSize !== b.subtreeSize) return b.subtreeSize - a.subtreeSize;
      if (a.secondaryHint !== b.secondaryHint) return a.secondaryHint - b.secondaryHint;
      return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
    });
    node.children.forEach((c, i) => (c.index = i));
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

const nextLeft = (v: TNode): TNode | null => (v.children.length ? v.children[0] : v.thread);
const nextRight = (v: TNode): TNode | null => (v.children.length ? v.children[v.children.length - 1] : v.thread);

const moveSubtree = (wLeft: TNode, wRight: TNode, shift: number): void => {
  const subtrees = wRight.index - wLeft.index;
  if (subtrees <= 0) return;
  wRight.change -= shift / subtrees;
  wRight.shift += shift;
  wLeft.change += shift / subtrees;
  wRight.prelim += shift;
  wRight.mod += shift;
};

const ancestorOf = (vIm: TNode, v: TNode, defaultAncestor: TNode): TNode =>
  vIm.ancestor.parent === v.parent ? vIm.ancestor : defaultAncestor;

const executeShifts = (v: TNode): void => {
  let shift = 0;
  let change = 0;
  for (let i = v.children.length - 1; i >= 0; i--) {
    const w = v.children[i];
    w.prelim += shift;
    w.mod += shift;
    change += w.change;
    shift += w.shift + change;
  }
};

const apportion = (v: TNode, defaultAncestor: TNode): TNode => {
  if (v.index === 0 || !v.parent) return defaultAncestor;
  const w = v.parent.children[v.index - 1];

  let vip: TNode = v;
  let vop: TNode = v;
  let vim: TNode = w;
  let vom: TNode = v.parent.children[0];

  let sip = vip.mod;
  let sop = vop.mod;
  let sim = vim.mod;
  let som = vom.mod;

  let nr = nextRight(vim);
  let nl = nextLeft(vip);
  while (nr && nl) {
    vim = nr;
    vip = nl;
    vom = nextLeft(vom)!;
    vop = nextRight(vop)!;
    vop.ancestor = v;

    const shift = vim.prelim + sim - (vip.prelim + sip) + DISTANCE;
    if (shift > 0) {
      moveSubtree(ancestorOf(vim, v, defaultAncestor), v, shift);
      sip += shift;
      sop += shift;
    }
    sim += vim.mod;
    sip += vip.mod;
    som += vom.mod;
    sop += vop.mod;

    nr = nextRight(vim);
    nl = nextLeft(vip);
  }

  if (nr && !nextRight(vop)) {
    vop.thread = nr;
    vop.mod += sim - sop;
  }
  if (nl && !nextLeft(vom)) {
    vom.thread = nl;
    vom.mod += sip - som;
    return v;
  }

  return defaultAncestor;
};

const firstWalk = (v: TNode): void => {
  if (v.children.length === 0) {
    if (v.index > 0) {
      v.prelim = v.parent!.children[v.index - 1].prelim + DISTANCE;
    } else {
      v.prelim = 0;
    }
    return;
  }

  let defaultAncestor = v.children[0];
  for (const child of v.children) {
    firstWalk(child);
    defaultAncestor = apportion(child, defaultAncestor);
  }
  executeShifts(v);

  const first = v.children[0];
  const last = v.children[v.children.length - 1];
  const midpoint = (first.prelim + last.prelim) / 2;

  if (v.index > 0) {
    v.prelim = v.parent!.children[v.index - 1].prelim + DISTANCE;
    v.mod = v.prelim - midpoint;
  } else {
    v.prelim = midpoint;
  }
};

const secondWalk = (v: TNode, m: number, depth: number): void => {
  v.secondary = v.prelim + m;
  v.depth = depth;
  for (const child of v.children) secondWalk(child, m + v.mod, depth + 1);
};

/**
 * Snap the float secondary-axis coordinates produced by the Buchheim walk
 * onto the integer cell grid, one depth level at a time. The algorithm
 * above guarantees >=1 unit of separation between any two nodes sharing a
 * depth (that is the whole point of contour-following apportionment), but
 * relies on that being exact in floating point; rounding independently
 * could in principle let two nodes collapse onto the same integer. This
 * pass removes that risk entirely and deterministically: sort each depth
 * band by (float secondary, id), then assign strictly increasing integers,
 * bumping up only when a naive round would collide with the previous node.
 */
const integerizeByDepth = (root: TNode): void => {
  const byDepth = new Map<number, TNode[]>();
  const collect = (node: TNode): void => {
    const bucket = byDepth.get(node.depth);
    if (bucket) bucket.push(node);
    else byDepth.set(node.depth, [node]);
    node.children.forEach(collect);
  };
  collect(root);

  for (const bucket of byDepth.values()) {
    bucket.sort((a, b) => a.secondary - b.secondary || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    let prev = -Infinity;
    for (const node of bucket) {
      let v = Math.round(node.secondary);
      if (v <= prev) v = prev + 1;
      node.secondary = v;
      prev = v;
    }
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

  firstWalk(root);
  secondWalk(root, 0, 0);
  integerizeByDepth(root);

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
