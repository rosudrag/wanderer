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

import type { CellCoord, LayoutBox } from './types';

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

const areaOf = (r: Rect): number => (r.maxCol - r.minCol + 1) * (r.maxRow - r.minRow + 1);

export const packBoxes = (boxes: LayoutBox[]): Map<string, CellCoord> => {
  const placedRects: Rect[] = [];
  // (id, cell, priority) triples in deterministic placement order; later
  // entries win ties in the final per-cell dedupe pass below.
  const ordered: Array<{ id: string; cell: CellCoord }> = [];

  const fixedBoxes = [...boxes.filter(b => b.fixed)].sort((a, b) => a.id.localeCompare(b.id));
  const floatBoxes = [...boxes.filter(b => !b.fixed)].sort((a, b) => {
    const areaDiff = areaOf(rectOf(b.cells)) - areaOf(rectOf(a.cells));
    return areaDiff !== 0 ? areaDiff : a.id.localeCompare(b.id);
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
 * (fixed boxes first, then largest-first floating boxes) keep their exact
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
