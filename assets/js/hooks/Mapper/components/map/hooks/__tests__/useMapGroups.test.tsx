/**
 * Focused unit test for `useMapGroups.ts`'s drag-stop -> bulk position update payload - the part
 * the brief singles out as "the part that can silently corrupt a map". Mocks
 * `useMapRootSelector`/`useMapSelector` directly (controlled data, no real `MapRootProvider`/
 * `MapProvider` tree needed) since jsdom cannot drive a REAL ReactFlow drag (no
 * `DOMMatrixReadOnly` - documented in docs/chewy/map-perf-findings.md "Harness limitations"); this
 * calls `filterGroupNodeChanges` directly with a synthetic `NodeChange`, the exact shape ReactFlow
 * itself would produce from a real drag.
 */
import { act } from 'react-dom/test-utils';
(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
import { createRoot } from 'react-dom/client';
import { NodeChange } from 'reactflow';
import { OutCommand, SolarSystemRawType } from '@/hooks/Mapper/types';
import { MapGroup } from '@/hooks/Mapper/components/map/groups/computeGroups';

const mockSystems: SolarSystemRawType[] = [
  { id: '1', position: { x: 0, y: 0 } } as SolarSystemRawType,
  { id: '2', position: { x: 100, y: 0 } } as SolarSystemRawType,
  { id: '3', position: { x: 0, y: 100 } } as SolarSystemRawType,
];
const mockConnections: never[] = [];
const mockCollapsedGroupKeys = ['region:10000001'];
let mockCommittedPositions: Record<string, { x: number; y: number }> = {};

jest.mock('@/hooks/Mapper/mapRootProvider', () => ({
  useMapRootSelector: (_keys: string[], selector: (d: unknown) => unknown) => {
    const data = {
      systems: mockSystems,
      connections: mockConnections,
      collapsedGroupKeys: mockCollapsedGroupKeys,
      groupPositions: mockCommittedPositions,
      pings: [],
    };
    return selector(data);
  },
}));

jest.mock('@/hooks/Mapper/components/map/MapProvider', () => ({
  useMapSelector: (_keys: string[], selector: (d: unknown) => unknown) => {
    const data = { charactersBySystem: new Map(), userCharacters: [] };
    return selector(data);
  },
}));

// `computeGroups` reads `getSystemStaticInfo`; mocked so `computeGroups(mockSystems, [])` returns
// a single 2-member group covering systems 1 and 2 (system 3 is NOT a member - proves the
// bulk-update payload only contains the GROUP's actual members, not every system on the map).
jest.mock('@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic', () => ({
  getSystemStaticInfo: (id: string) => ({
    region_id: id === '3' ? 99999999 : 10000001,
    region_name: id === '3' ? 'Other Region' : 'Test Region',
    constellation_name: 'Test Constellation',
    system_class: 7,
    solar_system_id: parseInt(id, 10),
  }),
}));

import { useMapGroups } from '../useMapGroups';
import { groupNodeId } from '@/hooks/Mapper/components/map/groups/deriveCollapsedView';

test('drag-stop on a collapsed group emits ONE bulk position update containing every member with the correct delta', async () => {
  mockCommittedPositions = { 'region:10000001': { x: 500, y: 500 } };
  const onCommand = jest.fn().mockResolvedValue({});
  const setNodes = jest.fn();
  const settingsGroupsUpdate = jest.fn();

  let filterGroupNodeChanges: ((changes: NodeChange[]) => NodeChange[]) | null = null;
  let capturedGroups: Map<string, MapGroup> | null = null;

  function Probe() {
    const result = useMapGroups({
      enabled: true,
      nodes: mockSystems.map(s => ({ id: s.id, position: s.position, data: s }) as never),
      edges: [],
      setNodes,
      onCommand,
      settingsGroupsUpdate,
    });
    filterGroupNodeChanges = result.filterGroupNodeChanges;
    capturedGroups = result.groups;
    return null;
  }

  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);

  await act(async () => {
    root.render(<Probe />);
  });

  // Sanity: `computeGroups` found exactly the group this test assumes (systems 1+2, NOT 3).
  const group = Array.from(capturedGroups!.values())[0];
  expect(new Set(group.systemIds)).toEqual(new Set(['1', '2']));

  // Simulate ReactFlow's own drag-stop NodeChange on the synthetic group node: moved from the
  // committed (500,500) to (520, 530) - a delta of (+20, +30).
  const dragStopChange: NodeChange = {
    id: groupNodeId('region:10000001'),
    type: 'position',
    position: { x: 520, y: 530 },
    dragging: false,
  };

  await act(async () => {
    filterGroupNodeChanges!([dragStopChange]);
  });

  // Exactly one bulk command, not one per member.
  expect(onCommand).toHaveBeenCalledTimes(1);
  const [call] = onCommand.mock.calls;
  expect(call[0].type).toBe(OutCommand.updateSystemPositionsBulk);

  const entries = call[0].data as { solar_system_id: string; position: { x: number; y: number } }[];
  expect(entries).toHaveLength(2); // only the group's 2 real members - not system 3
  const byId = new Map(entries.map(e => [e.solar_system_id, e.position]));
  // system 1 started at (0,0) -> (0+20, 0+30)
  expect(byId.get('1')).toEqual({ x: 20, y: 30 });
  // system 2 started at (100,0) -> (100+20, 0+30)
  expect(byId.get('2')).toEqual({ x: 120, y: 30 });

  // The group's own committed position is persisted too, so expanding later doesn't teleport it.
  expect(settingsGroupsUpdate).toHaveBeenCalled();
  const settingsCall = settingsGroupsUpdate.mock.calls[settingsGroupsUpdate.mock.calls.length - 1][0];
  const nextSettings =
    typeof settingsCall === 'function' ? settingsCall({ collapsedGroups: [], groupPositions: mockCommittedPositions }) : settingsCall;
  expect(nextSettings.groupPositions['region:10000001']).toEqual({ x: 520, y: 530 });

  act(() => {
    root.unmount();
  });
});

