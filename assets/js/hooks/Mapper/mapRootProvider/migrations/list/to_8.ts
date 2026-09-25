import { MigrationStructure } from '@/hooks/Mapper/mapRootProvider/types.ts';

export const to_8: MigrationStructure = {
  to: 8,
  up: prev => ({
    ...prev,
    interface: {
      ...prev?.interface,
      dotlanStyleConnections: prev?.interface?.dotlanStyleConnections ?? true,
    },
  }),
};
