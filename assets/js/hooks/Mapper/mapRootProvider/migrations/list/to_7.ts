import { MigrationStructure } from '@/hooks/Mapper/mapRootProvider/types.ts';
import { DEFAULT_BEAUTIFY_SETTINGS } from '@/hooks/Mapper/mapRootProvider/constants.ts';

export const to_7: MigrationStructure = {
  to: 7,
  up: prev => ({
    ...prev,
    beautify: {
      ...DEFAULT_BEAUTIFY_SETTINGS,
      ...prev?.beautify,
    },
  }),
};
