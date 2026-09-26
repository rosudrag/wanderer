// Map beautifier layout engine — public API.
//
// Pipeline:
//   1. Partition the graph: gate (type 1) edges define k-space clusters;
//      wormhole/bridge (type 0/2) edges define chain structure. A node
//      touched by no gate edge is chain-only.
//   2. Lay out every k-space cluster member that resolves to a GLOBAL
//      lattice cell as ONE geographic box shared across every cluster and
//      region (or every cluster topologically, per options/fallback); any
//      member lacking a lattice entry falls back to a per-cluster
//      topological group — see kspaceLayout.ts.
//   3. Build the wormhole-chain forest out of chain-only nodes plus any
//      k-space node that has a wormhole/bridge edge reaching into it (an
//      "attachment point"), and lay out each component as a tidy tree
//      rooted at pickChainRoot() — see chainLayout.ts. Attachment points
//      and locked nodes are pinned: they seed the tree's translation but
//      never receive a newly-emitted position themselves.
//   4. Hand every component (the geographic box, topological groups, chain
//      trees) to pack.ts as a LayoutBox; it places them on one shared grid
//      without overlap.
//   5. Emit only nodes whose integer-cell position actually changed,
//      excluding every locked node.

import { pickChainRoot, layoutChainTree } from './chainLayout';
import { layoutGeographicSet, layoutTopologicalGroup } from './kspaceLayout';
import { packBoxes, reduceCrossings, measureLayout, qualityScore, localViolationScore } from './pack';
import { loadRegionLayouts } from './regionData';
// CHEWY PATCH: angle discipline (WANDERER_ANGLE_SNAP) — see octilinear.ts.
import { snapAngles } from './octilinear';
// CHEWY PATCH: mode: 'auto' | 'incremental' | 'full' support (see the
// mode-resolution block in beautifyLayout below and anchor.ts's header).
import { classifyNodes, placeIncrementalNodes, INCREMENTAL_VALID_FRACTION_THRESHOLD } from './anchor';
import type { NodeClassification } from './anchor';
import { CELL_H, CELL_W } from './types';
import type {
  BeautifyAxis,
  BeautifyOptions,
  CellCoord,
  KSpaceMode,
  LayoutBox,
  LayoutEdgeInput,
  LayoutNodeInput,
  LayoutQuality,
  LayoutResult,
} from './types';

export { CELL_W, CELL_H, pickChainRoot };
export type {
  BeautifyAxis,
  BeautifyOptions,
  KSpaceMode,
  LayoutEdgeInput,
  LayoutNodeInput,
  LayoutQuality,
  LayoutResult,
} from './types';

// ---------------------------------------------------------------------------
// Graph sanitation & partitioning helpers
// ---------------------------------------------------------------------------

