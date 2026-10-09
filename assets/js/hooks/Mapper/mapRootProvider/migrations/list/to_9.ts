import { MigrationStructure } from '@/hooks/Mapper/mapRootProvider/types.ts';

// CHEWY PATCH: EVE Scout publishes Turnur connections alongside Thera's; stored
// settings written before the toggle existed have no `include_turnur` key, and
// an undefined checkbox renders unchecked while the server defaults it on.
export const to_9: MigrationStructure = {
  to: 9,
  up: prev => ({
    ...prev,
    routes: {
      ...prev?.routes,
      include_turnur: prev?.routes?.include_turnur ?? true,
    },
    routesBy: {
      ...prev?.routesBy,
      routes: {
        ...prev?.routesBy?.routes,
        include_turnur: prev?.routesBy?.routes?.include_turnur ?? true,
      },
    },
  }),
};