test('FIX 1: the first drag of a group that has never been dragged before moves its members by the real delta, not zero', async () => {
  // No entry for 'region:10000001' - this group has never been dragged, so its rendered
  // position came from `deriveCollapsedView`'s centroid fallback, not a committed value. The
  // bug: resolving the pre-drag position as `committedGroupPositions[key] ?? newPosition` made
  // the delta exactly zero here, silently failing to move any member.
  mockCommittedPositions = {};
  const onCommand = jest.fn().mockResolvedValue({});
  const setNodes = jest.fn();
  const settingsGroupsUpdate = jest.fn();

  let filterGroupNodeChanges: ((changes: NodeChange[]) => NodeChange[]) | null = null;

  function Probe() {
    const result = useMapGroups({
      enabled: true,
      nodes: mockSystems.map(s => ({ id: s.id, position: s.position, data: s }) as never),
      edges: [],
      setNodes,
      onCommand,
      settingsGroupsUpdate,
    });
    filterGroupNodeChanges = result.filterGroupNodeChanges;
    return null;
  }

  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);

  await act(async () => {
    root.render(<Probe />);
  });

  // Group members are systems 1 (0,0) and 2 (100,0) - centroid (50,0), grid-snapped to 50px ->
  // (50,0). That is where `deriveCollapsedView` would have rendered the tile, so dragging it to
  // (90, 40) is a real delta of (+40, +40), not zero.
  const dragStopChange: NodeChange = {
    id: groupNodeId('region:10000001'),
    type: 'position',
    position: { x: 90, y: 40 },
    dragging: false,
  };

  await act(async () => {
    filterGroupNodeChanges!([dragStopChange]);
  });

  expect(onCommand).toHaveBeenCalledTimes(1);
  const entries = onCommand.mock.calls[0][0].data as { solar_system_id: string; position: { x: number; y: number } }[];
  const byId = new Map(entries.map(e => [e.solar_system_id, e.position]));

  // NOT zero delta: member 1 moves from (0,0), member 2 from (100,0), both by (+40,+40).
  expect(byId.get('1')).toEqual({ x: 40, y: 40 });
  expect(byId.get('2')).toEqual({ x: 140, y: 40 });

  // Expand-then-read: the committed position written is the tile's actual drop point, so a
  // later `resolveGroupPosition` call (what expanding, then re-collapsing, would use) agrees.
  const settingsCall = settingsGroupsUpdate.mock.calls[settingsGroupsUpdate.mock.calls.length - 1][0];
  const nextSettings =
    typeof settingsCall === 'function' ? settingsCall({ collapsedGroups: [], groupPositions: {} }) : settingsCall;
  expect(nextSettings.groupPositions['region:10000001']).toEqual({ x: 90, y: 40 });

  act(() => {
    root.unmount();
  });
});

