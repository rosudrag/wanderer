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

/**
 * Rendered node box size in pixels (convertSystem2Node.ts / DotlanEdge.tsx's
 * own fallback constants). Connections are drawn as straight centre-to-centre
 * lines under these boxes, so any geometry check that wants to answer "can
 * the user see this link" has to reason about the box, not the cell centre.
 */
export const NODE_W_PX = 130;
export const NODE_H_PX = 34;

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
  /**
   * CHEWY PATCH: extra cells of clearance between a wormhole chain and the
   * k-space system it hangs off (`WANDERER_CHAIN_STANDOFF`). 0 (default) is
   * upstream behaviour: the chain root sits in the cell immediately next to
   * its anchor, which on a Dotlan-geometry k-space cluster means the chain
   * grows straight through the lattice it should be readable against.
   * A value of n pushes the whole chain n further cells away from its
   * anchor, opening a pocket of empty grid between the two.
   */
  chainStandoff?: number;
  /**
   * CHEWY PATCH: quantize connection directions (`WANDERER_ANGLE_SNAP`).
   * false (default) is upstream behaviour: a connection is drawn at whatever
   * angle the two systems' cells happen to produce, so a map ends up with as
   * many distinct line directions as it has links and reads as noise. true
   * runs octilinear.ts's final pass, which nudges systems (never further than
   * 3 cells, never into a crossing or a hidden link) until their connections
   * run along geometry.ts's ANGLE_DIRECTIONS.
   */
  angleSnap?: boolean;
}

/**
 * CHEWY PATCH: how readable a layout is, in the terms the engine optimises.
 * `occlusions`/`overlaps` are hidden connections (a node box drawn over a
 * link, or a link drawn inside another), which cost a user far more than a
 * visible crossing — see pack.ts's weights.
 */
export interface LayoutQuality {
  crossings: number;
  overlaps: number;
  occlusions: number;
  /** Total drawn edge length, in cells. */
  edgeLength: number;
  /**
   * CHEWY PATCH: connections drawn at an angle outside geometry.ts's
   * ANGLE_DIRECTIONS. Reported always; only acted on when
   * `BeautifyOptions.angleSnap` is set. Deliberately NOT part of
   * `qualityScore` — a tidier angle must never outrank a crossing or a
   * hidden connection.
   */
  offAngle: number;
}

export interface LayoutResult {
  positions: Record<string, { x: number; y: number }>;
  rootId: string | null;
  movedCount: number;
  /** Which algorithm actually ran — see BeautifyOptions.mode. */
  mode: 'incremental' | 'full';
  /**
   * CHEWY PATCH: quality of the layout the caller passed in vs the one this
   * result produces. Lets the UI say what actually improved, and lets
   * `mode: 'auto'` refuse a re-solve that would make the map worse.
   */
  quality: { before: LayoutQuality; after: LayoutQuality };
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
