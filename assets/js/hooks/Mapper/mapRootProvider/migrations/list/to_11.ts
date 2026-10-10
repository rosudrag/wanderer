import { MigrationStructure } from '@/hooks/Mapper/mapRootProvider/types.ts';
import { DEFAULT_MAP_GROUPS_SETTINGS } from '@/hooks/Mapper/mapRootProvider/constants.ts';

// CHEWY PATCH: map region/wormhole-chain collapse settings migration. A stored blob written
// before this feature existed has no `groups` key at all - default it in rather than relying on
// an undefined read behaving like the empty-state default everywhere it's read.
export const to_11: MigrationStructure = {
  to: 11,
  up: prev => ({
    ...prev,
    groups: {
      ...DEFAULT_MAP_GROUPS_SETTINGS,
      ...prev?.groups,
    },
  }),
};
