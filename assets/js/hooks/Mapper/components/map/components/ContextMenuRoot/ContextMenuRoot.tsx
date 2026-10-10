import React, { RefObject, useMemo } from 'react';
import { ContextMenu } from 'primereact/contextmenu';
import { PrimeIcons } from 'primereact/api';
import { MenuItem } from 'primereact/menuitem';
import { PasteSystemsAndConnections } from '@/hooks/Mapper/components/map/components';
import { useMapSelector } from '@/hooks/Mapper/components/map/MapProvider.tsx';
import { checkPermissions } from '@/hooks/Mapper/components/map/helpers';
import { MenuItemWithInfo, WdMenuItem } from '@/hooks/Mapper/components/ui-kit';
import clsx from 'clsx';

export interface ContextMenuRootProps {
  contextMenuRef: RefObject<ContextMenu>;
  pasteSystemsAndConnections: PasteSystemsAndConnections | undefined;
  onAddSystem(): void;
  onPasteSystemsAnsConnections(): void;
  // CHEWY PATCH: map region/wormhole-chain collapse (WANDERER_MAP_GROUPS).
  groupsEnabled?: boolean;
  onCollapseAllRegions?(): void;
  onExpandAllGroups?(): void;
}

export const ContextMenuRoot: React.FC<ContextMenuRootProps> = ({
  contextMenuRef,
  onAddSystem,
  onPasteSystemsAnsConnections,
  pasteSystemsAndConnections,
  groupsEnabled,
  onCollapseAllRegions,
  onExpandAllGroups,
}) => {
  const options = useMapSelector(['options'], d => d.options);
  const userPermissions = useMapSelector(['userPermissions'], d => d.userPermissions);

  const items: MenuItem[] = useMemo(() => {
    const allowPaste = checkPermissions(userPermissions, options.allowed_paste_for);

    return [
      {
        label: 'Add System',
        icon: PrimeIcons.PLUS,
        command: onAddSystem,
      },
      ...(groupsEnabled
        ? [
            {
              label: 'Collapse all regions',
              icon: PrimeIcons.MAP,
              command: onCollapseAllRegions,
            },
            {
              label: 'Expand all',
              icon: PrimeIcons.MAP_MARKER,
              command: onExpandAllGroups,
            },
          ]
        : []),
      ...(pasteSystemsAndConnections != null
        ? [
            {
              icon: 'pi pi-clipboard',
              disabled: !allowPaste,
              command: onPasteSystemsAnsConnections,
              template: () => {
                if (allowPaste) {
                  return (
                    <WdMenuItem icon="pi pi-clipboard">
                      Paste
                    </WdMenuItem>
                  );
                }

                return (
                  <MenuItemWithInfo
                    infoTitle="Action is blocked because you don’t have permission to Paste."
                    infoClass={clsx(PrimeIcons.QUESTION_CIRCLE, 'text-stone-500 mr-[12px]')}
                    tooltipWrapperClassName="flex"
                  >
                    <WdMenuItem disabled icon="pi pi-clipboard">
                      Paste
                    </WdMenuItem>
                  </MenuItemWithInfo>
                );
              },
            },
          ]
        : []),
    ];
  }, [
    userPermissions,
    options,
    onAddSystem,
    pasteSystemsAndConnections,
    onPasteSystemsAnsConnections,
    groupsEnabled,
    onCollapseAllRegions,
    onExpandAllGroups,
  ]);

  return (
    <>
      <ContextMenu model={items} ref={contextMenuRef} breakpoint="767px" />
    </>
  );
};
