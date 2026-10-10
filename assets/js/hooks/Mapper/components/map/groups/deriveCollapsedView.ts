// CHEWY PATCH: new file. The ONE choke point for the map region/wormhole-chain collapse feature
// (WANDERER_MAP_GROUPS): a pure function from (raw ReactFlow nodes/edges, computed groups,
// which are collapsed) to the nodes/edges ReactFlow actually renders. `Map.tsx` is the only
// caller - everywhere else that calls `rf.setNodes`/`rf.setEdges` keeps writing the RAW arrays
// exactly as before; this function re-derives the collapsed VIEW from whatever the raw state
// currently is, every render, instead of being a second state array something else can
// desynchronise from (see docs/chewy/map-groups.md).
import { Edge, Node } from 'reactflow';
import { CharacterTypeRaw, PingType, SolarSystemConnection, SolarSystemRawType } from '@/hooks/Mapper/types';
import { MapGroup } from './computeGroups';

export const GROUP_NODE_TYPE = 'group';
export const GROUP_ID_PREFIX = 'group:';

export const groupNodeId = (groupKey: string): string => `${GROUP_ID_PREFIX}${groupKey}`;
export const isGroupNodeId = (id: string): boolean => id.startsWith(GROUP_ID_PREFIX);
export const groupKeyFromNodeId = (id: string): string => id.slice(GROUP_ID_PREFIX.length);

export interface GroupNodeData {
  key: string;
  kind: MapGroup['kind'];
  displayName: string;
  memberIds: string[];
  onlineCount: number;
  hasRally: boolean;
  hasCurrentCharacterLocation: boolean;
}

export type GroupEdgeData = Partial<SolarSystemConnection> & { count: number };

export interface DeriveCollapsedViewInput {
  nodes: Node<SolarSystemRawType>[];
  edges: Edge<SolarSystemConnection>[];
  groups: Map<string, MapGroup>;
  collapsedGroupKeys: ReadonlySet<string>;
  groupPositions: Record<string, { x: number; y: number }>;
  charactersBySystem: Map<number, CharacterTypeRaw[]>;
  pings: { solar_system_id: string; type: PingType }[];
  currentCharacterSystemIds: ReadonlySet<string>;
}

const GRID = 50;

function centroid(nodes: Node[], memberIds: readonly string[]): { x: number; y: number } {
  const members = nodes.filter(n => memberIds.includes(n.id));
  if (members.length === 0) {
    return { x: 0, y: 0 };
  }
  const sum = members.reduce((acc, n) => ({ x: acc.x + n.position.x, y: acc.y + n.position.y }), { x: 0, y: 0 });
  return {
    x: Math.round(sum.x / members.length / GRID) * GRID,
    y: Math.round(sum.y / members.length / GRID) * GRID,
  };
}

/**
 * The SAME position resolution `deriveCollapsedView` uses to place a group's tile - exported so
 * any other caller computing "where is this group right now" (e.g. `useMapGroups.ts`'s drag-stop
 * handler, resolving the PRE-drag position to compute a delta) uses the identical rule instead of
 * a second, driftable copy of it. A group with no committed position yet (never dragged) resolves
 * to the grid-snapped centroid of its members' CURRENT raw positions - exactly what the view
 * rendered before this drag started, since members don't move independently while collapsed.
 */
export function resolveGroupPosition(
  group: MapGroup,
  nodes: Node[],
  groupPositions: Record<string, { x: number; y: number }>,
): { x: number; y: number } {
  return groupPositions[group.key] ?? centroid(nodes, group.systemIds);
}

/**
 * Returns `{ nodes, edges }` UNCHANGED (same array references) when nothing is collapsed - the
 * "flag off / nothing collapsed" case does zero extra work and produces byte-identical output to
 * not having this feature at all.
 */
