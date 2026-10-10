// CHEWY PATCH: new file. Collapsed-group canvas tile for the map region/wormhole-chain collapse
// feature (WANDERER_MAP_GROUPS) - replaces a region's or chain's member systems with one
// draggable node. Presentational only; all data comes from `GroupNodeData` computed once in
// `deriveCollapsedView.ts`, not read live from any store - matches `SolarSystemNodeDefault`'s own
// node-local-data-only shape, just without the dozen map-store selectors a real system needs.
import { memo } from 'react';
import { Handle, NodeProps, Position } from 'reactflow';
import clsx from 'clsx';
import { PrimeIcons } from 'primereact/api';
import classes from './GroupNode.module.scss';
import { GroupNodeData } from '@/hooks/Mapper/components/map/groups/deriveCollapsedView';

export const GroupNode = memo((props: NodeProps<GroupNodeData>) => {
  const { data, selected } = props;

  return (
    <div
      className={clsx(classes.GroupNode, {
        [classes.selected]: selected,
        [classes.rally]: data.hasRally,
        [classes.chain]: data.kind === 'chain',
      })}
    >
      <div className={classes.HeadRow}>
        <i className={clsx(PrimeIcons[data.kind === 'chain' ? 'SITEMAP' : 'MAP'], classes.icon)} />
        <span className={classes.displayName}>{data.displayName}</span>
      </div>
      <div className={classes.BottomRow}>
        <span className={classes.memberCount} title="Systems in this group">
          {data.memberIds.length} systems
        </span>
        {data.onlineCount > 0 && (
          <span className={classes.onlineCount} title="Online pilots in this group">
            <i className={clsx(PrimeIcons.USER, classes.icon)} />
            {data.onlineCount}
          </span>
        )}
        {data.hasCurrentCharacterLocation && (
          <i className={clsx(PrimeIcons.MAP_MARKER, classes.icon, classes.locationMarker)} title="You are here" />
        )}
      </div>

      <Handle type="source" className={clsx(classes.Handle, classes.HandleTop)} position={Position.Top} id="a" />
      <Handle type="source" className={clsx(classes.Handle, classes.HandleRight)} position={Position.Right} id="b" />
      <Handle type="source" className={clsx(classes.Handle, classes.HandleBottom)} position={Position.Bottom} id="c" />
      <Handle type="source" className={clsx(classes.Handle, classes.HandleLeft)} position={Position.Left} id="d" />
    </div>
  );
});

GroupNode.displayName = 'GroupNode';
