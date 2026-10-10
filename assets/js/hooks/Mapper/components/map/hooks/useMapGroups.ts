// CHEWY PATCH: new file. Wires the map region/wormhole-chain collapse feature
// (WANDERER_MAP_GROUPS) into `Map.tsx`'s `MapComp`: computes groups, derives the collapsed VIEW
// via the single `deriveCollapsedView` choke point, and translates ReactFlow node changes on a
// synthetic group node (drag) into real per-member position writes + one bulk out-command, so a
// group's members' STORED positions always follow the group (expanding never teleports them back
// to where they were collapsed).
import { Dispatch, SetStateAction, useCallback, useMemo, useRef, useState } from 'react';
import { Edge, Node, NodeChange } from 'reactflow';
import { useMapRootSelector } from '@/hooks/Mapper/mapRootProvider';
import { useMapSelector } from '@/hooks/Mapper/components/map/MapProvider';
import { computeGroups, MapGroup } from '@/hooks/Mapper/components/map/groups/computeGroups';
import {
  deriveCollapsedView,
  groupKeyFromNodeId,
  isGroupNodeId,
  resolveGroupPosition,
} from '@/hooks/Mapper/components/map/groups/deriveCollapsedView';
import { OutCommand, OutCommandHandler, SolarSystemConnection, SolarSystemRawType } from '@/hooks/Mapper/types';
import { MapGroupsSettings } from '@/hooks/Mapper/mapRootProvider/types';

export type SettingsGroupsUpdate = Dispatch<SetStateAction<MapGroupsSettings>>;

export interface PositionUpdateEntry {
  solar_system_id: string;
  position: { x: number; y: number };
}

interface UseMapGroupsProps {
  enabled: boolean;
  nodes: Node<SolarSystemRawType>[];
  edges: Edge<SolarSystemConnection>[];
  setNodes: Dispatch<SetStateAction<Node<SolarSystemRawType>[]>>;
  onCommand: OutCommandHandler;
  settingsGroupsUpdate: SettingsGroupsUpdate;
}

export interface UseMapGroupsResult {
  viewNodes: Node[];
  viewEdges: Edge[];
  groups: Map<string, MapGroup>;
  /** Intercepts group-node changes (position/select/remove) before they would otherwise reach
   * ReactFlow's real `onNodesChange`; returns the changes that should still be applied to the raw
   * node array (i.e. everything NOT targeting a synthetic group id). */
  filterGroupNodeChanges: (changes: NodeChange[]) => NodeChange[];
  /** Translates a rubber-band-selected node list (which may include synthetic group ids) into
   * REAL per-system position entries only - a group in the selection expands to every member,
   * offset by that group's own drag delta - and performs the matching `setNodes`/
   * `settingsGroupsUpdate` side effects (same as `filterGroupNodeChanges`'s drag-stop case).
   * Never returns a `group:` id - the caller sends the result straight to
   * `OutCommand.updateSystemPositions`. */
  translateSelectionNodes: (selectedNodes: Node[]) => PositionUpdateEntry[];
  /** Expands any `group:` ids in a selected-node-id list into their real member system ids -
   * what `onSelectionChange` reports as `systems`, so a selected group tile reads as "its
   * members are selected" to every downstream consumer (beautify `scope: 'selection'`, the
   * selection context menu, delete-selected, ...), not as an unresolvable synthetic id. */
  expandSelectionSystemIds: (ids: string[]) => string[];
  collapseGroup: (key: string) => void;
  expandGroup: (key: string) => void;
  collapseAllRegions: () => void;
  expandAll: () => void;
  isGroupCollapsed: (key: string) => boolean;
}