test('FIX 2: a rubber-band selection containing a group tile sends ONLY real system ids, offset by the real (non-zero) delta', async () => {
  mockCommittedPositions = {}; // group never dragged before - same "first move" case as fix 1
  const onCommand = jest.fn().mockResolvedValue({});
  const setNodes = jest.fn();
  const settingsGroupsUpdate = jest.fn();

  let translateSelectionNodes: ((nodes: { id: string; position: { x: number; y: number } }[]) => unknown[]) | null = null;

  function Probe() {
    const result = useMapGroups({
      enabled: true,
      nodes: mockSystems.map(s => ({ id: s.id, position: s.position, data: s }) as never),
      edges: [],
      setNodes,
      onCommand,
      settingsGroupsUpdate,
    });
    translateSelectionNodes = result.translateSelectionNodes as never;
    return null;
  }

  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);

  await act(async () => {
    root.render(<Probe />);
  });

  // Selection: the group tile (dragged to (90,40), same real delta as fix 1: +40,+40) and
  // system 3 (a real, non-member system, dragged to (10, 110) from its (0,100) start).
  let entries: { solar_system_id: string; position: { x: number; y: number } }[] = [];
  act(() => {
    entries = translateSelectionNodes!([
      { id: groupNodeId('region:10000001'), position: { x: 90, y: 40 } },
      { id: '3', position: { x: 10, y: 110 } },
    ]) as typeof entries;
  });

  // Zero synthetic ids reach the caller.
  expect(entries.some(e => e.solar_system_id.startsWith('group:'))).toBe(false);

  const byId = new Map(entries.map(e => [e.solar_system_id, e.position]));
  expect(entries).toHaveLength(3); // group's 2 members + the 1 real system
  expect(byId.get('1')).toEqual({ x: 40, y: 40 }); // real, non-zero delta - not the fix-1 bug
  expect(byId.get('2')).toEqual({ x: 140, y: 40 });
  expect(byId.get('3')).toEqual({ x: 10, y: 110 }); // real system's own dragged position, as-is

  act(() => {
    root.unmount();
  });
});

test('FIX 3: expandSelectionSystemIds expands a selected group tile into its real member ids, leaves real ids untouched', async () => {
  mockCommittedPositions = {};
  const onCommand = jest.fn().mockResolvedValue({});
  const setNodes = jest.fn();
  const settingsGroupsUpdate = jest.fn();

  let expandSelectionSystemIds: ((ids: string[]) => string[]) | null = null;

  function Probe() {
    const result = useMapGroups({
      enabled: true,
      nodes: mockSystems.map(s => ({ id: s.id, position: s.position, data: s }) as never),
      edges: [],
      setNodes,
      onCommand,
      settingsGroupsUpdate,
    });
    expandSelectionSystemIds = result.expandSelectionSystemIds;
    return null;
  }

  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);

  await act(async () => {
    root.render(<Probe />);
  });

  const expanded = expandSelectionSystemIds!([groupNodeId('region:10000001'), '3']);

  expect(expanded.some(id => id.startsWith('group:'))).toBe(false);
  expect(new Set(expanded)).toEqual(new Set(['1', '2', '3']));

  act(() => {
    root.unmount();
  });
});
