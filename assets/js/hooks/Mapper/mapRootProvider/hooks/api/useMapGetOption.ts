import { useMapRootSelector } from '@/hooks/Mapper/mapRootProvider';

export const useMapGetOption = (option: string) => {
  // Selector-based: called 3x per node (`useSolarSystemNode.ts`), so this is one of the hottest
  // `useMapRootState()` consumers on the map - see docs/chewy/map-perf-findings.md.
  return useMapRootSelector(['options'], d => d.options[option as keyof typeof d.options]);
};
