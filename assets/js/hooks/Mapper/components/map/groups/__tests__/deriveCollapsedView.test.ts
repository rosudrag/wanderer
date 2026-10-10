/**
 * Pure unit tests for `deriveCollapsedView.ts` - no React, no MapRootProvider, no ReactFlow
 * runtime. Builds plain `Node`/`Edge` objects and a `Map<groupKey, MapGroup>` by hand.
 */
import { Edge, Node } from 'reactflow';
import { CharacterTypeRaw, PingType, SolarSystemConnection, SolarSystemRawType } from '@/hooks/Mapper/types';
import { MapGroup } from '../computeGroups';
import { deriveCollapsedView, GroupEdgeData, groupNodeId } from '../deriveCollapsedView';

function node(id: string): Node<SolarSystemRawType> {
  return {
    id,
    type: 'custom',
    position: { x: parseInt(id, 10) * 10, y: 0 },
    width: 130,
    height: 34,
    data: { id } as SolarSystemRawType,
  };
}

function edge(source: string, target: string): Edge<SolarSystemConnection> {
  return { id: `${source}-${target}`, source, target, type: 'floating', data: { id: `${source}-${target}` } as SolarSystemConnection };
}

const EMPTY_INPUT = {
  charactersBySystem: new Map<number, CharacterTypeRaw[]>(),
  pings: [] as { solar_system_id: string; type: PingType }[],
  currentCharacterSystemIds: new Set<string>(),
  groupPositions: {},
};