export function useMapGroups({
  enabled,
  nodes,
  edges,
  setNodes,
  onCommand,
  settingsGroupsUpdate,
}: UseMapGroupsProps): UseMapGroupsResult {
  const systems = useMapRootSelector(['systems'], d => d.systems);
  const connections = useMapRootSelector(['connections'], d => d.connections);
  const collapsedGroupKeysArr = useMapRootSelector(['collapsedGroupKeys'], d => d.collapsedGroupKeys);
  const committedGroupPositions = useMapRootSelector(['groupPositions'], d => d.groupPositions);
  const pings = useMapRootSelector(['pings'], d => d.pings);
  const charactersBySystem = useMapSelector(['charactersBySystem'], d => d.charactersBySystem);
  const userCharacters = useMapSelector(['userCharacters'], d => d.userCharacters);

  const groups = useMemo(() => computeGroups(systems, connections), [systems, connections]);
  const collapsedGroupKeys = useMemo(() => new Set(collapsedGroupKeysArr), [collapsedGroupKeysArr]);

  const currentCharacterSystemIds = useMemo(() => {
    const result = new Set<string>();
    if (userCharacters.length === 0) {
      return result;
    }
    const userCharacterSet = new Set(userCharacters);
    charactersBySystem.forEach((chars, systemId) => {
      if (chars.some(c => userCharacterSet.has(c.eve_id))) {
        result.add(systemId.toString());
      }
    });
    return result;
  }, [charactersBySystem, userCharacters]);

  // Position a dragged-but-not-yet-dropped group tile follows DURING the drag, overlaid on top
  // of the committed `groupPositions` below - without this, `deriveCollapsedView` would
  // recompute the group's position from the (unchanged until drag-stop) committed value every
  // render and the tile would snap back to its start point on every frame of the drag.
  const [liveDragPositions, setLiveDragPositions] = useState<Record<string, { x: number; y: number }>>({});

  const groupPositions = useMemo(
    () => ({ ...committedGroupPositions, ...liveDragPositions }),
    [committedGroupPositions, liveDragPositions],
  );

  const { nodes: viewNodes, edges: viewEdges } = useMemo(() => {
    if (!enabled) {
      return { nodes, edges };
    }
    return deriveCollapsedView({
      nodes,
      edges,
      groups,
      collapsedGroupKeys,
      groupPositions,
      charactersBySystem,
      pings,
      currentCharacterSystemIds,
    });
  }, [enabled, nodes, edges, groups, collapsedGroupKeys, groupPositions, charactersBySystem, pings, currentCharacterSystemIds]);

  const ref = useRef({ groups, onCommand, settingsGroupsUpdate });
  ref.current = { groups, onCommand, settingsGroupsUpdate };

  // Shared by `filterGroupNodeChanges`'s drag-stop case and `translateSelectionNodes`: resolves
  // the group's PRE-move position the SAME way the view rendered it (`resolveGroupPosition` -
  // the committed position if it's ever been dragged before, otherwise the grid-snapped centroid
  // of its members' current positions, exactly matching what `deriveCollapsedView` placed the
  // tile at) so the delta is never accidentally zero for a group that has never been dragged.
  const computeGroupMoveEntries = useCallback(
    (group: MapGroup, newPosition: { x: number; y: number }): { delta: { x: number; y: number }; entries: PositionUpdateEntry[] } => {
      const committed = resolveGroupPosition(group, nodes, committedGroupPositions);
      const delta = { x: newPosition.x - committed.x, y: newPosition.y - committed.y };
      const entries = nodes
        .filter(n => group.systemIds.includes(n.id))
        .map(n => ({
          solar_system_id: n.id,
          position: { x: n.position.x + delta.x, y: n.position.y + delta.y },
        }));
      return { delta, entries };
    },
    [nodes, committedGroupPositions],
  );

  const collapseGroup = useCallback((key: string) => {
    ref.current.settingsGroupsUpdate(prev => ({
      ...prev,
      collapsedGroups: prev.collapsedGroups.includes(key) ? prev.collapsedGroups : [...prev.collapsedGroups, key],
    }));
  }, []);

  const expandGroup = useCallback((key: string) => {
    ref.current.settingsGroupsUpdate(prev => ({
      ...prev,
      collapsedGroups: prev.collapsedGroups.filter(k => k !== key),
    }));
  }, []);

  const collapseAllRegions = useCallback(() => {
    const regionKeys = Array.from(ref.current.groups.values())
      .filter(g => g.kind === 'region')
      .map(g => g.key);
    ref.current.settingsGroupsUpdate(prev => ({
      ...prev,
      collapsedGroups: Array.from(new Set([...prev.collapsedGroups, ...regionKeys])),
    }));
  }, []);

  const expandAll = useCallback(() => {
    ref.current.settingsGroupsUpdate(prev => ({ ...prev, collapsedGroups: [] }));
  }, []);

  const isGroupCollapsed = useCallback((key: string) => collapsedGroupKeys.has(key), [collapsedGroupKeys]);

  // Intercepts changes targeting a synthetic group node id; everything else is returned
  // unmodified for the caller to feed into the REAL `onNodesChange` against the raw node array.
  const filterGroupNodeChanges = useCallback(
    (changes: NodeChange[]): NodeChange[] => {
      const passthrough: NodeChange[] = [];

      for (const change of changes) {
        if (!('id' in change) || !isGroupNodeId(change.id)) {
          passthrough.push(change);
          continue;
        }

        const key = groupKeyFromNodeId(change.id);
        const group = ref.current.groups.get(key);
        if (!group) {
          continue;
        }

        if (change.type === 'position' && change.position) {
          const newPosition = change.position;
          setLiveDragPositions(prev => ({ ...prev, [key]: newPosition }));

          if (change.dragging === false) {
            // Drag stop: resolve the group's PRE-move position the SAME way the view rendered it
            // (`computeGroupMoveEntries` -> `resolveGroupPosition`), apply the resulting delta to
            // every member's REAL position, then persist the group's new committed position and
            // emit ONE bulk update for every member - members' STORED positions must follow the
            // group, or expanding teleports it back to where it was collapsed. A group that has
            // NEVER been dragged has no entry in `committedGroupPositions`; falling back to
            // `newPosition` there (instead of resolving the real pre-drag position) would make
            // the delta exactly zero and silently fail to move any member - confirmed and fixed,
            // see `useMapGroups.test.tsx`'s "first drag" case.
            const { entries } = computeGroupMoveEntries(group, newPosition);
            const positionById = new Map(entries.map(e => [e.solar_system_id, e.position]));

            setNodes(prevNodes =>
              prevNodes.map(n => (positionById.has(n.id) ? { ...n, position: positionById.get(n.id)! } : n)),
            );

            ref.current.settingsGroupsUpdate(prev => ({
              ...prev,
              groupPositions: { ...prev.groupPositions, [key]: newPosition },
            }));

            setLiveDragPositions(prev => {
              const next = { ...prev };
              delete next[key];
              return next;
            });

            if (entries.length > 0) {
              ref.current.onCommand({
                type: OutCommand.updateSystemPositionsBulk,
                data: entries,
              });
            }
          }
          continue;
        }

        // Select/remove/dimensions on a group id: not meaningful to apply to the raw array (the
        // group id isn't a real node there) - drop silently rather than letting it reach
        // `applyNodeChanges` against an id it doesn't recognise.
      }

      return passthrough;
    },
    [computeGroupMoveEntries, setNodes],
  );

  // A rubber-band selection can contain synthetic group ids alongside real system ids (a group
  // tile selects as itself - see `expandSelectionSystemIds` below for the SEPARATE "what does
  // selecting a group tile mean to onSelectionChange" question). Dragging such a selection must
  // still only ever send REAL system ids to the server: each group in the selection expands to
  // its members, offset by that group's own drag delta (resolved the same way as a solo group
  // drag), with the matching `setNodes`/`settingsGroupsUpdate` side effects applied once up front
  // rather than once per member.
  const translateSelectionNodes = useCallback(
    (selectedNodes: Node[]): PositionUpdateEntry[] => {
      const realEntries: PositionUpdateEntry[] = [];
      const groupCommits: Record<string, { x: number; y: number }> = {};
      let hasGroupCommits = false;
      const allMemberPositions = new Map<string, { x: number; y: number }>();

      for (const n of selectedNodes) {
        if (!isGroupNodeId(n.id)) {
          realEntries.push({ solar_system_id: n.id, position: n.position });
          continue;
        }

        const key = groupKeyFromNodeId(n.id);
        const group = ref.current.groups.get(key);
        if (!group) {
          continue;
        }

        const { entries } = computeGroupMoveEntries(group, n.position);
        realEntries.push(...entries);
        for (const entry of entries) {
          allMemberPositions.set(entry.solar_system_id, entry.position);
        }
        groupCommits[key] = n.position;
        hasGroupCommits = true;
      }

      if (hasGroupCommits) {
        setNodes(prevNodes =>
          prevNodes.map(n => (allMemberPositions.has(n.id) ? { ...n, position: allMemberPositions.get(n.id)! } : n)),
        );
        ref.current.settingsGroupsUpdate(prev => ({
          ...prev,
          groupPositions: { ...prev.groupPositions, ...groupCommits },
        }));
      }

      return realEntries;
    },
    [computeGroupMoveEntries, setNodes],
  );

  const expandSelectionSystemIds = useCallback((ids: string[]): string[] => {
    return ids.flatMap(id => {
      if (!isGroupNodeId(id)) {
        return [id];
      }
      return ref.current.groups.get(groupKeyFromNodeId(id))?.systemIds ?? [];
    });
  }, []);

  return {
    viewNodes,
    viewEdges,
    groups,
    filterGroupNodeChanges,
    translateSelectionNodes,
    expandSelectionSystemIds,
    collapseGroup,
    expandGroup,
    collapseAllRegions,
    expandAll,
    isGroupCollapsed,
  };
}
