// CHEWY PATCH: new file. Dotlan renders connections as plain centre-to-centre <line> elements (see
// verified facts in the task brief), so this edge draws one straight segment instead of the floating
// bezier used by SolarSystemEdge, clipped to the node boxes, and colours it by constellation/region
// boundary the same way Dotlan's own region SVGs do (.j / .jc / .jr classes).
import { useCallback, useMemo, useState } from 'react';

import classes from './DotlanEdge.module.scss';
import { EdgeLabelRenderer, EdgeProps, useStore } from 'reactflow';
import type { Node } from 'reactflow';
import clsx from 'clsx';
import { ConnectionType, MassState, ShipSizeStatus, SolarSystemConnection, TimeStatus } from '@/hooks/Mapper/types';
import { PrimeIcons } from 'primereact/api';
import { WdTooltipWrapper } from '@/hooks/Mapper/components/ui-kit/WdTooltipWrapper';
import { useMapState } from '@/hooks/Mapper/components/map/MapProvider.tsx';
import { SHIP_SIZES_DESCRIPTION, SHIP_SIZES_NAMES_SHORT } from '@/hooks/Mapper/components/map/constants.ts';
import { TooltipPosition } from '@/hooks/Mapper/components/ui-kit';
import { getSystemStaticInfo } from '@/hooks/Mapper/mapRootProvider/hooks/useLoadSystemStatic';
import { SHIP_SIZES_COLORS } from './SolarSystemEdge';

// Nodes are placed as 130x34 boxes (see convertSystem2Node.ts); used as a fallback only, the real
// bounds are read from ReactFlow's node internals below.
const DEFAULT_NODE_WIDTH = 130;
const DEFAULT_NODE_HEIGHT = 34;

type Point = { x: number; y: number };
type Boundary = 'none' | 'constellation' | 'region';

const getNodeCenter = (node: Node): Point => ({
  x: (node.positionAbsolute?.x ?? node.position.x) + (node.width ?? DEFAULT_NODE_WIDTH) / 2,
  y: (node.positionAbsolute?.y ?? node.position.y) + (node.height ?? DEFAULT_NODE_HEIGHT) / 2,
});

/**
 * Clips the ray starting at box centre (cx, cy) travelling in direction (dx, dy) to the border of
 * the axis-aligned box with half-extents (halfW, halfH) centred at (cx, cy). The centre is always
 * inside the box, so the exit point is at the smallest positive scale `t` (of `dx`/`dy`) that first
 * reaches either the vertical edges (x = cx +/- halfW) or the horizontal edges (y = cy +/- halfH).
 */
const clipToBoxBorder = (cx: number, cy: number, halfW: number, halfH: number, dx: number, dy: number): Point => {
  if (dx === 0 && dy === 0) {
    return { x: cx, y: cy };
  }

  const tx = dx !== 0 ? halfW / Math.abs(dx) : Infinity;
  const ty = dy !== 0 ? halfH / Math.abs(dy) : Infinity;
  const t = Math.min(tx, ty);

  return { x: cx + dx * t, y: cy + dy * t };
};

