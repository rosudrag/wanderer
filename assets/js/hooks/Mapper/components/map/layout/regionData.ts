// Lazy loader + typing for the precomputed GLOBAL k-space lattice layout
// data (assets/js/hooks/Mapper/components/map/layout/data/regionLayouts.json,
// generated offline from the Fuzzwork SDE mapSolarSystems dump). Every
// known-space system in New Eden shares ONE lattice — see kspaceLayout.ts
// for why per-region grids can't produce meaningful relative positions
// across a region border. The JSON is sizeable, so it is dynamically
// imported and cached — that keeps it out of the main bundle and out of
// any code path that never runs geographic k-space layout.

import type { CellCoord } from './types';

export interface RegionLayoutData {
  version: number;
  generatedAt: string;
  source: string;
  /** regionId (string) -> region name; display/debugging only, not used for layout lookups. */
  regions: Record<string, string>;
  /** solarSystemId (string) -> GLOBAL [col, row] on the one shared lattice. */
  systems: Record<string, [number, number]>;
}

let cache: Promise<RegionLayoutData | null> | null = null;

/**
 * Loads and caches the lattice dataset. Resolves to `null` (rather than
 * throwing) if the data file is missing or malformed, so geographic
 * k-space layout can gracefully fall back to topological layout instead of
 * failing the whole beautify pass.
 */
export const loadRegionLayouts = (): Promise<RegionLayoutData | null> => {
  if (!cache) {
    cache = import('./data/regionLayouts.json')
      .then((mod: unknown) => {
        const data = hasDefaultExport(mod) ? mod.default : mod;
        return isRegionLayoutData(data) ? data : null;
      })
      .catch(() => null);
  }
  return cache;
};

const hasDefaultExport = (value: unknown): value is { default: unknown } =>
  typeof value === 'object' && value !== null && 'default' in value;

const isRegionLayoutData = (value: unknown): value is RegionLayoutData => {
  if (typeof value !== 'object' || value === null) return false;
  if (!('systems' in value)) return false;
  return typeof value.systems === 'object' && value.systems !== null;
};

/** Looks up a k-space system's GLOBAL cell coordinate on the shared lattice, or null if the system is unknown/missing. */
export const getGlobalSystemCell = (data: RegionLayoutData | null, solarSystemId: string): CellCoord | null => {
  if (!data) return null;
  const cell = data.systems[solarSystemId];
  return cell ? { col: cell[0], row: cell[1] } : null;
};