/** Drops self-edges, edges referencing unknown nodes, and duplicate (type, unordered endpoint pair) edges. */
const sanitizeEdges = (edges: LayoutEdgeInput[], nodeIds: ReadonlySet<string>): LayoutEdgeInput[] => {
  const seen = new Set<string>();
  const result: LayoutEdgeInput[] = [];
  for (const edge of edges) {
    if (edge.source === edge.target) continue;
    if (!nodeIds.has(edge.source) || !nodeIds.has(edge.target)) continue;
    const [a, b] = edge.source < edge.target ? [edge.source, edge.target] : [edge.target, edge.source];
    const key = `${edge.type}:${a}:${b}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(edge);
  }
  return result;
};

const connectedComponents = (ids: string[], edges: Array<{ source: string; target: string }>): string[][] => {
  const adjacency = new Map<string, string[]>();
  for (const id of ids) adjacency.set(id, []);
  for (const edge of edges) {
    adjacency.get(edge.source)?.push(edge.target);
    adjacency.get(edge.target)?.push(edge.source);
  }

  const visited = new Set<string>();
  const components: string[][] = [];
  for (const id of [...ids].sort()) {
    if (visited.has(id)) continue;
    const component: string[] = [];
    const queue = [id];
    visited.add(id);
    while (queue.length > 0) {
      const current = queue.shift()!;
      component.push(current);
      for (const neighbor of adjacency.get(current) ?? []) {
        if (!visited.has(neighbor)) {
          visited.add(neighbor);
          queue.push(neighbor);
        }
      }
    }
    components.push(component.sort());
  }
  return components;
};

const edgesWithin = (edges: LayoutEdgeInput[], idSet: ReadonlySet<string>): LayoutEdgeInput[] =>
  edges.filter(e => idSet.has(e.source) && idSet.has(e.target));

/**
 * CHEWY PATCH: hidden-connection-first comparison of two layouts of the same
 * graph, ignoring the edge-length tie-breaker `qualityScore` carries. Used
 * wherever "is this candidate actually better for the user" must not be
 * decided by a fraction of a cell of total edge length.
 */
const defectScore = (quality: LayoutQuality): number =>
  (quality.occlusions + quality.overlaps) * 1000 + quality.crossings;


// ---------------------------------------------------------------------------
// beautifyLayout
// ---------------------------------------------------------------------------

/** One pass of the pipeline described in the file header. Public entry point is `beautifyLayout` below, which runs this to convergence. */
const beautifyOnce = async (
  nodes: LayoutNodeInput[],
  edges: LayoutEdgeInput[],
  options: BeautifyOptions = {},
): Promise<LayoutResult> => {
  const emptyQuality: LayoutQuality = { crossings: 0, overlaps: 0, occlusions: 0, edgeLength: 0, offAngle: 0 };
  if (nodes.length === 0) {
    return {
      positions: {},
      rootId: null,
      movedCount: 0,
      mode: 'full',
      quality: { before: emptyQuality, after: emptyQuality },
    };
  }

  const axis: BeautifyAxis = options.axis ?? 'left_to_right';
  const kspaceMode: KSpaceMode = options.kspaceMode ?? 'geographic';
  const hubs = options.hubs ?? [];
  const explicitRootId = options.rootId ?? null;
  const requestedMode = options.mode ?? 'auto';
  // CHEWY PATCH: clearance (in cells) between a wormhole chain and its k-space
  // anchor; 0 = upstream behaviour. Fractional/negative input is clamped away.
  const chainStandoff = Math.max(0, Math.floor(options.chainStandoff ?? 0));
  // CHEWY PATCH: quantize connection directions as a final polish pass; off
  // (upstream) unless the server sets WANDERER_ANGLE_SNAP. See octilinear.ts.
  const angleSnap = options.angleSnap === true;

  const nodeById = new Map(nodes.map(n => [n.id, n]));
  const nodeIds = new Set(nodeById.keys());
  const cleanEdges = sanitizeEdges(edges, nodeIds);
  const gateEdges = cleanEdges.filter(e => e.type === 1);
  const chainEdges = cleanEdges.filter(e => e.type === 0 || e.type === 2);

  // CHEWY PATCH: the layout the user actually has right now, quantized to
  // cells — the baseline every result is measured against (and, for
  // `mode: 'auto'`, the fallback a worse re-solve is rejected in favour of).
  const inputCells = new Map<string, CellCoord>(
    nodes.map(n => [n.id, { col: Math.round(n.x / CELL_W), row: Math.round(n.y / CELL_H) }]),
  );
  const inputQuality = measureLayout(cleanEdges, inputCells);
  const movableIds = new Set([...nodeIds].filter(id => !nodeById.get(id)!.locked));

  // CHEWY PATCH: is the layout the user has right now already a legal one —
  // every unlocked node exactly on the grid, no two nodes sharing a cell?
  // Both "don't churn a clean map" guards below hang off this: a layout that
  // is well-formed AND no worse than anything we can produce must be left
  // exactly alone, however many times the user presses the button.
  const inputCellKeys = new Set([...inputCells.values()].map(c => `${c.col},${c.row}`));
  const inputWellFormed =
    nodes.every(n => n.locked || (n.x % CELL_W === 0 && n.y % CELL_H === 0)) &&
    inputCellKeys.size === inputCells.size;
  /** Emits only nodes whose integer cell differs from their current position; locked nodes are never emitted. */
  const emit = (cells: Map<string, CellCoord>): { positions: Record<string, { x: number; y: number }>; movedCount: number } => {
    const positions: Record<string, { x: number; y: number }> = {};
    let movedCount = 0;
    for (const [id, cell] of cells) {
      const original = nodeById.get(id);
      if (!original || original.locked) continue;
      const x = cell.col * CELL_W;
      const y = cell.row * CELL_H;
      if (x === original.x && y === original.y) continue;
      positions[id] = { x, y };
      movedCount += 1;
    }
    return { positions, movedCount };
  };

  // --- 1. Partition -------------------------------------------------------

  const gateComponents = connectedComponents([...nodeIds], gateEdges);
  const kspaceClusters = gateComponents.filter(c => c.length >= 2);
  const kspaceMemberIds = new Set<string>(kspaceClusters.flat());

  // CHEWY PATCH: the repair pass may not undo chain standoff. It is allowed to
  // move a chain system, but never into a cell within `chainStandoff` of the
  // k-space lattice — without this it pulled chains straight back in (measured
  // on live yugen: two systems dragged 2 cells back to 1 cell of the lattice).
  const isCellAllowed =
    chainStandoff > 0
      ? (id: string, cell: CellCoord): boolean => {
          if (kspaceMemberIds.has(id)) return true;
          for (const memberId of kspaceMemberIds) {
            const member = inputCells.get(memberId);
            if (!member) continue;
            if (Math.max(Math.abs(cell.col - member.col), Math.abs(cell.row - member.row)) < chainStandoff) {
              return false;
            }
          }
          return true;
        }
      : undefined;

  /**
   * CHEWY PATCH: the standoff fence the ANGLE path uses, and only it —
   * `isCellAllowed` above stays exactly as it was for every layout produced
   * without `angleSnap`, because the bench's round-trip stability numbers are
   * calibrated against it (making it live+symmetric for everyone took yugen
   * from movedFrac 0.04 to 0.16 and rank inversions from 1.5 to 4.4).
   *
   * Two differences, both forced by the angle pass:
   *  - measured against the cells being improved, not `inputCells`: in full
   *    mode the lattice has just been rebuilt somewhere else entirely, so the
   *    user's old member positions fence off the wrong region of the grid;
   *  - symmetric: fencing only the chain side let a k-space system be nudged
   *    up against a chain that had just been moved clear — the same picture
   *    with the blame reversed, and measured on the `occlusion` scenario the
   *    clearance closed back to 1 cell that way.
   */
  const angleFenceFor = (
    cells: Map<string, CellCoord>,
  ): ((id: string, cell: CellCoord) => boolean) | undefined => {
    if (chainStandoff <= 0) return undefined;
    return (id: string, cell: CellCoord): boolean => {
      const selfIsLattice = kspaceMemberIds.has(id);
      for (const [otherId, other] of cells) {
        if (otherId === id) continue;
        if (kspaceMemberIds.has(otherId) === selfIsLattice) continue;
        if (Math.max(Math.abs(cell.col - other.col), Math.abs(cell.row - other.row)) < chainStandoff) {
          return false;
        }
      }
      return true;
    };
  };

  /**
   * CHEWY PATCH: evict chain systems that are already inside the standoff
   * zone. `fenceFor` only vetoes MOVES, so a system the placement step put
   * too close to the lattice stays there — the improvement passes have no
   * reason to touch it. Measured on the bench's `occlusion` scenario: the
   * placement left one chain system 1 cell off the lattice, the incremental
   * candidate comparison scored that as crowded, and the NEXT beautify moved
   * it out. Two presses to settle, i.e. not idempotent.
   *
   * Nearest legal free cell wins, ties by column then row, and only if the
   * move does not make that system's own crossings/hidden connections worse.
   */
  const evictCrowded = (cells: Map<string, CellCoord>): Map<string, CellCoord> => {
    const fence = angleFenceFor(cells);
    if (!fence) return cells;
    const result = new Map(cells);
    const occupied = new Set([...result.values()].map(c => `${c.col},${c.row}`));
    const radius = chainStandoff + 2;

    for (const id of [...movableIds].sort()) {
      const from = result.get(id);
      if (!from || fence(id, from)) continue;
      const before = localViolationScore(cleanEdges, result, id);
      let best: CellCoord | null = null;
      let bestDistance = Infinity;
      for (let dCol = -radius; dCol <= radius; dCol++) {
        for (let dRow = -radius; dRow <= radius; dRow++) {
          const cell = { col: from.col + dCol, row: from.row + dRow };
          const distance = Math.hypot(dCol, dRow);
          if (distance === 0 || distance > radius || distance > bestDistance) continue;
          if (occupied.has(`${cell.col},${cell.row}`)) continue;
          if (!fence(id, cell)) continue;
          result.set(id, cell);
          const after = localViolationScore(cleanEdges, result, id);
          result.set(id, from);
          if (after > before) continue;
          if (distance < bestDistance) {
            best = cell;
            bestDistance = distance;
          }
        }
      }
      if (!best) continue;
      occupied.delete(`${from.col},${from.row}`);
      occupied.add(`${best.col},${best.row}`);
      result.set(id, best);
    }
    return result;
  };

  /**
   * CHEWY PATCH: repair and angle discipline, run to a joint fixed point.
   *
   * One pass each is not enough and the order cannot be chosen: repair moves
   * nodes to clear crossings (which skews angles), the angle pass moves them
   * onto clean directions (which opens crossing fixes repair never got to
   * see). Measured on the bench's `occlusion` scenario with angles on and a
   * single repair-then-snap: press one left 5 crossings, press two found 1,
   * press three settled — i.e. the user had to press beautify three times.
   * Alternating here converges before returning, so one press is one press.
   *
   * It terminates: repair strictly lowers the violation score and never sees
   * angles at all, while the angle pass strictly lowers
   * violations*100 + offAngle and can never raise violations. So the compound
   * potential (violations, then off-angle edges) falls on every accepted move
   * of either pass. The round cap is a safety net, not the exit condition.
   */
  const MAX_SETTLE_ROUNDS = 6;

  const settle = (cells: Map<string, CellCoord>): Map<string, CellCoord> => {
    if (!angleSnap) return reduceCrossings(cells, cleanEdges, movableIds, isCellAllowed);
    const evicted = evictCrowded(cells);
    let current = reduceCrossings(evicted, cleanEdges, movableIds, angleFenceFor(evicted));
    for (let round = 0; round < MAX_SETTLE_ROUNDS; round++) {
      const snapped = snapAngles(current, cleanEdges, {
        movableIds,
        isCellAllowed: angleFenceFor(current),
      });
      const next = reduceCrossings(snapped, cleanEdges, movableIds, angleFenceFor(snapped));
      let changed = false;
      for (const [id, cell] of next) {
        const before = current.get(id);
        if (!before || before.col !== cell.col || before.row !== cell.row) {
          changed = true;
          break;
        }
      }
      current = next;
      if (!changed) break;
    }
    return current;
  };

  // CHEWY PATCH: mode resolution. regionData is needed both by the full
  // pipeline's geographic k-space layout (kspaceMode === 'geographic') and
  // by classifyNodes/placeIncrementalNodes' lattice-order check whenever we
  // might not go straight to 'full' — load it once, up front, and reuse it
  // for whichever path actually runs.
  const regionData =
    kspaceClusters.length > 0 && (kspaceMode === 'geographic' || requestedMode !== 'full')
      ? await loadRegionLayouts()
      : null;

  let resolvedMode: 'incremental' | 'full';
  let classification: NodeClassification | null = null;
  if (requestedMode === 'full') {
    resolvedMode = 'full';
  } else {
    classification = classifyNodes(nodes, gateEdges, chainEdges, kspaceMemberIds, regionData, chainStandoff);
    const eligibleCount = nodes.filter(n => !n.locked).length;
    const validFraction = eligibleCount > 0 ? classification.validCells.size / eligibleCount : 0;
    resolvedMode =
      requestedMode === 'incremental'
        ? 'incremental'
        : validFraction >= INCREMENTAL_VALID_FRACTION_THRESHOLD
          ? 'incremental'
          : 'full';
  }

  if (resolvedMode === 'incremental') {
    const incremental = placeIncrementalNodes(
      nodes,
      gateEdges,
      chainEdges,
      kspaceMemberIds,
      regionData,
      axis,
      classification!,
      chainStandoff,
    );

    // Lightweight rootId pick — mirrors step 3's partition below, without
    // the tree-layout math full mode needs (nothing here is re-laid-out).
    const chainOnlyIds = new Set([...nodeIds].filter(id => !kspaceMemberIds.has(id)));
    const attachmentIds = new Set<string>();
    for (const edge of chainEdges) {
      const sourceIsK = kspaceMemberIds.has(edge.source);
      const targetIsK = kspaceMemberIds.has(edge.target);
      if (sourceIsK && chainOnlyIds.has(edge.target)) attachmentIds.add(edge.source);
      if (targetIsK && chainOnlyIds.has(edge.source)) attachmentIds.add(edge.target);
    }
    const chainGraphIds = new Set([...chainOnlyIds, ...attachmentIds]);
    const chainGraphEdges = edgesWithin(chainEdges, chainGraphIds);
    const chainComponents = connectedComponents([...chainGraphIds], chainGraphEdges);

    let reportedRootId: string | null = null;
    let reportedRootSize = -1;
    for (const component of chainComponents) {
      const compIdSet = new Set(component);
      const compNodes = component.map(id => nodeById.get(id)!);
      const compEdges = edgesWithin(chainGraphEdges, compIdSet);
      const rootId =
        explicitRootId && compIdSet.has(explicitRootId)
          ? explicitRootId
          : (pickChainRoot(compNodes, compEdges, hubs) ?? component[0]);
      if (component.length > reportedRootSize || (explicitRootId && rootId === explicitRootId)) {
        reportedRootId = rootId;
        reportedRootSize = explicitRootId && rootId === explicitRootId ? Infinity : component.length;
      }
    }

    // CHEWY PATCH (local repair + smallest honest edit). Two things were
    // wrong with "place the invalid nodes and return":
    //
    //  1. Placing nodes is not the whole job. A map whose nodes are ALL
    //     individually "validly placed" can still hide connections — the
    //     live production map `yugen` had six links running under a foreign
    //     node box while this path returned ZERO moves for it. So the result
    //     now goes through the same bounded repair pass full mode uses (only
    //     nodes party to a real violation move, each capped at
    //     MAX_NODE_DISPLACEMENT_CELLS).
    //
    //  2. classifyNodes also re-places nodes that are merely out of lattice
    //     ORDER, which is a relative judgement — re-placing A changes whether
    //     B looks inverted. On a hand-built map that never settles: pressing
    //     beautify on live `yugen` moved 6, then 4, then 4 nodes with
    //     identical crossing/occlusion counts, and adding ONE system moved 10
    //     untouched ones and took crossings from 5 to 12 (placing just the
    //     new system: still 5).
    //
    // So build BOTH candidates — the engine's full suggestion, and the
    // minimal edit that only places nodes which are genuinely unplaced
    // (off-grid or stacked on another node) — repair each, and emit whichever
    // actually measures better. Ties go to the one that moves fewer systems,
    // so "already as good as we can make it" emits nothing at all.
    const placedCell = new Map<string, CellCoord>(
      Object.entries(incremental.positions).map(([id, position]) => [
        id,
        { col: Math.round(position.x / CELL_W), row: Math.round(position.y / CELL_H) },
      ]),
    );
    const occupiedInputCells = new Map<string, number>();
    for (const cell of inputCells.values()) {
      const cellKey = `${cell.col},${cell.row}`;
      occupiedInputCells.set(cellKey, (occupiedInputCells.get(cellKey) ?? 0) + 1);
    }
    const mustMoveIds = new Set(
      nodes
        .filter(n => {
          if (n.locked) return false;
          if (n.x % CELL_W !== 0 || n.y % CELL_H !== 0) return true;
          const cell = inputCells.get(n.id)!;
          return (occupiedInputCells.get(`${cell.col},${cell.row}`) ?? 0) > 1;
        })
        .map(n => n.id),
    );

    const candidateFor = (allowedIds: ReadonlySet<string> | null): Map<string, CellCoord> => {
      const cells = new Map(inputCells);
      for (const [id, cell] of placedCell) {
        if (!allowedIds || allowedIds.has(id)) cells.set(id, cell);
      }
      return reduceCrossings(cells, cleanEdges, movableIds, isCellAllowed);
    };

    // CHEWY PATCH: chains crowding the lattice count as defects too, or the
    // minimal candidate (which only places off-grid/stacked systems) always
    // ties on crossings and wins, leaving every existing chain exactly where
    // it was — measured on live yugen: auto mode moved 2 systems and left
    // clearance at 1 cell while a full re-solve moved the chains out.
    const crowdedCount = (cells: Map<string, CellCoord>): number => {
      if (chainStandoff <= 0) return 0;
      let count = 0;
      for (const [id, cell] of cells) {
        if (kspaceMemberIds.has(id) || nodeById.get(id)?.locked) continue;
        for (const memberId of kspaceMemberIds) {
          const member = cells.get(memberId);
          if (!member) continue;
          if (Math.max(Math.abs(cell.col - member.col), Math.abs(cell.row - member.row)) < chainStandoff) {
            count += 1;
            break;
          }
        }
      }
      return count;
    };

    // CHEWY PATCH: angle discipline is applied to the WINNER, never to the
    // candidates. Scoring snapped candidates instead changed which one wins,
    // and the chosen one then differed from press to press: the bench's
    // `occlusion` scenario stopped being idempotent and yugen's round-trip
    // churn tripled (movedFrac 0.08 -> 0.27). Which layout is best is a
    // question about crossings, hidden connections and crowding; angles are
    // polish applied afterwards.
    const candidates = [candidateFor(mustMoveIds), candidateFor(null)].map(cells => {
      const quality = measureLayout(cleanEdges, cells);
      return { cells, quality, score: defectScore(quality) + crowdedCount(cells), movedCount: emit(cells).movedCount };
    });
    const best = candidates.reduce((a, b) =>
      b.score < a.score || (b.score === a.score && b.movedCount < a.movedCount) ? b : a,
    );
    const finalCells = settle(best.cells);
    const finalQuality = measureLayout(cleanEdges, finalCells);
    const emitted = emit(finalCells);

    return {
      positions: emitted.positions,
      rootId: reportedRootId,
      movedCount: emitted.movedCount,
      mode: 'incremental',
      quality: { before: inputQuality, after: finalQuality },
    };
  }

  // --- 2. Chain attachment points -----------------------------------------
  //
  // CHEWY PATCH: which k-space systems have a wormhole chain hanging off them.
  // With `chainStandoff` on, those chains are pushed out of the lattice
  // entirely (see step 4) instead of growing through it.
  const chainAnchorIds = new Set<string>();
  if (chainStandoff > 0) {
    for (const edge of chainEdges) {
      if (kspaceMemberIds.has(edge.source) && !kspaceMemberIds.has(edge.target)) {
        chainAnchorIds.add(edge.source);
      }
      if (kspaceMemberIds.has(edge.target) && !kspaceMemberIds.has(edge.source)) {
        chainAnchorIds.add(edge.target);
      }
    }
  }

  // --- 3. K-space geographic set + topological fallback -------------------

  const boxes: LayoutBox[] = [];
  /** k-space node id -> its proposed (pre-pack) global cell, used to seed wormhole-chain attachment anchors. */
  const kspaceProposedCell = new Map<string, CellCoord>();

  if (kspaceMode === 'geographic') {
    // ONE box for every cluster member that resolves to a GLOBAL lattice
    // cell, regardless of which gate component or region it belongs to —
    // compressing this whole set together (inside layoutGeographicSet) is
    // what keeps relative position meaningful across region boundaries.
    const allMembers = kspaceClusters.flat().map(id => nodeById.get(id)!);
    const geo = layoutGeographicSet('kspace:geo', allMembers, regionData);
    if (geo.result) {
      boxes.push(geo.result.box);
      for (const [id, cell] of geo.result.proposedCells) kspaceProposedCell.set(id, cell);
    }

    // Members with no lattice entry (wormhole space, abyssal, data gaps)
    // fall back to a per-cluster topological group, scoped to just that
    // cluster's missing members, exactly as before.
    kspaceClusters.forEach((cluster, clusterIndex) => {
      const missingIds = cluster.filter(id => geo.missingIds.has(id));
      if (missingIds.length === 0) return;
      const members = missingIds.map(id => nodeById.get(id)!);
      const clusterGateEdges = edgesWithin(gateEdges, new Set(cluster));
      const groupGateEdges = edgesWithin(clusterGateEdges, new Set(missingIds));
      const result = layoutTopologicalGroup(`kspace:topo:${clusterIndex}`, members, groupGateEdges, axis, hubs);
      boxes.push(result.box);
      for (const [id, cell] of result.proposedCells) kspaceProposedCell.set(id, cell);
    });
  } else {
    kspaceClusters.forEach((cluster, clusterIndex) => {
      const members = cluster.map(id => nodeById.get(id)!);
      const clusterGateEdges = edgesWithin(gateEdges, new Set(cluster));
      const result = layoutTopologicalGroup(`kspace:${clusterIndex}`, members, clusterGateEdges, axis, hubs);
      boxes.push(result.box);
      for (const [id, cell] of result.proposedCells) kspaceProposedCell.set(id, cell);
    });
  }

  // CHEWY PATCH: k-space member id -> the box object that already contains
  // it, built once here (before step 3 pushes any chain boxes) so an
  // attached wormhole-chain can fold directly into its anchor's box below
  // instead of becoming a separate obstacle that box has to dodge — see
  // the comment where this map is used.
  const kspaceBoxByMemberId = new Map<string, LayoutBox>();
  for (const box of boxes) {
    for (const id of box.cells.keys()) kspaceBoxByMemberId.set(id, box);
  }

  // --- 3. Wormhole-chain forest --------------------------------------------

  const chainOnlyIds = new Set([...nodeIds].filter(id => !kspaceMemberIds.has(id)));
  const attachmentIds = new Set<string>();
  for (const edge of chainEdges) {
    const sourceIsK = kspaceMemberIds.has(edge.source);
    const targetIsK = kspaceMemberIds.has(edge.target);
    if (sourceIsK && chainOnlyIds.has(edge.target)) attachmentIds.add(edge.source);
    if (targetIsK && chainOnlyIds.has(edge.source)) attachmentIds.add(edge.target);
  }

  const chainGraphIds = new Set([...chainOnlyIds, ...attachmentIds]);
  const chainGraphEdges = edgesWithin(chainEdges, chainGraphIds);
  const chainComponents = connectedComponents([...chainGraphIds], chainGraphEdges);

  let reportedRootId: string | null = null;
  let reportedRootSize = -1;

  for (const component of chainComponents) {
    const compIdSet = new Set(component);
    const compNodes = component.map(id => nodeById.get(id)!);
    const compEdges = edgesWithin(chainGraphEdges, compIdSet);

    // K-space attachment points already have an authoritative position;
    // substitute it in so anchor/tie-break math sees the real location.
    const effectiveNodes: LayoutNodeInput[] = compNodes.map(n => {
      const proposed = kspaceMemberIds.has(n.id) ? kspaceProposedCell.get(n.id) : undefined;
      return proposed ? { ...n, x: proposed.col * CELL_W, y: proposed.row * CELL_H } : n;
    });
    const effectiveById = new Map(effectiveNodes.map(n => [n.id, n]));

    // Anchor = nearest pinned (locked, or an already-positioned k-space
    // attachment) node to the root; falls back to the root itself. Computed
    // before rootId below since a pin, when one exists, now determines the
    // root too (see the CHEWY PATCH comment there).
    const pinnedCandidates = component.filter(id => nodeById.get(id)!.locked || kspaceMemberIds.has(id));

    const rootId =
      explicitRootId && compIdSet.has(explicitRootId)
        ? explicitRootId
        : pinnedCandidates.length > 0
          ? // CHEWY PATCH: root at a pinned node instead of pickChainRoot's
            // centroid-style heuristic whenever one exists. Proven failure
            // mode (dev/layout-bench.mjs "mixed" scenario): pickChainRoot
            // returns a DIFFERENT root for the same chain whenever a new
            // leaf lands anywhere except its current tail, and a different
            // root re-derives the WHOLE tree's local layout from scratch —
            // verified directly to fully mirror a 10-node linear chain's
            // order (every node's relative position reversed) from a single
            // new leaf off its middle node. A pin's identity never changes
            // across growth (growth only adds leaves, never a new
            // attachment point to an already-existing component), so
            // sorting for the smallest id gives a canonical, always-stable
            // choice; rooting there makes the tree's shape a pure function
            // of the tree's own topology, immune to where a new leaf lands.
            [...pinnedCandidates].sort()[0]
          : (pickChainRoot(compNodes, compEdges, hubs) ?? component[0]);

    if (component.length > reportedRootSize || (explicitRootId && rootId === explicitRootId)) {
      reportedRootId = rootId;
      reportedRootSize = explicitRootId && rootId === explicitRootId ? Infinity : component.length;
    }

    // CHEWY PATCH (chain pockets): a chain hanging off a k-space system grows
    // along the CROSS axis when standoff is on, so it runs OUT of the lattice
    // (down, for the default left-to-right layout) instead of along it.
    const componentHasLatticeAnchor = chainStandoff > 0 && component.some(id => chainAnchorIds.has(id));
    const chainAxis: BeautifyAxis = componentHasLatticeAnchor
      ? axis === 'left_to_right'
        ? 'top_to_bottom'
        : 'left_to_right'
      : axis;
    const { localCells, depths } = layoutChainTree(effectiveNodes, compEdges, chainAxis, rootId);

    let anchorId = rootId;
    if (pinnedCandidates.length > 0) {
      let bestDepth = Infinity;
      for (const id of pinnedCandidates) {
        const depth = depths.get(id) ?? Infinity;
        if (depth < bestDepth || (depth === bestDepth && id < anchorId)) {
          bestDepth = depth;
          anchorId = id;
        }
      }
    }

    const anchorLocal = localCells.get(anchorId);
    const anchorNode = effectiveById.get(anchorId);
    const dCol = anchorLocal && anchorNode ? Math.round(anchorNode.x / CELL_W) - anchorLocal.col : 0;
    const dRow = anchorLocal && anchorNode ? Math.round(anchorNode.y / CELL_H) - anchorLocal.row : 0;

    const cells = new Map<string, CellCoord>();
    for (const id of component) {
      if (kspaceMemberIds.has(id)) continue; // authoritative position lives in the geographic set or a topological k-space box
      const local = localCells.get(id);
      if (!local) continue; // unreachable in this edge set (shouldn't happen for a real component)
      cells.set(id, { col: local.col + dCol, row: local.row + dRow });
    }

    if (cells.size === 0) continue; // every member was a k-space attachment point; nothing new to place

    // CHEWY PATCH (chain standoff): a chain hanging off a k-space system used
    // to start in the cell immediately next to it. On a Dotlan-geometry
    // cluster — whose own gate gaps are compressed to a single cell
    // (kspaceLayout.ts LOCAL_PACK_CELLS) — that means the chain grows straight
    // through the lattice the user navigates by, and there is no free cell
    // beside the anchor to move it into.
    //
    // So the chain is moved OUT of the lattice instead of inside it: it keeps
    // its anchor's column (so it still reads as hanging off that system) and
    // starts `chainStandoff` cells past the lattice's own edge on whichever
    // side its anchor is closer to, growing further out from there. The
    // lattice itself is not touched at all — no reserved lanes, no stretched
    // gate edges (a first attempt reserved lanes INSIDE the lattice and blew
    // yugen's mean gate edge from 3.3 to 7.3 cells, which is exactly the
    // Dotlan readability this is supposed to protect).
    if (chainStandoff > 0 && chainAnchorIds.has(anchorId)) {
      const anchorCell = kspaceProposedCell.get(anchorId);
      const latticeCells = [...kspaceProposedCell.values()];
      if (anchorCell && latticeCells.length > 0) {
        const alongRows = axis !== 'top_to_bottom';
        const values = latticeCells.map(cell => (alongRows ? cell.row : cell.col));
        const low = Math.min(...values);
        const high = Math.max(...values);
        const anchorValue = alongRows ? anchorCell.row : anchorCell.col;
        // Nearest lattice edge, so the connector back to the anchor stays as
        // short as the geometry allows; ties go to the high side for a stable,
        // predictable "chains hang below the map" reading.
        const useHighSide = high - anchorValue <= anchorValue - low;
        const edgeValue = useHighSide ? high + chainStandoff + 1 : low - chainStandoff - 1;

        const rootCell = cells.get(rootId) ?? [...cells.values()][0];
        const shiftCol = alongRows ? anchorCell.col - rootCell.col : edgeValue - rootCell.col;
        const shiftRow = alongRows ? edgeValue - rootCell.row : anchorCell.row - rootCell.row;
        // The tree grows along the cross axis from its root; flip it so it
        // grows AWAY from the lattice when hanging off the low side.
        const flip = useHighSide ? 1 : -1;
        for (const [id, cell] of cells) {
          const col = alongRows ? cell.col + shiftCol : rootCell.col + shiftCol + (cell.col - rootCell.col) * flip;
          const row = alongRows ? rootCell.row + shiftRow + (cell.row - rootCell.row) * flip : cell.row + shiftRow;
          cells.set(id, { col, row });
        }
      }
    }

    // CHEWY PATCH: if this chain is anchored to a k-space member, fold its
    // cells directly into that member's OWN box instead of pushing a
    // separate (fixed, unmovable) box. Proven failure mode: packBoxes'
    // collision search (pack.ts) treats every box as independent, so a
    // tiny fixed chain box sitting right next to its own anchor forced the
    // ENTIRE k-space box (all of its members) to dodge it — and WHICH
    // direction/how far depended on the k-space box's exact proposed rect,
    // which shifts slightly on almost every insertion even though relative
    // order among k-space members never does (verified: layoutGeographicSet's
    // own proposed cells are order-preserving in isolation). That produced
    // a large, direction-flipping whole-cluster relocation on most growth
    // steps, entirely unrelated to any real edge crossing. Folding into one
    // box means the attachment and its anchor now move together as a
    // single unit (or, the common case, don't move at all) instead of the
    // anchor's own box treating its dependent as a foreign obstacle.
    const anchorBox = kspaceMemberIds.has(anchorId) ? kspaceBoxByMemberId.get(anchorId) : undefined;
    if (anchorBox) {
      for (const [id, cell] of cells) anchorBox.cells.set(id, cell);
    } else {
      boxes.push({ id: `chain:${rootId}`, cells, fixed: pinnedCandidates.length > 0 });
    }
  }

  // --- 4. Pack everything onto one grid, then cheaply de-cross it ---------

  const packedCells = packBoxes(boxes);
  // CHEWY PATCH: final deterministic improvement pass (see pack.ts) —
  // relocates movable nodes into free adjacent cells, or swaps a pair that
  // are endpoints of the same crossing, evaluated canonically (not
  // first-come) each sweep and displacement-capped. Only nodes that aren't
  // locked are eligible, so locked nodes never move.
  const packedRepaired = reduceCrossings(packedCells, cleanEdges, movableIds, isCellAllowed);
  const packedQuality = measureLayout(cleanEdges, packedRepaired);

  // --- 5. Auto-mode regression guard --------------------------------------
  //
  // CHEWY PATCH: a from-scratch re-solve is not automatically better than
  // the map the user built. Measured on the live `yugen` map: full mode
  // rewrites nearly every position and, on the 40-system snapshot, doubles
  // the crossing count (5 -> 10) and adds 14% edge length for the same zero
  // hidden connections a bounded repair of the user's own layout achieves by
  // moving 11 nodes. When the user asks for 'full' explicitly that is their
  // call and it is applied as-is; when 'auto' picked full on their behalf,
  // the alternative (repair what they already have) is scored too and the
  // better of the two wins.
  // The guard only applies to an input layout that is itself well-formed
  // (every unlocked node exactly on the grid, no two nodes in one cell).
  // When 'auto' falls back to full because the map is genuinely unplaced —
  // off-grid imports, stacked nodes — keeping it is never the better answer,
  // and a 2-cell-capped repair cannot fix it either.
  if (requestedMode === 'auto' && inputWellFormed) {
    // Both alternatives are scored BEFORE angle discipline, for the reason
    // the incremental path documents: which layout is best must not depend on
    // a polish step, or the answer changes from press to press.
    const repaired = reduceCrossings(inputCells, cleanEdges, movableIds, isCellAllowed);
    if (qualityScore(measureLayout(cleanEdges, repaired)) < qualityScore(packedQuality)) {
      const settled = settle(repaired);
      const repairedEmit = emit(settled);
      return {
        positions: repairedEmit.positions,
        rootId: reportedRootId,
        movedCount: repairedEmit.movedCount,
        mode: 'incremental',
        quality: { before: inputQuality, after: measureLayout(cleanEdges, settled) },
      };
    }
  }

  const globalCells = settle(packedRepaired);
  const fullQuality = measureLayout(cleanEdges, globalCells);

  // --- 6. Emit only genuinely-changed, unlocked nodes ----------------------

  const { positions, movedCount } = emit(globalCells);

  return {
    positions,
    rootId: reportedRootId,
    movedCount,
    mode: 'full',
    quality: { before: inputQuality, after: fullQuality },
  };
};

/**
 * CHEWY PATCH: how many extra passes one button press is allowed to run.
 * Real maps need at most two (the second returns "nothing moved"); the cap
 * only bounds a pathological input.
 */
const MAX_CONVERGENCE_PASSES = 4;

/**
 * Beautify to convergence: run the pipeline until a pass reports nothing left
 * to move, and emit the combined result as one edit.
 *
 * A single pass is not a fixed point of itself, and never was — placement
 * feeds repair feeds angle discipline, and each one changes what the next can
 * see. Before this, pressing the button twice in a row kept moving systems:
 * the bench's `occlusion` scenario settled on press two or three, which reads
 * to a user as "the button didn't finish" and to the bench as a failed
 * idempotence check. Converging here costs one or two extra passes of pure
 * computation (no re-render, no server round trip) and makes one press mean
 * one press.
 *
 * Only `angleSnap` layouts converge. Without it the pipeline is already a
 * fixed point on every bench scenario, and re-running it is not free of
 * consequence: it re-enters placement, which is what the round-trip
 * stability numbers measure.
 *
 * The reported `mode`, `rootId` and `quality.before` are the FIRST pass's —
 * they describe what the user's map was and which algorithm decided its
 * shape. `positions`/`movedCount` are cumulative against the input, and
 * `quality.after` is the layout actually emitted.
 */
export const beautifyLayout = async (
  nodes: LayoutNodeInput[],
  edges: LayoutEdgeInput[],
  options: BeautifyOptions = {},
): Promise<LayoutResult> => {
  const first = await beautifyOnce(nodes, edges, options);
  if (options.angleSnap !== true || first.movedCount === 0) return first;

  const merged: Record<string, { x: number; y: number }> = { ...first.positions };
  let current = nodes.map(node => (merged[node.id] ? { ...node, ...merged[node.id] } : node));
  let last = first;

  // A follow-up pass is allowed to CORRECT the last one, not to re-solve the
  // map. Anything bigger than a handful of systems is a second opinion about
  // the whole layout, and taking it re-enters placement: on the bench's
  // round-trip test (add k systems, beautify again) an unlimited follow-up
  // moved a quarter of yugen and reordered 5.2 system pairs, against 0.10 and
  // 1.2 for the same map with the follow-up capped. Real leftovers — a chain
  // system the placement left one cell inside the standoff zone — are one or
  // two systems.
  const correctionLimit = Math.max(2, Math.ceil(nodes.length * 0.05));

  for (let pass = 0; pass < MAX_CONVERGENCE_PASSES; pass++) {
    const next = await beautifyOnce(current, edges, options);
    if (next.movedCount === 0 || next.movedCount > correctionLimit) break;
    for (const [id, position] of Object.entries(next.positions)) merged[id] = position;
    current = current.map(node => (next.positions[node.id] ? { ...node, ...next.positions[node.id] } : node));
    last = next;
  }

  // A system can be moved by one pass and moved back by another; only report
  // the systems whose final cell differs from the one they came in with.
  const positions: Record<string, { x: number; y: number }> = {};
  const byId = new Map(nodes.map(node => [node.id, node]));
  for (const [id, position] of Object.entries(merged)) {
    const original = byId.get(id);
    if (!original || (original.x === position.x && original.y === position.y)) continue;
    positions[id] = position;
  }

  return {
    positions,
    rootId: first.rootId,
    movedCount: Object.keys(positions).length,
    mode: first.mode,
    quality: { before: first.quality.before, after: last.quality.after },
  };
};
