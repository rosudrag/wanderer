import { MigrationStructure } from '@/hooks/Mapper/mapRootProvider/types.ts';

// CHEWY PATCH: ReactFlow `onlyRenderVisibleElements` toggle. Stored settings written before this
// toggle existed have no `onlyRenderVisibleElements` key, and an undefined checkbox would render
// unchecked anyway - but spell the default out explicitly (off; see Map.tsx for why this isn't
// defaulted on) rather than relying on an undefined read happening to behave like `false`.
export const to_10: MigrationStructure = {
  to: 10,
  up: prev => ({
    ...prev,
    interface: {
      ...prev?.interface,
      onlyRenderVisibleElements: prev?.interface?.onlyRenderVisibleElements ?? false,
    },
  }),
};
