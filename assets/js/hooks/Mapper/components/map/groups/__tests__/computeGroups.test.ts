/**
 * Pure unit tests for `computeGroups.ts` - no React, no ReactFlow, no MapRootProvider. The
 * module-level `getSystemStaticInfo` cache it reads from is mocked directly here (same pattern
 * `__perf__/harness.tsx` uses) since it isn't exported for direct seeding.
 */
import { SolarSystemConnection, SolarSystemRawType } from '@/hooks/Mapper/types';
import type { SolarSystemStaticInfoRaw } from '@/hooks/Mapper/types/system';
import { Regions } from '@/hooks/Mapper/constants';

const staticInfoById = new Map<number, SolarSystemStaticInfoRaw>();

jest.mock('@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic', () => ({
  getSystemStaticInfo: (id: number | string | undefined) => {
    if (id == null) return undefined;
    return staticInfoById.get(typeof id === 'number' ? id : parseInt(id, 10));
  },
}));

import { computeGroups } from '../computeGroups';

function makeStatic(id: number, overrides: Partial<SolarSystemStaticInfoRaw> = {}): SolarSystemStaticInfoRaw {
  return {
    region_id: 10000001,
    constellation_id: 20000001,
    solar_system_id: id,
    solar_system_name: `Sys${id}`,
    solar_system_name_lc: `sys${id}`,
    constellation_name: 'Test Constellation',
    region_name: 'Test Region',
    system_class: 7, // hs
    security: '0.5',
    type_description: 'High-sec',
    class_title: '',
    is_shattered: false,
    effect_name: '',
    effect_power: 0,
    statics: [],
    wandering: [],
    triglavian_invasion_status: 'Normal',
    sun_type_id: 3800,
    ...overrides,
  };
}

function makeSystem(id: string, info: SolarSystemStaticInfoRaw): SolarSystemRawType {
  staticInfoById.set(info.solar_system_id, info);
  return {
    id,
    position: { x: 0, y: 0 },
    description: null,
    labels: null,
    locked: false,
    tag: null,
    status: 0,
    name: null,
    temporary_name: null,
    linked_sig_eve_id: null,
    comments_count: 0,
    system_static_info: info,
    system_signatures: [],
  };
}

function connection(source: string, target: string): SolarSystemConnection {
  return { id: `${source}_${target}`, time_status: 0, mass_status: 0, ship_size_type: 0, locked: false, source, target };
}

beforeEach(() => {
  staticInfoById.clear();
});

describe('computeGroups', () => {
  test('buckets k-space systems by region_id', () => {
    const s1 = makeSystem('1', makeStatic(1, { region_id: 10000001, region_name: 'Region A' }));
    const s2 = makeSystem('2', makeStatic(2, { region_id: 10000001, region_name: 'Region A' }));
    const s3 = makeSystem('3', makeStatic(3, { region_id: 10000002, region_name: 'Region B' }));

    const groups = computeGroups([s1, s2, s3], []);

    expect(groups.size).toBe(1); // region B has only 1 member, not collapsible
    const regionA = groups.get('region:10000001');
    expect(regionA?.kind).toBe('region');
    expect(regionA?.displayName).toBe('Region A');
    expect(new Set(regionA?.systemIds)).toEqual(new Set(['1', '2']));
  });

  test('a region with fewer than 2 members is not returned', () => {
    const s1 = makeSystem('1', makeStatic(1, { region_id: 10000001 }));
    const groups = computeGroups([s1], []);
    expect(groups.size).toBe(0);
  });

  test('Pochven displays its constellation name, not its region name', () => {
    const s1 = makeSystem(
      '1',
      makeStatic(1, { region_id: Regions.Pochven, region_name: 'Pochven', constellation_name: 'Ichoriya' }),
    );
    const s2 = makeSystem(
      '2',
      makeStatic(2, { region_id: Regions.Pochven, region_name: 'Pochven', constellation_name: 'Ichoriya' }),
    );
    const groups = computeGroups([s1, s2], []);
    expect(groups.get(`region:${Regions.Pochven}`)?.displayName).toBe('Ichoriya');
  });

  test('wormhole systems form a chain by connected component over CURRENT connections only', () => {
    const s1 = makeSystem('1', makeStatic(1, { system_class: 1 })); // c1
    const s2 = makeSystem('2', makeStatic(2, { system_class: 2 })); // c2
    const s3 = makeSystem('3', makeStatic(3, { system_class: 3 })); // c3, NOT connected to 1/2
    const groups = computeGroups([s1, s2, s3], [connection('1', '2')]);

    expect(groups.size).toBe(1); // s3 is alone, not collapsible
    const chain = groups.get('chain:1');
    expect(chain?.kind).toBe('chain');
    expect(new Set(chain?.systemIds)).toEqual(new Set(['1', '2']));
  });

  test('chain key is the numerically smallest member id, stable as the chain grows', () => {
    const s5 = makeSystem('30000005', makeStatic(30000005, { system_class: 1 }));
    const s3 = makeSystem('30000003', makeStatic(30000003, { system_class: 1 }));
    const groupsBefore = computeGroups([s5, s3], [connection('30000005', '30000003')]);
    expect(Array.from(groupsBefore.keys())).toEqual(['chain:30000003']);

    const s7 = makeSystem('30000007', makeStatic(30000007, { system_class: 1 }));
    const groupsAfter = computeGroups(
      [s5, s3, s7],
      [connection('30000005', '30000003'), connection('30000005', '30000007')],
    );
    // Same root key after growing - not jumping just because a new system joined.
    expect(Array.from(groupsAfter.keys())).toEqual(['chain:30000003']);
    expect(new Set(groupsAfter.get('chain:30000003')?.systemIds)).toEqual(
      new Set(['30000003', '30000005', '30000007']),
    );
  });

  test('an edge between two k-space systems does not join a chain', () => {
    const s1 = makeSystem('1', makeStatic(1, { system_class: 1 }));
    const s2 = makeSystem('2', makeStatic(2, { system_class: 7 })); // hs
    const groups = computeGroups([s1, s2], [connection('1', '2')]);
    expect(groups.size).toBe(0); // s1 alone (1 member), s2 is k-space with no region siblings
  });

  test('a system with no loaded static info is excluded entirely (ungroupable until it loads)', () => {
    const s1 = makeSystem('1', makeStatic(1, { region_id: 10000001 }));
    const s2: SolarSystemRawType = {
      id: '2',
      position: { x: 0, y: 0 },
      description: null,
      labels: null,
      locked: false,
      tag: null,
      status: 0,
      name: null,
      temporary_name: null,
      linked_sig_eve_id: null,
      comments_count: 0,
      system_static_info: makeStatic(2), // NOT registered in staticInfoById - cache miss
      system_signatures: [],
    };
    staticInfoById.delete(2);

    const groups = computeGroups([s1, s2], []);
    expect(groups.size).toBe(0); // s1 has no region sibling since s2 was excluded
  });

  test('returns multiple region groups across a multi-region map', () => {
    const systems: SolarSystemRawType[] = [];
    for (let region = 0; region < 8; region++) {
      for (let i = 0; i < 3; i++) {
        const id = region * 10 + i;
        systems.push(makeSystem(String(id), makeStatic(id, { region_id: 11000000 + region })));
      }
    }
    const groups = computeGroups(systems, []);
    expect(groups.size).toBe(8);
    for (const group of groups.values()) {
      expect(group.systemIds).toHaveLength(3);
    }
  });
});
