import { NodeSelectionMouseHandler } from '@/hooks/Mapper/components/contexts/types.ts';
import { PingData, SolarSystemConnection, SolarSystemRawType } from '@/hooks/Mapper/types';
import { MapHandlers, OutCommand, OutCommandHandler } from '@/hooks/Mapper/types/mapHandlers.ts';
import { ctxManager } from '@/hooks/Mapper/utils/contextManager.ts';
import type { PanelPosition } from '@reactflow/core';
import clsx from 'clsx';
import { ForwardedRef, forwardRef, memo, MouseEvent, useCallback, useEffect, useMemo, useRef } from 'react';
import ReactFlow, {
  Background,
  Edge,
  MiniMap,
  Node,
  NodeChange,
  NodeDragHandler,
  OnConnect,
  OnMoveEnd,
  OnSelectionChangeFunc,
  SelectionDragHandler,
  SelectionMode,
  useReactFlow,
} from 'reactflow';
import 'reactflow/dist/style.css';
import classes from './Map.module.scss';
import { MapProvider, useMapState } from './MapProvider';
import {
  ContextMenuConnection,
  ContextMenuRoot,
  SolarSystemEdge,
  useContextMenuConnectionHandlers,
  useContextMenuRootHandlers,
} from './components';
import { getBehaviorForTheme } from './helpers/getThemeBehavior';
import { useEdgesState, useMapHandlers, useNodesState, useUpdateNodes } from './hooks';
import { useBackgroundVars } from './hooks/useBackgroundVars';
import { MapViewport, OnMapAddSystemCallback, OnMapSelectionChange } from './map.types';
import type { Viewport } from '@reactflow/core/dist/esm/types';
import { usePrevious } from 'primereact/hooks';
import { useMapRootSelector } from '@/hooks/Mapper/mapRootProvider';
// CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS).
import { GroupNode } from './components/GroupNode';
import { SettingsGroupsUpdate, useMapGroups } from './hooks/useMapGroups';
import { groupKeyFromNodeId, isGroupNodeId } from './groups/deriveCollapsedView';

const initialNodes: Node<SolarSystemRawType>[] = [
  // {
  //   id: '31122321',
  //   width: 100,
  //   height: 28,
  //   position: { x: 0, y: 0 },
  //   data: {
  //     id: '31122321',
  //     solarSystemName: 'J111447',
  //     classTitle: 'C6',
  //   },
  //   type: 'custom',
  // },
];

const initialEdges = [
  {
    id: '1-2',
    source: '_____kek',
    target: '_____cheburek',
    sourceHandle: 'c',
    targetHandle: 'a',
    type: 'floating',
    // markerEnd: { type: MarkerType.Arrow },
    label: 'updatable edge',
  },
];

const edgeTypes = {
  floating: SolarSystemEdge,
};

export const MAP_ROOT_ID = 'MAP_ROOT_ID';

interface MapCompProps {
  refn: ForwardedRef<MapHandlers>;
  onCommand: OutCommandHandler;
  onSelectionChange: OnMapSelectionChange;
  onConnectionInfoClick?(e: SolarSystemConnection): void;
  onAddSystem?: OnMapAddSystemCallback;
  onSelectionContextMenu?: NodeSelectionMouseHandler;
  onChangeViewport?: (viewport: MapViewport) => void;
  minimapClasses?: string;
  isShowMinimap?: boolean;
  onSystemContextMenu: (event: MouseEvent<Element>, systemId: string) => void;
  showKSpaceBG?: boolean;
  isThickConnections?: boolean;
  isShowBackgroundPattern?: boolean;
  isSoftBackground?: boolean;
  theme?: string;
  pings: PingData[];
  minimapPlacement?: PanelPosition;
  localShowShipName?: boolean;
  defaultViewport?: Viewport;
  // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) - the stable per-map
  // settings setter (`useSettingsValueAndSetter`'s own `useCallback([])`), threaded down from
  // `MapWrapper.tsx` rather than read here via `useMapRootState()`, which would re-subscribe the
  // whole canvas to every other `MapRootContextProps` field - see docs/chewy/map-perf-findings.md.
  settingsGroupsUpdate?: SettingsGroupsUpdate;
}

