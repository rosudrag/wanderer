// CHEWY PATCH: new hook — wires the map beautifier layout engine (components/map/layout)
// into live map state, the bulk position-update command, and an undo toast.
import { createElement, useCallback, useRef, useState } from 'react';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { OutCommand } from '@/hooks/Mapper/types/mapHandlers.ts';
import { useToast } from '@/hooks/Mapper/ToastProvider.tsx';
import {
  beautifyLayout,
  BeautifyAxis,
  KSpaceMode,
  LayoutEdgeInput,
  LayoutNodeInput,
} from '@/hooks/Mapper/components/map/layout';
import { BeautifyUndoToastContent } from '@/hooks/Mapper/components/map/hooks/BeautifyUndoToastContent.tsx';

export type BeautifyScope = 'all' | 'selection';
// CHEWY PATCH: layout mode — 'auto' keeps every validly-placed node untouched and only
// places new/misplaced ones, 'full' re-solves the whole map, 'auto' picks between them.
export type BeautifyMode = 'auto' | 'incremental' | 'full';

export interface BeautifyParams {
  scope: BeautifyScope;
  rootId?: string | null;
  axis?: BeautifyAxis;
  kspaceMode?: KSpaceMode;
  mode?: BeautifyMode;
}

type PositionUpdate = { solar_system_id: string; position: { x: number; y: number } };

/**
 * Reads systems/connections/selection out of the map root state, feeds the pure layout
 * engine, then sends the resulting positions through the existing bulk-update command
 * (which the server broadcasts back to every client, including this one, via the normal
 * per-system update_system path). Captures the pre-move positions of exactly the nodes
 * that moved so `undo()` can restore them precisely.
 */
export const useBeautify = () => {
  const {
    data: { systems, connections, selectedSystems, hubs, options },
    outCommand,
  } = useMapRootState();
  const { show } = useToast();

  const [isBeautifying, setIsBeautifying] = useState(false);
  const [canUndo, setCanUndo] = useState(false);
  const undoSnapshotRef = useRef<PositionUpdate[] | null>(null);

  const isEnabled = options.beautifier_enabled === 'true';

  const ref = useRef({ systems, connections, selectedSystems, hubs, options, outCommand });
  ref.current = { systems, connections, selectedSystems, hubs, options, outCommand };

  const applyPositions = useCallback((entries: PositionUpdate[]) => {
    return ref.current.outCommand({
      type: OutCommand.updateSystemPositionsBulk,
      data: entries,
    });
  }, []);

  const undo = useCallback(async () => {
    const snapshot = undoSnapshotRef.current;
    if (!snapshot || snapshot.length === 0) {
      return;
    }

    undoSnapshotRef.current = null;
    setCanUndo(false);
    await applyPositions(snapshot);
  }, [applyPositions]);

  const beautify = useCallback(
    async ({
      scope,
      rootId = null,
      axis = 'left_to_right',
      kspaceMode = 'geographic',
      mode = 'auto',
    }: BeautifyParams) => {
      const { systems, connections, selectedSystems, hubs, options } = ref.current;

      if (options.beautifier_enabled !== 'true') {
        return;
      }

      const selectedSet = scope === 'selection' ? new Set(selectedSystems) : null;
      const relevantSystems = selectedSet ? systems.filter(system => selectedSet.has(system.id)) : systems;

      if (relevantSystems.length === 0) {
        return;
      }

      const relevantIds = new Set(relevantSystems.map(system => system.id));

      const nodes: LayoutNodeInput[] = relevantSystems.map(system => {
        const staticInfo = system.system_static_info;
        const parsedSecurity = staticInfo?.security !== undefined ? parseFloat(staticInfo.security) : undefined;

        return {
          id: system.id,
          x: system.position.x,
          y: system.position.y,
          locked: system.locked,
          regionId: staticInfo?.region_id,
          systemClass: staticInfo?.system_class,
          security: parsedSecurity !== undefined && Number.isNaN(parsedSecurity) ? undefined : parsedSecurity,
          name: staticInfo?.solar_system_name,
        };
      });

      const edges: LayoutEdgeInput[] = connections
        .filter(connection => relevantIds.has(connection.source) && relevantIds.has(connection.target))
        .map(connection => ({
          source: connection.source,
          target: connection.target,
          type: connection.type ?? 0,
        }));

      setIsBeautifying(true);

      try {
        const result = await beautifyLayout(nodes, edges, {
          axis,
          rootId: scope === 'selection' ? null : rootId,
          hubs,
          kspaceMode,
          mode,
        });

        if (result.movedCount === 0) {
          return;
        }

        const movedIds = Object.keys(result.positions);
        const systemById = new Map(systems.map(system => [system.id, system]));

        const snapshot = movedIds.reduce<PositionUpdate[]>((acc, id) => {
          const system = systemById.get(id);
          if (system) {
            acc.push({ solar_system_id: id, position: { x: system.position.x, y: system.position.y } });
          }
          return acc;
        }, []);

        undoSnapshotRef.current = snapshot;
        setCanUndo(true);

        const newPositions: PositionUpdate[] = movedIds.map(id => ({
          solar_system_id: id,
          position: result.positions[id],
        }));

        await applyPositions(newPositions);

        show({
          severity: 'info',
          life: 8000,
          content: createElement(BeautifyUndoToastContent, {
            movedCount: result.movedCount,
            mode: result.mode,
            onUndo: () => undo(),
          }),
        });
      } finally {
        setIsBeautifying(false);
      }
    },
    [applyPositions, show, undo],
  );

  return { beautify, undo, canUndo, isEnabled, isBeautifying };
};
