import { useEffect, useState, useCallback, useMemo } from 'react';
import { useMapEventListener } from '@/hooks/Mapper/events';
import { Commands } from '@/hooks/Mapper/types';
import { DetailedKill } from '@/hooks/Mapper/types/kills';
import { useMapRootSelector } from '@/hooks/Mapper/mapRootProvider';

const EMPTY_KILLS: DetailedKill[] = [];

interface Kill {
  solar_system_id: number | string;
  kills: number;
}

interface MapEvent {
  name: Commands;
  data?: unknown;
  payload?: Kill[];
}

function getActivityType(count: number): string {
  if (count <= 5) return 'activityNormal';
  if (count <= 30) return 'activityWarn';
  return 'activityDanger';
}

export function useNodeKillsCount(systemId: number | string, initialKillsCount: number | null = null): { killsCount: number | null; killsActivityType: string | null } {
  const [killsCount, setKillsCount] = useState<number | null>(initialKillsCount);
  // Selector-based, not `useMapRootState()`: this hook runs once per node, so a plain
  // `useMapRootState()` read would re-subscribe every node to every OTHER field on
  // `MapRootContextProps` - see docs/chewy/map-perf-findings.md.
  const detailedKillsForSystem = useMapRootSelector(
    ['detailedKills'],
    d => d.detailedKills[systemId] ?? EMPTY_KILLS,
  );
  const hasDetailedKillsForSystem = useMapRootSelector(['detailedKills'], d =>
    Object.prototype.hasOwnProperty.call(d.detailedKills, systemId),
  );

  // Calculate 1-hour kill count from detailed kills
  const oneHourKillCount = useMemo(() => {
    // If we have detailed kills data (even if empty), use it for counting
    if (hasDetailedKillsForSystem) {
      const oneHourAgo = Date.now() - 60 * 60 * 1000; // 1 hour in milliseconds
      const recentKills = detailedKillsForSystem.filter(kill => {
        if (!kill.kill_time) return false;
        const killTime = new Date(kill.kill_time).getTime();
        if (isNaN(killTime)) return false;
        return killTime >= oneHourAgo;
      });

      return recentKills.length; // Return 0 if no recent kills, not null
    }

    // Return null only if we don't have detailed kills data for this system
    return null;
  }, [detailedKillsForSystem, hasDetailedKillsForSystem]);

  useEffect(() => {
    // Always prefer the calculated 1-hour count over initial count
    // This ensures we properly expire old kills
    if (oneHourKillCount !== null) {
      setKillsCount(oneHourKillCount);
    } else if (hasDetailedKillsForSystem && detailedKillsForSystem.length === 0) {
      // If we have detailed kills data but it's empty, set to 0
      setKillsCount(0);
    } else {
      // Only fall back to initial count if we have no detailed kills data at all
      setKillsCount(initialKillsCount);
    }
  }, [oneHourKillCount, initialKillsCount, hasDetailedKillsForSystem, detailedKillsForSystem]);

  const handleEvent = useCallback(
    (event: MapEvent): boolean => {
      if (event.name === Commands.killsUpdated && Array.isArray(event.payload)) {
        const killForSystem = event.payload.find(kill => kill.solar_system_id.toString() === systemId.toString());
        if (killForSystem && typeof killForSystem.kills === 'number') {
          // Only update if we don't have detailed kills data
          if (!hasDetailedKillsForSystem || detailedKillsForSystem.length === 0) {
            setKillsCount(killForSystem.kills);
          }
        }
        return true;
      }
      return false;
    },
    [systemId, hasDetailedKillsForSystem, detailedKillsForSystem],
  );

  useMapEventListener(handleEvent);

  const killsActivityType = useMemo(() => {
    return killsCount !== null && killsCount > 0 ? getActivityType(killsCount) : null;
  }, [killsCount]);

  return { killsCount, killsActivityType };
}