describe('deriveCollapsedView', () => {
  test('returns the SAME array references when nothing is collapsed - zero extra work', () => {
    const nodes = [node('1'), node('2')];
    const edges = [edge('1', '2')];
    const result = deriveCollapsedView({
      nodes,
      edges,
      groups: new Map(),
      collapsedGroupKeys: new Set(),
      ...EMPTY_INPUT,
    });
    expect(result.nodes).toBe(nodes);
    expect(result.edges).toBe(edges);
  });

  test('hides members and adds one group node for a collapsed group', () => {
    const nodes = [node('1'), node('2'), node('3')];
    const group: MapGroup = { key: 'region:1', kind: 'region', displayName: 'Region A', systemIds: ['1', '2'] };
    const result = deriveCollapsedView({
      nodes,
      edges: [],
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
    });

    const member1 = result.nodes.find(n => n.id === '1');
    const member2 = result.nodes.find(n => n.id === '2');
    const member3 = result.nodes.find(n => n.id === '3');
    const groupTile = result.nodes.find(n => n.id === groupNodeId(group.key));

    expect(member1?.hidden).toBe(true);
    expect(member1?.selectable).toBe(false);
    expect(member2?.hidden).toBe(true);
    expect(member3?.hidden).toBeUndefined(); // untouched - not in this group
    expect(groupTile).toBeDefined();
    expect(groupTile?.type).toBe('group');
    expect(result.nodes).toHaveLength(4); // 3 real + 1 group tile
  });

  test('a group key the user collapsed that no longer exists in `groups` is treated as expanded', () => {
    const nodes = [node('1'), node('2')];
    const result = deriveCollapsedView({
      nodes,
      edges: [],
      groups: new Map(), // dissolved - membership dropped below 2
      collapsedGroupKeys: new Set(['region:1']),
      ...EMPTY_INPUT,
    });
    expect(result.nodes).toBe(nodes); // falls back to the identity pass-through
  });

  test('an edge internal to one collapsed group is hidden (dropped)', () => {
    const nodes = [node('1'), node('2')];
    const edges = [edge('1', '2')];
    const group: MapGroup = { key: 'region:1', kind: 'region', displayName: 'Region A', systemIds: ['1', '2'] };
    const result = deriveCollapsedView({
      nodes,
      edges,
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
    });
    expect(result.edges).toHaveLength(0);
  });

  test('an edge crossing a group boundary is replaced by a synthetic group edge', () => {
    const nodes = [node('1'), node('2'), node('3')];
    const edges = [edge('1', '3')];
    const group: MapGroup = { key: 'region:1', kind: 'region', displayName: 'Region A', systemIds: ['1', '2'] };
    const result = deriveCollapsedView({
      nodes,
      edges,
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
    });

    expect(result.edges).toHaveLength(1);
    const [syntheticEdge] = result.edges;
    expect([syntheticEdge.source, syntheticEdge.target].sort()).toEqual(['3', groupNodeId(group.key)].sort());
  });

  test('multiple boundary edges to the same other endpoint are de-duplicated with a count', () => {
    const nodes = [node('1'), node('2'), node('3')];
    const edges = [edge('1', '3'), edge('2', '3')];
    const group: MapGroup = { key: 'region:1', kind: 'region', displayName: 'Region A', systemIds: ['1', '2'] };
    const result = deriveCollapsedView({
      nodes,
      edges,
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
    });

    expect(result.edges).toHaveLength(1);
    expect((result.edges[0].data as GroupEdgeData).count).toBe(2);
  });

  test('an edge touching no collapsed group passes through unmodified', () => {
    const nodes = [node('1'), node('2'), node('3'), node('4')];
    const edges = [edge('3', '4')];
    const group: MapGroup = { key: 'region:1', kind: 'region', displayName: 'Region A', systemIds: ['1', '2'] };
    const result = deriveCollapsedView({
      nodes,
      edges,
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
    });
    expect(result.edges).toEqual([edges[0]]);
  });

  test('onlineCount sums characters across every member system, not a filtered subset', () => {
    const nodes = [node('1'), node('2')];
    const group: MapGroup = { key: 'region:1', kind: 'region', displayName: 'Region A', systemIds: ['1', '2'] };
    const charactersBySystem = new Map<number, CharacterTypeRaw[]>([
      [1, [{ eve_id: 'a', online: true } as CharacterTypeRaw, { eve_id: 'b', online: false } as CharacterTypeRaw]],
      [2, [{ eve_id: 'c', online: true } as CharacterTypeRaw]],
    ]);
    const result = deriveCollapsedView({
      nodes,
      edges: [],
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
      charactersBySystem,
    });
    const tile = result.nodes.find(n => n.id === groupNodeId(group.key));
    expect(tile?.data.onlineCount).toBe(2);
  });

  test('hasRally is true if any member has a rally ping', () => {
    const nodes = [node('1'), node('2')];
    const group: MapGroup = { key: 'region:1', kind: 'region', displayName: 'Region A', systemIds: ['1', '2'] };
    const result = deriveCollapsedView({
      nodes,
      edges: [],
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
      pings: [{ solar_system_id: '2', type: PingType.Rally }],
    });
    const tile = result.nodes.find(n => n.id === groupNodeId(group.key));
    expect(tile?.data.hasRally).toBe(true);
  });

  test('a committed group position is used verbatim; otherwise falls back to the grid-snapped centroid', () => {
    const nodes = [node('1'), node('2')]; // positions (10,0) and (20,0)
    const group: MapGroup = { key: 'region:1', kind: 'region', displayName: 'Region A', systemIds: ['1', '2'] };

    const withCommitted = deriveCollapsedView({
      nodes,
      edges: [],
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
      groupPositions: { [group.key]: { x: 999, y: 999 } },
    });
    expect(withCommitted.nodes.find(n => n.id === groupNodeId(group.key))?.position).toEqual({ x: 999, y: 999 });

    const withoutCommitted = deriveCollapsedView({
      nodes,
      edges: [],
      groups: new Map([[group.key, group]]),
      collapsedGroupKeys: new Set([group.key]),
      ...EMPTY_INPUT,
    });
    // centroid of (10,0) and (20,0) is (15,0), snapped to the 50px grid -> (0,0).
    expect(withoutCommitted.nodes.find(n => n.id === groupNodeId(group.key))?.position).toEqual({ x: 0, y: 0 });
  });
});
