import { useMapState } from '@/hooks/Mapper/components/map/MapProvider.tsx';
import { SolarSystemRawType } from '@/hooks/Mapper/types';
import { useCallback, useEffect, useRef } from 'react';
import { Node, useOnViewportChange, useReactFlow } from 'reactflow';

const useThrottle = () => {
  const throttleSeed = useRef<number | null>(null);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const throttleFunction = useRef((func: any, delay = 200) => {
    if (!throttleSeed.current) {
      func();
      throttleSeed.current = setTimeout(() => {
        throttleSeed.current = null;
      }, delay);
    }
  });

  return throttleFunction.current;
};

// Exported for test reuse (so the perf/diagnostic harness can compute a REALISTIC viewport-shift
// visible set using the exact same formula production uses, instead of guessing).
export const X_OFFSET = 50;
export const Y_OFFSET = 50;

export type Viewport = { x: number; y: number; width: number; height: number };

export const isNodeVisible = (node: Node, viewport: Viewport) => {
  const { x: nodeX, y: nodeY } = node.position;
  const { width, height } = node;

  return (
    nodeX + (width ?? 0) + X_OFFSET > viewport.x &&
    nodeX - X_OFFSET < viewport.x + viewport.width &&
    nodeY + (height ?? 0) + Y_OFFSET > viewport.y &&
    nodeY - Y_OFFSET < viewport.y + viewport.height
  );
};

const sameMembers = (a: Set<string>, b: Set<string>) => {
  if (a.size !== b.size) {
    return false;
  }
  for (const id of a) {
    if (!b.has(id)) {
      return false;
    }
  }
  return true;
};

export const useUpdateNodes = (nodes: Node<SolarSystemRawType>[]) => {
  const { screenToFlowPosition } = useReactFlow();
  const throttle = useThrottle();
  const { update } = useMapState();

  const ref = useRef({ screenToFlowPosition });
  ref.current = { screenToFlowPosition };

  // What the last visibility computation saw: which viewport, which node OBJECT (so a moved
  // node's position is detected by reference, not a per-frame deep compare) per id, and the
  // resulting visible-id set. A drag frame changes exactly one node's position and nothing else
  // about the map - comparing against this lets that case patch the one changed node's visibility
  // in O(1) instead of re-`filter()`ing every node on the map.
  const lastRef = useRef<{
    viewport: Viewport | undefined;
    byId: Map<string, Node<SolarSystemRawType>>;
    visible: Set<string>;
  }>({ viewport: undefined, byId: new Map(), visible: new Set() });

  const getViewport = useCallback((): Viewport | undefined => {
    const clientRect = document.querySelector('.react-flow__renderer')?.getBoundingClientRect();

    if (!clientRect) {
      return undefined;
    }

    const { screenToFlowPosition } = ref.current;

    const topLeft = screenToFlowPosition({ x: clientRect.left, y: clientRect.top });
    const bottomRight = screenToFlowPosition({ x: clientRect.right, y: clientRect.bottom });
    return {
      x: topLeft.x,
      y: topLeft.y,
      width: bottomRight.x - topLeft.x,
      height: bottomRight.y - topLeft.y,
    };
  }, []);

  // Commits a newly-computed visible-id set, but only if it actually differs from the last one -
  // same size, same members is a no-op: no `update()` call, no notify, no re-render anywhere.
  const commitVisible = useCallback(
    (next: Set<string>) => {
      if (sameMembers(next, lastRef.current.visible)) {
        return;
      }
      lastRef.current.visible = next;
      update({ visibleNodes: next });
    },
    [update],
  );

  const recomputeAll = useCallback(() => {
    if (!nodes.length) {
      return;
    }

    const viewport = getViewport();
    lastRef.current.viewport = viewport;
    lastRef.current.byId = new Map(nodes.map(n => [n.id, n]));

    if (!viewport) {
      commitVisible(new Set(nodes.map(x => x.id)));
      return;
    }

    commitVisible(new Set(nodes.filter(x => isNodeVisible(x, viewport)).map(x => x.id)));
  }, [nodes, getViewport, commitVisible]);

  // Viewport pan/zoom can change every node's visibility, so this path always does a full
  // recompute - throttled exactly as before.
  useOnViewportChange({
    onChange: () => throttle(() => recomputeAll()),
    onEnd: () => throttle(() => recomputeAll()),
  });

  // The node SET or a node's POSITION changing is the only other thing that can change
  // visibility. Membership changes (added/removed systems) still need a full recompute; a drag
  // frame (same ids, one node's position object changed) only needs that node re-checked.
  useEffect(() => {
    if (!nodes.length) {
      return;
    }

    const { byId: lastById, viewport } = lastRef.current;

    const idsChanged = nodes.length !== lastById.size || nodes.some(n => !lastById.has(n.id));

    if (idsChanged || !viewport) {
      recomputeAll();
      return;
    }

    const moved = nodes.filter(n => lastById.get(n.id)?.position !== n.position);
    if (moved.length === 0) {
      return;
    }

    lastRef.current.byId = new Map(nodes.map(n => [n.id, n]));

    const next = new Set(lastRef.current.visible);
    moved.forEach(n => {
      if (isNodeVisible(n, viewport)) {
        next.add(n.id);
      } else {
        next.delete(n.id);
      }
    });

    commitVisible(next);
    // `recomputeAll`/`commitVisible` close over `nodes` themselves (via their own deps); this
    // effect only needs to re-run when the `nodes` array identity changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nodes]);
};
