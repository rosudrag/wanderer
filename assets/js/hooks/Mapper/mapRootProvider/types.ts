import { WindowStoreInfo } from '@/hooks/Mapper/mapRootProvider/hooks/useStoreWidgets.ts';
// CHEWY PATCH: map beautifier per-map preferences (rootId/axis/kspaceMode).
import type { BeautifyAxis, KSpaceMode } from '@/hooks/Mapper/components/map/layout';
import { SignatureSettingsType } from '@/hooks/Mapper/constants/signatures.ts';

export enum AvailableThemes {
  default = 'default',
  pathfinder = 'pathfinder',
  accessibleDark = 'accessible-dark',
  accessibleLarge = 'accessible-large',
  accessibleLargeColorblind = 'accessible-large-colorblind',
  // CHEWY PATCH: Dotlan-style theme.
  dotlan = 'dotlan',
}

export enum MiniMapPlacement {
  rightTop = 'rightTop',
  rightBottom = 'rightBottom',
  leftTop = 'leftTop',
  leftBottom = 'leftBottom',
  hide = 'hide',
}

export enum PingsPlacement {
  rightTop = 'rightTop',
  rightBottom = 'rightBottom',
  leftTop = 'leftTop',
  leftBottom = 'leftBottom',
}

export enum DotlanBehavior {
  system = 'system',
  security = 'sec',
  sovereignty = 'sov',
  constellation = 'const',
  jumps = 'jumps',
  kills = 'kills',
  npcKills = 'npc',
  npcKillsDelta = 'npc_delta',
}

export type InterfaceStoredSettings = {
  isShowMenu: boolean;
  isShowKSpace: boolean;
  isThickConnections: boolean;
  isShowUnsplashedSignatures: boolean;
  isShowBackgroundPattern: boolean;
  isSoftBackground: boolean;
  theme: AvailableThemes;
  minimapPlacement: MiniMapPlacement;
  pingsPlacement: PingsPlacement;
  hideBookmarkWarning: boolean;
  dotlanBehavior: DotlanBehavior;
  // CHEWY PATCH: Dotlan-style straight connections toggle.
  dotlanStyleConnections: boolean;
};

export type RoutesType = {
  path_type: 'shortest' | 'secure' | 'insecure';
  include_mass_crit: boolean;
  include_eol: boolean;
  include_frig: boolean;
  include_cruise: boolean;
  include_thera: boolean;
  avoid_wormholes: boolean;
  avoid_pochven: boolean;
  avoid_edencom: boolean;
  avoid_triglavian: boolean;
  avoid: number[];
};

export type RoutesByCategoryType = 'blueLoot' | 'redLoot' | 'thera' | 'turnur' | 'so_cleaning' | 'trade_hubs';

export type RoutesByScopeType = 'ALL' | 'HIGH';

export type RoutesByType = {
  routes: RoutesType;
  scope: RoutesByScopeType;
  type: RoutesByCategoryType;
};

export type LocalWidgetSettings = {
  compact: boolean;
  showOffline: boolean;
  showShipName: boolean;
};

export type OnTheMapSettingsType = {
  hideOffline: boolean;
};

export type KillsWidgetSettings = {
  showAll: boolean;
  whOnly: boolean;
  excludedSystems: number[];
  timeRange: number;
};

export type MapViewPort = { zoom: number; x: number; y: number };

export type MapSettings = {
  viewport: MapViewPort;
};

export type JumpSkillLevel = 0 | 1 | 2 | 3 | 4 | 5;

export type JumpPlannerSettings = {
  shipType: string;
  jumpDriveCalibration: JumpSkillLevel;
  jumpFuelConservation: JumpSkillLevel;
  jumpFreighter: JumpSkillLevel;
  preferStationSystems: boolean;
  avoidIncursions: boolean;
};

// CHEWY PATCH: map beautifier per-map preferences.
export type BeautifySettings = {
  rootId: string | null;
  axis: BeautifyAxis;
  kspaceMode: KSpaceMode;
};

export type SettingsWrapper<T> = T;

export type MapUserSettings = {
  migratedFromOld: boolean;
  version: number;
  widgets: SettingsWrapper<WindowStoreInfo>;
  interface: SettingsWrapper<InterfaceStoredSettings>;
  onTheMap: SettingsWrapper<OnTheMapSettingsType>;
  routes: SettingsWrapper<RoutesType>;
  routesBy: SettingsWrapper<RoutesByType>;
  localWidget: SettingsWrapper<LocalWidgetSettings>;
  signaturesWidget: SettingsWrapper<SignatureSettingsType>;
  killsWidget: SettingsWrapper<KillsWidgetSettings>;
  map: SettingsWrapper<MapSettings>;
  jumpPlanner: SettingsWrapper<JumpPlannerSettings>;
  // CHEWY PATCH: map beautifier settings.
  beautify: SettingsWrapper<BeautifySettings>;
};

export type MapUserSettingsStructure = {
  [mapId: string]: MapUserSettings;
};

export type WdResponse<T> = T;

export type RemoteAdminSettingsResponse = { default_settings?: string };

export enum SettingsTypes {
  killsWidget = 'killsWidget',
  localWidget = 'localWidget',
  widgets = 'widgets',
  routes = 'routes',
  routesBy = 'routesBy',
  onTheMap = 'onTheMap',
  signaturesWidget = 'signaturesWidget',
  interface = 'interface',
  map = 'map',
  jumpPlanner = 'jumpPlanner',
  // CHEWY PATCH: map beautifier settings.
  beautify = 'beautify',
}

export type MigrationFunc = (prev: any) => any;
export type MigrationStructure = {
  to: number;
  up: MigrationFunc;
};
