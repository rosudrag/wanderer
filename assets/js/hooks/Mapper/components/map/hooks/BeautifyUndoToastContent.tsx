// CHEWY PATCH: small presentational piece for the beautify "Undo" toast (see useBeautify.ts).
import { WdButton } from '@/hooks/Mapper/components/ui-kit/WdButton.tsx';
import type { BeautifyMode } from '@/hooks/Mapper/components/map/hooks/useBeautify.ts';

export interface BeautifyUndoToastContentProps {
  movedCount: number;
  mode: Exclude<BeautifyMode, 'auto'>;
  onUndo(): void;
}

export const BeautifyUndoToastContent = ({ movedCount, mode, onUndo }: BeautifyUndoToastContentProps) => {
  // CHEWY PATCH: incremental placements read as "placed" (new/misplaced nodes only),
  // a full rebuild reads as "moved" (the whole map was re-solved).
  const verb = mode === 'incremental' ? 'placed' : 'moved';
  return (
    <div className="flex items-center justify-between gap-3 w-full py-1 pr-1">
      <div className="flex items-center gap-2">
        <i className="pi pi-sparkles text-cyan-400" />
        <span>{`${movedCount} system${movedCount === 1 ? '' : 's'} ${verb}`}</span>
      </div>
      <WdButton size="small" outlined label="Undo" onClick={onUndo} />
    </div>
  );
};