export function deriveCollapsedView({
  nodes,
  edges,
  groups,
  collapsedGroupKeys,
  groupPositions,
  charactersBySystem,
  pings,
  currentCharacterSystemIds,
}: DeriveCollapsedViewInput): { nodes: Node[]; edges: Edge[] } {
  const activeGroups: MapGroup[] = [];
  const memberToGroupKey = new Map<string, string>();
  for (const key of collapsedGroupKeys) {
    const group = groups.get(key);
    // A group key the user collapsed may no longer exist (membership dropped below 2, or the
    // last member left the map) - treat it as expanded rather than rendering an empty tile.
    if (!group) {
      continue;
    }
    activeGroups.push(group);
    for (const id of group.systemIds) {
      memberToGroupKey.set(id, key);
    }
  }

  if (activeGroups.length === 0) {
    return { nodes, edges };
  }

  const viewNodes: Node[] = [];
  for (const node of nodes) {
    if (memberToGroupKey.has(node.id)) {
      // Hidden members: ReactFlow skips hidden nodes and their edges entirely (no DOM, no
      // render); `selectable`/`draggable` false is defense in depth for the (unreachable while
      // hidden) case something still dispatches a change against this id directly.
      viewNodes.push({ ...node, hidden: true, selectable: false, draggable: false });
    } else {
      viewNodes.push(node);
    }
  }

  for (const group of activeGroups) {
    const onlineCount = group.systemIds.reduce((sum, id) => {
      const inSystem = charactersBySystem.get(parseInt(id, 10)) ?? [];
      return sum + inSystem.filter(c => c.online).length;
    }, 0);
    const hasRally = pings.some(p => p.type === PingType.Rally && group.systemIds.includes(p.solar_system_id));
    const hasCurrentCharacterLocation = group.systemIds.some(id => currentCharacterSystemIds.has(id));
    const position = resolveGroupPosition(group, nodes, groupPositions);
    const data: GroupNodeData = {
      key: group.key,
      kind: group.kind,
      displayName: group.displayName,
      memberIds: group.systemIds,
      onlineCount,
      hasRally,
      hasCurrentCharacterLocation,
    };

    viewNodes.push({
      id: groupNodeId(group.key),
      type: GROUP_NODE_TYPE,
      position,
      width: 150,
      height: 48,
      data,
      draggable: true,
      selectable: true,
    });
  }

  // Aggregate edges: an edge whose both endpoints resolve to the SAME group is internal - hidden.
  // An edge crossing a group boundary is replaced by a synthetic edge between the group node id
  // and the other (possibly also-group) endpoint, de-duplicated by endpoint pair with a running
  // `count`. An edge touching no collapsed group passes straight through unmodified.
  const passthroughEdges: Edge[] = [];
  const aggregated = new Map<string, { edge: Edge; count: number }>();

  for (const edge of edges) {
    const sourceGroup = memberToGroupKey.get(edge.source);
    const targetGroup = memberToGroupKey.get(edge.target);

    if (sourceGroup && targetGroup && sourceGroup === targetGroup) {
      continue; // internal to one collapsed group - hidden
    }

    if (!sourceGroup && !targetGroup) {
      passthroughEdges.push(edge);
      continue;
    }

    const source = sourceGroup ? groupNodeId(sourceGroup) : edge.source;
    const target = targetGroup ? groupNodeId(targetGroup) : edge.target;
    const pairKey = [source, target].sort().join('::');
    const existing = aggregated.get(pairKey);
    if (existing) {
      existing.count += 1;
    } else {
      const data: GroupEdgeData = { ...edge.data, count: 1 };
      aggregated.set(pairKey, {
        edge: { ...edge, id: `group-edge:${pairKey}`, source, target, data },
        count: 1,
      });
    }
  }

  const viewEdges: Edge[] = [
    ...passthroughEdges,
    ...Array.from(aggregated.values()).map(({ edge, count }) =>
      count > 1 ? { ...edge, data: { ...(edge.data as GroupEdgeData), count } } : edge,
    ),
  ];

  return { nodes: viewNodes, edges: viewEdges };
}