export const DotlanEdge = ({ id, source, target, markerEnd, style, data }: EdgeProps<SolarSystemConnection>) => {
  const sourceNode = useStore(useCallback(store => store.nodeInternals.get(source), [source]));
  const targetNode = useStore(useCallback(store => store.nodeInternals.get(target), [target]));
  const isWormhole = data?.type === ConnectionType.wormhole;
  const isBridge = data?.type === ConnectionType.bridge;
  // Everything that isn't a wormhole or a bridge (i.e. gates, and connections with no type) is
  // coloured by Dotlan's constellation/region boundary semantics instead of the flat gate green.
  const isBoundaryColored = !isWormhole && !isBridge;

  const {
    data: { isThickConnections },
  } = useMapState();

  const [hovered, setHovered] = useState(false);

  const [sourcePoint, targetPoint, labelX, labelY] = useMemo(() => {
    if (!sourceNode || !targetNode) {
      return [null, null, 0, 0] as const;
    }

    const sourceCenter = getNodeCenter(sourceNode);
    const targetCenter = getNodeCenter(targetNode);

    const sourceHalfW = (sourceNode.width ?? DEFAULT_NODE_WIDTH) / 2;
    const sourceHalfH = (sourceNode.height ?? DEFAULT_NODE_HEIGHT) / 2;
    const targetHalfW = (targetNode.width ?? DEFAULT_NODE_WIDTH) / 2;
    const targetHalfH = (targetNode.height ?? DEFAULT_NODE_HEIGHT) / 2;

    const dx = targetCenter.x - sourceCenter.x;
    const dy = targetCenter.y - sourceCenter.y;

    const start = clipToBoxBorder(sourceCenter.x, sourceCenter.y, sourceHalfW, sourceHalfH, dx, dy);
    const end = clipToBoxBorder(targetCenter.x, targetCenter.y, targetHalfW, targetHalfH, -dx, -dy);

    return [start, end, (start.x + end.x) / 2, (start.y + end.y) / 2] as const;
  }, [sourceNode, targetNode]);

  const boundary: Boundary = useMemo(() => {
    if (!isBoundaryColored) {
      return 'none';
    }

    const sourceInfo = getSystemStaticInfo(source);
    const targetInfo = getSystemStaticInfo(target);

    if (!sourceInfo || !targetInfo) {
      return 'none';
    }

    if (sourceInfo.region_id !== targetInfo.region_id) {
      return 'region';
    }

    if (sourceInfo.constellation_id !== targetInfo.constellation_id) {
      return 'constellation';
    }

    return 'none';
  }, [isBoundaryColored, source, target]);

  if (!sourceNode || !targetNode || !data || !sourcePoint || !targetPoint) {
    return null;
  }

  const path = `M ${sourcePoint.x},${sourcePoint.y} L ${targetPoint.x},${targetPoint.y}`;

  return (
    <>
      <path
        id={`back_${id}`}
        className={clsx(classes.EdgePathBack, {
          [classes.Tick]: isThickConnections,
          [classes.time1]: isWormhole && data.time_status === TimeStatus._1h,
          [classes.time4]: isWormhole && data.time_status === TimeStatus._4h,
          [classes.Hovered]: hovered,
          [classes.Bridge]: isBridge,
          [classes.BoundaryNone]: isBoundaryColored && boundary === 'none',
          [classes.BoundaryConstellation]: isBoundaryColored && boundary === 'constellation',
          [classes.BoundaryRegion]: isBoundaryColored && boundary === 'region',
        })}
        d={path}
        markerEnd={markerEnd}
        style={style}
      />
      <path
        id={`front_${id}`}
        className={clsx(classes.EdgePathFront, {
          [classes.Tick]: isThickConnections,
          [classes.Hovered]: hovered,
          [classes.MassVerge]: isWormhole && data.mass_status === MassState.verge,
          [classes.MassHalf]: isWormhole && data.mass_status === MassState.half,
          [classes.Frigate]: isWormhole && data.ship_size_type === ShipSizeStatus.small,
          [classes.Gate]: isBoundaryColored,
          [classes.Bridge]: isBridge,
        })}
        d={path}
        markerEnd={markerEnd}
        style={style}
      />
      <path
        id={id}
        className={classes.ClickPath}
        d={path}
        markerEnd={markerEnd}
        style={style}
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
      />

      <EdgeLabelRenderer>
        <div
          className="absolute flex items-center gap-1 pointer-events-none"
          style={{
            transform: `translate(-50%, -50%) translate(${labelX}px,${labelY}px)`,
          }}
        >
          {isWormhole && data.locked && (
            <WdTooltipWrapper
              content="Save mass"
              className={clsx(
                classes.LinkLabel,
                'pointer-events-auto bg-amber-300 rounded opacity-100 cursor-auto text-neutral-900',
              )}
            >
              <span className={clsx(PrimeIcons.LOCK, classes.icon)} />
            </WdTooltipWrapper>
          )}

          {isBridge && (
            <WdTooltipWrapper
              content="Ansiblex Jump Bridge"
              position={TooltipPosition.top}
              className={clsx(
                classes.LinkLabel,
                'pointer-events-auto bg-lime-300 rounded opacity-100 cursor-auto text-neutral-900',
              )}
            >
              B
            </WdTooltipWrapper>
          )}

          {isWormhole && data.ship_size_type !== ShipSizeStatus.large && (
            <WdTooltipWrapper
              content={SHIP_SIZES_DESCRIPTION[data.ship_size_type]}
              className={clsx(
                classes.LinkLabel,
                'pointer-events-auto rounded opacity-100 cursor-auto text-neutral-900 font-bold',
                SHIP_SIZES_COLORS[data.ship_size_type],
              )}
            >
              {SHIP_SIZES_NAMES_SHORT[data.ship_size_type]}
            </WdTooltipWrapper>
          )}
        </div>
      </EdgeLabelRenderer>
    </>
  );
};
