// CHEWY PATCH: small presentational piece for the beautify "Undo" toast (see useBeautify.ts).
import { WdButton } from '@/hooks/Mapper/components/ui-kit/WdButton.tsx';

export interface BeautifyUndoToastContentProps {
  movedCount: number;
  onUndo(): void;
}

export const BeautifyUndoToastContent = ({ movedCount, onUndo }: BeautifyUndoToastContentProps) => {
  return (
    <div className="flex items-center justify-between gap-3 w-full py-1 pr-1">
      <div className="flex items-center gap-2">
        <i className="pi pi-sparkles text-cyan-400" />
        <span>{`${movedCount} system${movedCount === 1 ? '' : 's'} moved`}</span>
      </div>
      <WdButton size="small" outlined label="Undo" onClick={onUndo} />
    </div>
  );
};
