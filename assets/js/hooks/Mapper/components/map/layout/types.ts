// Shared type & constant definitions for the map beautifier layout engine.
// Pure data types only — no React, no side effects, no domain-specific
// coupling to the rest of the Mapper UI beyond the shapes the caller hands
// us (see the public API in ./index.ts).

/**
 * Grid pitch. Node is 130x34px, margins 50x/41y
 * (lib/wanderer_app/map/map_position_calculator.ex). Every beautified
 * position is an integer multiple of these.
 */
export const CELL_W = 180;
export const CELL_H = 75;

export type BeautifyAxis = 'left_to_right' | 'top_to_bottom';
export type KSpaceMode = 'geographic' | 'topological';

export interface LayoutNodeInput {
  id: string;
  x: number;
  y: number;
  locked: boolean;
  regionId?: number;
  systemClass?: number;
  security?: number;
  name?: string;
}

/** Connection type: 0 wormhole, 1 gate, 2 bridge. */
export interface LayoutEdgeInput {
  source: string;
  target: string;
  type: number;
}

export interface BeautifyOptions {
  axis?: BeautifyAxis;
  rootId?: string | null;
  hubs?: string[];
  kspaceMode?: KSpaceMode;
  /**
   * 'full' — re-solve every node from scratch (today's behaviour).
   * 'incremental' — keep every already-validly-placed node exactly where
   *   it is; place only the nodes that are new or out of place (see
   *   anchor.ts).
   * 'auto' (default) — pick 'incremental' when the input already looks
   *   laid out, else 'full' (see beautifyLayout's mode-resolution doc in
   *   index.ts). This is what makes "beautify after adding one system"
   *   stable without ever needing an explicit flag from the caller.
   */
  mode?: 'auto' | 'incremental' | 'full';
}

export interface LayoutResult {
  positions: Record<string, { x: number; y: number }>;
  rootId: string | null;
  movedCount: number;
  /** Which algorithm actually ran — see BeautifyOptions.mode. */
  mode: 'incremental' | 'full';
}

/** Integer cell coordinate (pre pixel-conversion). */
export interface CellCoord {
  col: number;
  row: number;
}

/**
 * A placement unit handed to pack.ts: a wormhole chain tree or a k-space
 * region group, already laid out and translated into its own *proposed*
 * global cell space by its producer (chainLayout.ts / kspaceLayout.ts /
 * index.ts). Pack.ts only ever applies a uniform integer shift to a whole
 * box (never rearranges cells within it) and only when `fixed` is false.
 */
export interface LayoutBox {
  /** Stable id, used only for deterministic sort tie-breaking. */
  id: string;
  /** node id -> proposed global cell coordinate. */
  cells: Map<string, CellCoord>;
  /**
   * true = this box contains a locked node or is anchored to a k-space node
   * whose position is already authoritative elsewhere; it must be placed
   * exactly as given, never shifted by pack.ts's collision resolution.
   */
  fixed: boolean;
}
