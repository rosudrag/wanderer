import { Menu } from 'primereact/menu';
import { useCallback, useMemo, useRef } from 'react';
import { useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { WdTooltipWrapper } from '@/hooks/Mapper/components/ui-kit/WdTooltipWrapper';
import { TooltipPosition } from '@/hooks/Mapper/components/ui-kit';
import { OutCommand } from '@/hooks/Mapper/types';
import { MenuItem } from 'primereact/menuitem';
import { useMapCheckPermissions } from '@/hooks/Mapper/mapRootProvider/hooks/api';
import { UserPermission } from '@/hooks/Mapper/types/permissions.ts';
// CHEWY PATCH: map beautifier submenu.
import { useBeautify } from '@/hooks/Mapper/components/map/hooks/useBeautify.ts';

export interface MapContextMenuProps {
  onShowOnTheMap?: () => void;
  onShowMapSettings?: () => void;
  onShowTrackingDialog?: () => void;
  onShowWormholesReference?: () => void;
  onShowJumpPlanner?: () => void;
}

export const MapContextMenu = ({
  onShowOnTheMap,
  onShowMapSettings,
  onShowTrackingDialog,
  onShowWormholesReference,
  onShowJumpPlanner,
}: MapContextMenuProps) => {
  const {
    outCommand,
    data: { selectedSystems },
    storedSettings: { setInterfaceSettings, settingsBeautify, settingsBeautifyUpdate },
  } = useMapRootState();

  const { beautify, isEnabled: isBeautifyEnabled, isBeautifying } = useBeautify();

  const canTrackCharacters = useMapCheckPermissions([UserPermission.TRACK_CHARACTER]);

  const menuRight = useRef<Menu>(null);

  const handleShowActivity = useCallback(() => {
    outCommand({
      type: OutCommand.showActivity,
      data: {},
    });
  }, [outCommand]);

  // CHEWY PATCH: map beautifier handlers.
  const handleBeautifyWholeMap = useCallback(() => {
    beautify({
      scope: 'all',
      rootId: settingsBeautify.rootId,
      axis: settingsBeautify.axis,
      kspaceMode: settingsBeautify.kspaceMode,
    });
  }, [beautify, settingsBeautify]);

  const handleBeautifySelection = useCallback(() => {
    beautify({
      scope: 'selection',
      rootId: settingsBeautify.rootId,
      axis: settingsBeautify.axis,
      kspaceMode: settingsBeautify.kspaceMode,
    });
  }, [beautify, settingsBeautify]);

  // CHEWY PATCH: explicit "re-solve everything" command — mode: 'full' overrides the
  // default 'auto' behaviour that otherwise leaves already-placed systems untouched.
  const handleBeautifyRebuild = useCallback(() => {
    beautify({
      scope: 'all',
      rootId: settingsBeautify.rootId,
      axis: settingsBeautify.axis,
      kspaceMode: settingsBeautify.kspaceMode,
      mode: 'full',
    });
  }, [beautify, settingsBeautify]);

  const handleToggleBeautifyAxis = useCallback(() => {
    settingsBeautifyUpdate(prev => ({
      ...prev,
      axis: prev.axis === 'top_to_bottom' ? 'left_to_right' : 'top_to_bottom',
    }));
  }, [settingsBeautifyUpdate]);

  const items = useMemo(() => {
    return (
      [
        {
          label: 'Tracking',
          icon: 'pi pi-user-plus',
          command: onShowTrackingDialog,
          visible: canTrackCharacters,
        },
        {
          label: 'Character Activity',
          icon: 'pi pi-chart-bar',
          command: handleShowActivity,
          visible: canTrackCharacters,
        },
        {
          label: 'On the map',
          icon: 'pi pi-hashtag',
          command: onShowOnTheMap,
          visible: canTrackCharacters,
        },
        {
          label: 'Wormholes Ref.',
          icon: 'pi pi-book',
          command: onShowWormholesReference,
          visible: canTrackCharacters,
        },
        {
          label: 'Jump Planner',
          icon: 'hero-jump-range-diagonal',
          command: onShowJumpPlanner,
          visible: true,
        },
        { separator: true, visible: true },
        ...(isBeautifyEnabled
          ? [
              {
                label: 'Beautify',
                icon: 'pi pi-sparkles',
                visible: true,
                items: [
                  {
                    label: 'Tidy whole map',
                    icon: 'pi pi-sitemap',
                    command: handleBeautifyWholeMap,
                    disabled: isBeautifying,
                  },
                  {
                    label: 'Tidy selection',
                    icon: 'pi pi-check-square',
                    command: handleBeautifySelection,
                    disabled: isBeautifying || selectedSystems.length === 0,
                  },
                  { separator: true },
                  {
                    label: 'Rebuild layout',
                    icon: 'pi pi-refresh',
                    command: handleBeautifyRebuild,
                    disabled: isBeautifying,
                  },
                  { separator: true },
                  {
                    label: settingsBeautify.axis === 'top_to_bottom' ? 'Axis: Top to bottom' : 'Axis: Left to right',
                    icon: settingsBeautify.axis === 'top_to_bottom' ? 'pi pi-arrow-down' : 'pi pi-arrow-right',
                    command: handleToggleBeautifyAxis,
                  },
                ],
              },
              { separator: true, visible: true },
            ]
          : []),
        {
          label: 'Settings',
          icon: `pi pi-cog`,
          command: onShowMapSettings,
          visible: true,
        },
        {
          label: 'Dock menu',
          icon: 'pi pi-window-maximize',
          command: () =>
            setInterfaceSettings(x => ({
              ...x,
              isShowMenu: !x.isShowMenu,
            })),
          visible: true,
        },
      ] as MenuItem[]
    ).filter(item => item.visible);
  }, [
    canTrackCharacters,
    onShowTrackingDialog,
    handleShowActivity,
    onShowMapSettings,
    onShowOnTheMap,
    onShowWormholesReference,
    onShowJumpPlanner,
    setInterfaceSettings,
    isBeautifyEnabled,
    isBeautifying,
    selectedSystems,
    settingsBeautify,
    handleBeautifyWholeMap,
    handleBeautifySelection,
    handleBeautifyRebuild,
    handleToggleBeautifyAxis,
  ]);

  return (
    <div className="ml-1">
      <WdTooltipWrapper content="Map Menu" position={TooltipPosition.left}>
        <button
          className="btn bg-transparent text-gray-400 hover:text-white border-transparent hover:bg-transparent px-2"
          type="button"
          onClick={event => menuRight.current?.toggle(event)}
        >
          <i className="pi pi-sliders-h text-lg"></i>
        </button>
      </WdTooltipWrapper>
      <Menu model={items} popup ref={menuRight} id="popup_menu_right" popupAlignment="right" />
    </div>
  );
};