const MapComp = ({
  refn,
  onCommand,
  minimapClasses,
  onSelectionChange,
  onSystemContextMenu,
  onConnectionInfoClick,
  onSelectionContextMenu,
  isShowMinimap,
  showKSpaceBG,
  isThickConnections,
  isShowBackgroundPattern,
  isSoftBackground,
  theme,
  onAddSystem,
  pings,
  minimapPlacement = 'bottom-right',
  localShowShipName = false,
  onChangeViewport,
  defaultViewport,
  settingsGroupsUpdate,
}: MapCompProps) => {
  const { getNodes, setViewport } = useReactFlow();
  const [nodes, setNodes, onNodesChange] = useNodesState<Node<SolarSystemRawType>>(initialNodes);
  const [edges, , onEdgesChange] = useEdgesState<Edge<SolarSystemConnection>>(initialEdges);

  useMapHandlers(refn, onSelectionChange);
  useUpdateNodes(nodes);

  const { handleRootContext, ...rootCtxProps } = useContextMenuRootHandlers({ onAddSystem, onCommand });
  const { handleConnectionContext, ...connectionCtxProps } = useContextMenuConnectionHandlers();
  const { update } = useMapState();
  // Selector-based, not `useMapRootState()`: `MapComp` is the parent of every node/edge on the
  // canvas, so a plain `useMapRootState()` read here would make the WHOLE canvas subtree
  // re-render (and, per measurement, ReactFlow re-creates node wrapper props on its own
  // re-render, defeating every node's own `React.memo`) on every `MapRootProvider` write -
  // including the server-pushed character/kill/signature bursts this store exists to isolate
  // from the render path. See docs/chewy/map-perf-findings.md.
  const onlyRenderVisibleElements = useMapRootSelector(
    ['interfaceSettings'],
    d => d.interfaceSettings.onlyRenderVisibleElements,
  );
  // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS), off upstream.
  const groupsEnabled = useMapRootSelector(['options'], d => d.options.groups_enabled === 'true');
  const noopSettingsGroupsUpdate: SettingsGroupsUpdate = useCallback(() => {}, []);
  const {
    viewNodes,
    viewEdges,
    filterGroupNodeChanges,
    translateSelectionNodes,
    expandSelectionSystemIds,
    expandGroup,
    collapseAllRegions,
    expandAll,
  } = useMapGroups({
    enabled: groupsEnabled,
    nodes,
    edges,
    setNodes,
    onCommand,
    settingsGroupsUpdate: settingsGroupsUpdate ?? noopSettingsGroupsUpdate,
  });
  const { variant, gap, size, color } = useBackgroundVars(theme);
  const { isPanAndDrag, nodeComponent, connectionMode } = getBehaviorForTheme(theme || 'default');

  const refVars = useRef({ onChangeViewport });
  refVars.current = { onChangeViewport };

  const nodeTypes = useMemo(() => {
    return {
      custom: nodeComponent,
      // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS).
      group: GroupNode,
    };
  }, [nodeComponent]);

  const onConnect: OnConnect = useCallback(
    params => {
      const { source, target } = params;

      onCommand({
        type: OutCommand.manualAddConnection,
        data: { source, target },
      });
    },
    [onCommand],
  );

  const handleDragStop: NodeDragHandler = useCallback(
    (_, node) => {
      // CHEWY PATCH: a group node's own drag-stop position write is handled entirely inside
      // `useMapGroups`'s `filterGroupNodeChanges` (translates into a per-member bulk update) -
      // this handler must not ALSO fire `updateSystemPosition` for the synthetic group id.
      if (isGroupNodeId(node.id)) {
        return;
      }

      // eslint-disable-next-line no-console
      setTimeout(() => {
        onCommand({
          type: OutCommand.updateSystemPosition,
          data: { solar_system_id: node.id, position: node.position },
        });
      }, 500);
    },
    [onCommand],
  );

  const handleSelectionDragStop: SelectionDragHandler = useCallback(
    (_, nodes) => {
      // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) - a rubber-band
      // selection can include synthetic group ids; `translateSelectionNodes` expands each into
      // its real members offset by that group's own drag delta (and performs the matching
      // `setNodes`/`settingsGroupsUpdate` side effects) so this never sends a `group:` id to the
      // server, while still moving every system the user visually dragged.
      const entries = translateSelectionNodes(nodes);
      setTimeout(() => {
        onCommand({
          type: OutCommand.updateSystemPositions,
          data: entries,
        });
      }, 500);
    },
    [onCommand, translateSelectionNodes],
  );

  const resetContexts = useCallback(() => ctxManager.reset(), []);

  const handleSelectionChange: OnSelectionChangeFunc = useCallback(
    ({ edges, nodes }) => {
      // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) - a selected group
      // tile reports as "its member systems are selected", not as an unresolvable synthetic id -
      // that is what the user means by selecting a region tile, and it is what makes beautify
      // `scope: 'selection'` (and anything else downstream of `onSelectionChange`) resolve real
      // systems instead of silently finding zero.
      onSelectionChange({
        connections: edges.map(({ source, target }) => ({ source, target })),
        systems: expandSelectionSystemIds(nodes.map(x => x.id)),
      });
    },
    [onSelectionChange, expandSelectionSystemIds],
  );

  const handleMoveEnd: OnMoveEnd = useCallback((_, viewport) => {
    // @ts-ignore
    refVars.current.onChangeViewport?.(viewport);
  }, []);

  // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) - clicking a group
  // tile expands it; a regular system node's click/select behaviour is untouched.
  const handleNodeClick = useCallback(
    (_: unknown, node: Node) => {
      if (isGroupNodeId(node.id)) {
        expandGroup(groupKeyFromNodeId(node.id));
      }
    },
    [expandGroup],
  );

  const handleNodesChange = useCallback(
    (changes: NodeChange[]) => {
      // prevents single node deselection on background / same node click
      // allows deseletion of all nodes if multiple are currently selected
      if (changes.length === 1 && changes[0].type == 'select' && changes[0].selected === false) {
        changes[0].selected = getNodes().filter(node => node.selected).length === 1;
      }

      // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS) - a change
      // targeting a synthetic group id (drag/select/remove) is intercepted and translated into
      // real per-member writes inside `useMapGroups`; only what's left (changes against REAL
      // node ids) reaches the raw `onNodesChange` below. A no-op when nothing is collapsed.
      const realChanges = groupsEnabled ? filterGroupNodeChanges(changes) : changes;
      if (realChanges.length === 0) {
        return;
      }

      onNodesChange(realChanges);
    },
    [getNodes, onNodesChange, groupsEnabled, filterGroupNodeChanges],
  );

  useEffect(() => {
    update(x => ({
      ...x,
      showKSpaceBG: showKSpaceBG,
      isThickConnections: isThickConnections,
      pings,
      localShowShipName,
    }));
  }, [showKSpaceBG, isThickConnections, pings, update, localShowShipName]);

  const prevViewport = usePrevious(defaultViewport);
  useEffect(() => {
    if (defaultViewport == null) {
      return;
    }

    if (prevViewport == null) {
      return;
    }

    setViewport(defaultViewport);
  }, [defaultViewport, prevViewport, setViewport]);

  return (
    <>
      <div
        data-window-id={MAP_ROOT_ID}
        className={clsx(classes.MapRoot, { [classes.BackgroundAlternateColor]: isSoftBackground })}
      >
        <ReactFlow
          nodes={viewNodes}
          edges={viewEdges}
          onNodesChange={handleNodesChange}
          onEdgesChange={onEdgesChange}
          onConnect={onConnect}
          // TODO we need save into session all of this
          //      and on any action do either
          defaultViewport={defaultViewport}
          edgeTypes={edgeTypes}
          nodeTypes={nodeTypes}
          connectionMode={connectionMode}
          snapToGrid
          nodeDragThreshold={10}
          onNodeDragStop={handleDragStop}
          onNodeClick={handleNodeClick}
          onSelectionDragStop={handleSelectionDragStop}
          onConnectStart={() => update({ isConnecting: true })}
          onConnectEnd={() => update({ isConnecting: false })}
          onNodeMouseEnter={(_, node) => update({ hoverNodeId: node.id })}
          onPaneClick={event => {
            event.preventDefault();
            event.stopPropagation();
          }}
          // onKeyUp=
          onNodeMouseLeave={() => update({ hoverNodeId: null })}
          onEdgeClick={(_, t) => {
            onConnectionInfoClick?.(t.data);
          }}
          onEdgeContextMenu={handleConnectionContext}
          onNodeContextMenu={(ev, node) => onSystemContextMenu(ev, node.id)}
          // TODO don't know why this error appear - but it annoying
          // eslint-disable-next-line @typescript-eslint/ban-ts-comment
          // @ts-expect-error
          onPaneContextMenu={handleRootContext}
          onSelectionContextMenu={(ev, nodes) => onSelectionContextMenu?.(ev, nodes)}
          onSelectionChange={handleSelectionChange} // TODO - somewhy calling 2 times. don't know why
          // onSelectionEnd={handleSelectionChange}
          onMoveStart={resetContexts}
          onMouseDown={resetContexts}
          onMoveEnd={handleMoveEnd}
          minZoom={0.2}
          maxZoom={1.5}
          elevateNodesOnSelect
          deleteKeyCode={['']}
          {...(isPanAndDrag
            ? {
                selectionOnDrag: true,
                panOnDrag: [2],
              }
            : {})}
          // CHEWY PATCH: `onlyRenderVisibleElements` (unmounts off-screen nodes/edges, cutting
          // render cost close to "what's on screen" instead of every node on the map) defaults
          // OFF, opt-in via the "Only render visible elements" map setting. ReactFlow does not
          // measure (ResizeObserver) a node until it is mounted, and an edge whose endpoint has
          // never been measured is filtered out of the tree entirely by ReactFlow itself before
          // the edge component even runs (confirmed: not something app code can fall back around -
          // see docs/chewy/map-perf-findings.md "Hotspot 5" / "onlyRenderVisibleElements"), so a
          // long-range connection to a system that has never scrolled into view can stay invisible
          // until it does. Kept opt-in rather than hardcoded on because that risk could not be
          // verified safe in a real browser from this investigation.
          onlyRenderVisibleElements={onlyRenderVisibleElements}
          selectionMode={SelectionMode.Partial}
        >
          {isShowMinimap && (
            <MiniMap pannable zoomable ariaLabel="Mini map" className={minimapClasses} position={minimapPlacement} />
          )}
          {isShowBackgroundPattern && <Background variant={variant} gap={gap} size={size} color={color} />}
        </ReactFlow>
        {/* <button className="z-auto btn btn-primary absolute top-20 right-20" onClick={handleGetPassages}>
          Test // DON NOT REMOVE
        </button> */}
      </div>

      <ContextMenuRoot
        {...rootCtxProps}
        groupsEnabled={groupsEnabled}
        onCollapseAllRegions={collapseAllRegions}
        onExpandAllGroups={expandAll}
      />
      <ContextMenuConnection {...connectionCtxProps} />
    </>
  );
};

