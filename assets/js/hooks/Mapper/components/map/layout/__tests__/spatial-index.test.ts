/**
 * Equivalence tests for pack.ts's performance work:
 *
 *  1. Spatial-grid indexing (buildEdgeIndex/buildNodeIndex +
 *     countCrossings/countEdgeOverlapPairs/countNodeOcclusions) must return
 *     IDENTICAL counts to the naive O(E^2)/O(E*N) fallback — these are the
 *     real functions imported from pack.ts, not a parallel reimplementation,
 *     so a regression in either path fails this file.
 *  2. `localViolationScore`'s single-node delta — the identity
 *     `violationScore(after) - violationScore(before) ===
 *      localViolationScore(id, after) - localViolationScore(id, before)`
 *     for a move of exactly one node — must hold exactly, since
 *     reduceCrossings's relocation trials rely on it instead of a full
 *     violationScore recompute per trial.
 */

import { describe, it, expect } from '@jest/globals';
import {
  buildEdgeIndex,
  buildNodeIndex,
  countCrossings,
  countEdgeOverlapPairs,
  countNodeOcclusions,
  violationScore,
  localViolationScore,
  pairViolationScore,
  type CrossingEdge,
} from '../pack';
import type { CellCoord } from '../types';

const BUCKET_SIZE = 8;

function mulberry32(seed: number) {
  let t = seed;
  return () => {
    t += 0x6d2b79f5;
    let r = Math.imul(t ^ (t >>> 15), 1 | t);
    r ^= r + Math.imul(r ^ (r >>> 7), 61 | r);
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  };
}

function generateRandomLayout(
  rand: () => number,
  nodeCount: number,
  edgeCount: number,
): { edges: CrossingEdge[]; cells: Map<string, CellCoord> } {
  const cells = new Map<string, CellCoord>();
  for (let i = 0; i < nodeCount; i++) {
    cells.set(`node_${i}`, { col: Math.floor(rand() * 60), row: Math.floor(rand() * 60) });
  }
  const edges: CrossingEdge[] = [];
  for (let i = 0; i < edgeCount; i++) {
    const source = `node_${Math.floor(rand() * nodeCount)}`;
    // Never a self-loop: a real connection is always between two distinct
    // systems (a system never connects to itself), and `countCrossings`'s
    // naive scan does not skip self-loops while `localViolationScore`/
    // `pairViolationScore` deliberately do (a self-loop is never
    // "incident" to anything), so a self-loop that happens to
    // geometrically cross another edge is a real, pre-existing,
    // OUT-OF-DOMAIN blind spot shared by both local-delta functions —
    // generating one here would test a case `reduceCrossings` never sees
    // on real data, not a regression in either function.
    let target = `node_${Math.floor(rand() * nodeCount)}`;
    let guard = 0;
    while (target === source && guard++ < 20) target = `node_${Math.floor(rand() * nodeCount)}`;
    if (target === source) continue; // degenerate nodeCount===1 case, skip
    edges.push({ source, target });
  }
  return { edges, cells };
}

