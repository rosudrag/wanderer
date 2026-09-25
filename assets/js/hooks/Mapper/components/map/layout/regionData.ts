// Lazy loader + typing for the precomputed per-region Dotlan-like layout
// data (assets/js/hooks/Mapper/components/map/layout/data/regionLayouts.json,
// generated offline from the Fuzzwork SDE mapSolarSystems dump). The JSON is
// sizeable (every known-space region), so it is dynamically imported and
// cached — that keeps it out of the main bundle and out of any code path
// that never runs geographic k-space layout.

export interface RegionLayoutEntry {
  name: string;
  /** Region's position in shared, universe-projected CELL units. */
  centroid: [number, number];
  /** [maxCol + 1, maxRow + 1] of the region's own local grid. */
  size: [number, number];
  /** solarSystemId (string) -> region-local [col, row]. */
  systems: Record<string, [number, number]>;
}

export interface RegionLayoutData {
  version: number;
  generatedAt: string;
  source: string;
  /** regionId (string) -> region entry. */
  regions: Record<string, RegionLayoutEntry>;
}

let cache: Promise<RegionLayoutData | null> | null = null;

/**
 * Loads and caches the region layout dataset. Resolves to `null` (rather
 * than throwing) if the data file is missing or malformed, so geographic
 * k-space layout can gracefully fall back to topological layout instead of
 * failing the whole beautify pass.
 */
export const loadRegionLayouts = (): Promise<RegionLayoutData | null> => {
  if (!cache) {
    cache = import('./data/regionLayouts.json')
      .then(mod => {
        const data = (mod as { default?: unknown }).default ?? mod;
        return isRegionLayoutData(data) ? data : null;
      })
      .catch(() => null);
  }
  return cache;
};

const isRegionLayoutData = (value: unknown): value is RegionLayoutData =>
  typeof value === 'object' &&
  value !== null &&
  'regions' in value &&
  typeof (value as { regions: unknown }).regions === 'object';

export const getRegionEntry = (
  data: RegionLayoutData | null,
  regionId: number | undefined,
): RegionLayoutEntry | null => {
  if (!data || regionId == null) return null;
  return data.regions[String(regionId)] ?? null;
};

export const getSystemCell = (entry: RegionLayoutEntry | null, solarSystemId: string): [number, number] | null => {
  if (!entry) return null;
  return entry.systems[solarSystemId] ?? null;
};
