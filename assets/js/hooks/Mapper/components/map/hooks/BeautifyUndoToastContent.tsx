// CHEWY PATCH: small presentational piece for the beautify "Undo" toast (see useBeautify.ts).
import { WdButton } from '@/hooks/Mapper/components/ui-kit/WdButton.tsx';
import type { BeautifyMode } from '@/hooks/Mapper/components/map/hooks/useBeautify.ts';

export interface BeautifyUndoToastContentProps {
  movedCount: number;
  mode: Exclude<BeautifyMode, 'auto'>;
  /** CHEWY PATCH: what the pass actually fixed — see LayoutResult.quality. */
  fixedHidden: number;
  crossingsDelta: number;
  /** CHEWY PATCH: connections that went from an arbitrary angle to a clean one (WANDERER_ANGLE_SNAP). */
  squaredUp: number;
  onUndo(): void;
}

export const BeautifyUndoToastContent = ({
  movedCount,
  mode,
  fixedHidden,
  crossingsDelta,
  squaredUp,
  onUndo,
}: BeautifyUndoToastContentProps) => {
  // CHEWY PATCH: incremental placements read as "placed" (new/misplaced nodes only),
  // a full rebuild reads as "moved" (the whole map was re-solved).
  const verb = mode === 'incremental' ? 'placed' : 'moved';

  // CHEWY PATCH: "12 systems placed" says nothing about whether the map got
  // better. A hidden connection (a link drawn under a system's box, or inside
  // another link) is the defect users actually report, so say how many of
  // those went away, and flag a crossing regression instead of hiding it.
  const detail = [
    fixedHidden > 0 ? `${fixedHidden} hidden link${fixedHidden === 1 ? '' : 's'} fixed` : null,
    crossingsDelta < 0 ? `${-crossingsDelta} fewer crossings` : null,
    crossingsDelta > 0 ? `${crossingsDelta} more crossings` : null,
    squaredUp > 0 ? `${squaredUp} link${squaredUp === 1 ? '' : 's'} squared up` : null,
  ]
    .filter(Boolean)
    .join(', ');

  return (
    <div className="flex items-center justify-between gap-3 w-full py-1 pr-1">
      <div className="flex items-center gap-2">
        <i className="pi pi-sparkles text-cyan-400" />
        <div className="flex flex-col">
          <span>{`${movedCount} system${movedCount === 1 ? '' : 's'} ${verb}`}</span>
          {detail && <span className="text-stone-400 text-[11px]">{detail}</span>}
        </div>
      </div>
      <WdButton size="small" outlined label="Undo" onClick={onUndo} />
    </div>
  );
};