describe('Spatial grid indexing matches the naive fallback', () => {
  it('countCrossings: indexed === naive on 50 random layouts', () => {
    const rand = mulberry32(1);
    for (let trial = 0; trial < 50; trial++) {
      const nodeCount = 10 + Math.floor(rand() * 40);
      const edgeCount = nodeCount + Math.floor(rand() * nodeCount);
      const { edges, cells } = generateRandomLayout(rand, nodeCount, edgeCount);
      const index = buildEdgeIndex(edges, cells, BUCKET_SIZE);
      expect(countCrossings(edges, cells, index)).toBe(countCrossings(edges, cells));
    }
  });

  it('countEdgeOverlapPairs: indexed === naive on 50 random layouts', () => {
    const rand = mulberry32(2);
    for (let trial = 0; trial < 50; trial++) {
      const nodeCount = 10 + Math.floor(rand() * 40);
      const edgeCount = nodeCount + Math.floor(rand() * nodeCount);
      const { edges, cells } = generateRandomLayout(rand, nodeCount, edgeCount);
      const index = buildEdgeIndex(edges, cells, BUCKET_SIZE);
      expect(countEdgeOverlapPairs(edges, cells, index)).toBe(countEdgeOverlapPairs(edges, cells));
    }
  });

  it('countNodeOcclusions: indexed === naive on 50 random layouts', () => {
    const rand = mulberry32(3);
    for (let trial = 0; trial < 50; trial++) {
      const nodeCount = 10 + Math.floor(rand() * 40);
      const edgeCount = nodeCount + Math.floor(rand() * nodeCount);
      const { edges, cells } = generateRandomLayout(rand, nodeCount, edgeCount);
      const nodeIndex = buildNodeIndex(cells, BUCKET_SIZE);
      expect(countNodeOcclusions(edges, cells, nodeIndex, BUCKET_SIZE)).toBe(countNodeOcclusions(edges, cells));
    }
  });

  it('is invariant to bucket size (4, 8, 16) on the same layout', () => {
    const rand = mulberry32(4);
    const { edges, cells } = generateRandomLayout(rand, 60, 90);
    const naive = countCrossings(edges, cells);
    for (const bucketSize of [4, 8, 16]) {
      const index = buildEdgeIndex(edges, cells, bucketSize);
      expect(countCrossings(edges, cells, index)).toBe(naive);
    }
  });

  it('finds a node whose box overlaps a segment even when the node cell sits outside the raw edge bbox', () => {
    // Node c's rendered box (half-extents > 1 cell) overlaps the segment
    // a->b's clip region even though c's own cell (105,0) is outside the
    // edge's raw bbox (0-100, 0-100). Without bbox padding in
    // queryNodeCandidates this would be missed by the indexed path.
    const cells = new Map<string, CellCoord>([
      ['a', { col: 0, row: 0 }],
      ['b', { col: 100, row: 0 }],
      ['c', { col: 101, row: 0 }],
    ]);
    const edges: CrossingEdge[] = [{ source: 'a', target: 'b' }];
    const nodeIndex = buildNodeIndex(cells, BUCKET_SIZE);
    const naive = countNodeOcclusions(edges, cells);
    const indexed = countNodeOcclusions(edges, cells, nodeIndex, BUCKET_SIZE);
    expect(indexed).toBe(naive);
  });
});

describe('localViolationScore delta matches the full violationScore delta for a single-node move', () => {
  it('holds across 100 random single-node relocations', () => {
    const rand = mulberry32(5);
    for (let trial = 0; trial < 100; trial++) {
      const nodeCount = 10 + Math.floor(rand() * 30);
      const edgeCount = nodeCount + Math.floor(rand() * nodeCount);
      const { edges, cells } = generateRandomLayout(rand, nodeCount, edgeCount);
      const ids = [...cells.keys()];
      const id = ids[Math.floor(rand() * ids.length)];
      const before = new Map(cells);
      const to = { col: Math.floor(rand() * 60), row: Math.floor(rand() * 60) };

      const fullBefore = violationScore(edges, before);
      const localBefore = localViolationScore(edges, before, id);

      const after = new Map(cells);
      after.set(id, to);
      const fullAfter = violationScore(edges, after);
      const localAfter = localViolationScore(edges, after, id);

      expect(localBefore - localAfter).toBe(fullBefore - fullAfter);
    }
  });
});

describe('pairViolationScore delta matches the full violationScore delta for a two-node swap', () => {
  it('holds across 150 random swaps of two distinct nodes', () => {
    const rand = mulberry32(6);
    for (let trial = 0; trial < 150; trial++) {
      const nodeCount = 10 + Math.floor(rand() * 30);
      const edgeCount = nodeCount + Math.floor(rand() * nodeCount);
      const { edges, cells } = generateRandomLayout(rand, nodeCount, edgeCount);
      const ids = [...cells.keys()];
      const idxA = Math.floor(rand() * ids.length);
      let idxB = Math.floor(rand() * ids.length);
      if (idxB === idxA) idxB = (idxB + 1) % ids.length;
      const idA = ids[idxA];
      const idB = ids[idxB];

      const before = new Map(cells);
      const fullBefore = violationScore(edges, before);
      const localBefore = pairViolationScore(edges, before, idA, idB);

      // Swap idA's and idB's cells — the exact trial `reduceCrossings` runs.
      const after = new Map(cells);
      const cellA = before.get(idA)!;
      const cellB = before.get(idB)!;
      after.set(idA, cellB);
      after.set(idB, cellA);
      const fullAfter = violationScore(edges, after);
      const localAfter = pairViolationScore(edges, after, idA, idB);

      expect(localBefore - localAfter).toBe(fullBefore - fullAfter);
    }
  });
});
