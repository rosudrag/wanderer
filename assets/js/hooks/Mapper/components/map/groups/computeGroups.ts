// CHEWY PATCH: new file. Pure, server-call-free group-key computation for the map region/
// wormhole-chain collapse feature (WANDERER_MAP_GROUPS). No React, no ReactFlow - just
// `SolarSystemRawType[]` + `SolarSystemConnection[]` in, a `Map<groupKey, MapGroup>` out.
import { SolarSystemConnection, SolarSystemRawType } from '@/hooks/Mapper/types';
import { getSystemStaticInfo } from '@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic';
import { isWormholeSpace } from '@/hooks/Mapper/components/map/helpers/isWormholeSpace';
import { Regions } from '@/hooks/Mapper/constants';

export type GroupKind = 'region' | 'chain';

export interface MapGroup {
  key: string;
  kind: GroupKind;
  displayName: string;
  systemIds: string[];
}

export const REGION_GROUP_PREFIX = 'region:';
export const CHAIN_GROUP_PREFIX = 'chain:';

/**
 * Connected components of J-space systems over CURRENT connections only (an edge between two
 * k-space systems, or whose other endpoint isn't in `wormholeSystemIds`, never joins a chain).
 * Keyed by the numerically smallest member system id, so the key stays the same system as the
 * chain grows or shrinks by one end, rather than jumping every time the "first" system changes.
 */
function computeChainRoots(
  wormholeSystemIds: ReadonlySet<string>,
  connections: SolarSystemConnection[],
): Map<string, string> {
  const adjacency = new Map<string, Set<string>>();
  for (const id of wormholeSystemIds) {
    adjacency.set(id, new Set());
  }
  for (const connection of connections) {
    if (wormholeSystemIds.has(connection.source) && wormholeSystemIds.has(connection.target)) {
      adjacency.get(connection.source)?.add(connection.target);
      adjacency.get(connection.target)?.add(connection.source);
    }
  }

  const idToRoot = new Map<string, string>();
  const visited = new Set<string>();
  for (const start of wormholeSystemIds) {
    if (visited.has(start)) {
      continue;
    }
    const component: string[] = [];
    const stack = [start];
    visited.add(start);
    while (stack.length > 0) {
      const current = stack.pop() as string;
      component.push(current);
      for (const next of adjacency.get(current) ?? []) {
        if (!visited.has(next)) {
          visited.add(next);
          stack.push(next);
        }
      }
    }
    const root = component.reduce((a, b) => (parseInt(a, 10) <= parseInt(b, 10) ? a : b));
    for (const id of component) {
      idToRoot.set(id, root);
    }
  }
  return idToRoot;
}

/**
 * k-space systems bucketed by `region:<region_id>` (Pochven displays its constellation name
 * instead of its region name, matching `useSolarSystemNode.ts`'s existing display rule), j-space
 * systems bucketed into `chain:<root id>` connected components. A system whose static info has
 * not loaded yet (`getSystemStaticInfo` cache miss) is excluded - ungroupable until it loads.
 * Only groups with >= 2 members are returned (a single-system "group" collapses nothing).
 */
export function computeGroups(systems: SolarSystemRawType[], connections: SolarSystemConnection[]): Map<string, MapGroup> {
  const regionBuckets = new Map<string, { displayName: string; systemIds: string[] }>();
  const wormholeIds = new Set<string>();

  for (const system of systems) {
    const info = getSystemStaticInfo(system.id);
    if (!info) {
      continue;
    }
    if (isWormholeSpace(info.system_class)) {
      wormholeIds.add(system.id);
      continue;
    }
    const key = `${REGION_GROUP_PREFIX}${info.region_id}`;
    const displayName = info.region_id === Regions.Pochven ? info.constellation_name : info.region_name;
    const bucket = regionBuckets.get(key) ?? { displayName, systemIds: [] };
    bucket.systemIds.push(system.id);
    regionBuckets.set(key, bucket);
  }

  const chainRoots = computeChainRoots(wormholeIds, connections);
  const chainBuckets = new Map<string, { displayName: string; systemIds: string[] }>();
  for (const [systemId, root] of chainRoots) {
    const key = `${CHAIN_GROUP_PREFIX}${root}`;
    const rootInfo = getSystemStaticInfo(root);
    const bucket = chainBuckets.get(key) ?? {
      displayName: rootInfo ? `Chain ${rootInfo.solar_system_name}` : `Chain ${root}`,
      systemIds: [],
    };
    bucket.systemIds.push(systemId);
    chainBuckets.set(key, bucket);
  }

  const groups = new Map<string, MapGroup>();
  for (const [key, bucket] of regionBuckets) {
    if (bucket.systemIds.length < 2) {
      continue;
    }
    groups.set(key, { key, kind: 'region', displayName: bucket.displayName, systemIds: bucket.systemIds });
  }
  for (const [key, bucket] of chainBuckets) {
    if (bucket.systemIds.length < 2) {
      continue;
    }
    groups.set(key, { key, kind: 'chain', displayName: bucket.displayName, systemIds: bucket.systemIds });
  }
  return groups;
}