export type MapPropsType = Omit<MapCompProps, 'refn'>;

// `memo()`-wrapped: `Map`/`MapComp` sit directly below `MapRootProvider` in the tree (via
// `MapRootHandlers` -> `MapRootContent`/`MapWrapper`), so without this, ANY ancestor re-render
// (e.g. `MapRootProvider`'s own re-render on a data-store write - see
// `ALL_MAP_ROOT_DATA_KEYS`'s comment in MapRootProvider.tsx) would cascade through this whole
// subtree via React's default reconciliation and defeat every node/edge's own `React.memo`,
// REGARDLESS of `useMapSelector`/`useMapRootSelector` isolation inside it - those hooks only stop
// a SELECTOR's own re-render trigger, not a PARENT-driven one. Requires every prop passed to
// `<Map>` to be referentially stable across an unrelated parent re-render (the caller's own
// responsibility - see docs/chewy/map-perf-findings.md).
// TODO: INFO - this component needs for correct work map provider
// eslint-disable-next-line react/display-name
export const Map = memo(
  forwardRef((props: MapPropsType, ref: ForwardedRef<MapHandlers>) => {
    return (
      <MapProvider onCommand={props.onCommand}>
        <MapComp refn={ref} {...props} />
      </MapProvider>
    );
  }),
);
