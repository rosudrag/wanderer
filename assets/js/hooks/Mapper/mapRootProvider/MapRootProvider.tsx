import { ContextStoreDataUpdate, ContextStoreListener, ContextStoreUnsubscribe, useContextSelector, useContextStore } from '@/hooks/Mapper/utils';
import { createContext, Dispatch, ForwardedRef, forwardRef, SetStateAction, useContext, useEffect, useReducer, useRef } from 'react';
import {
  ActivitySummary,
  CommandLinkSignatureToSystem,
  MapUnionTypes,
  OutCommandHandler,
  SolarSystemConnection,
  TrackingCharacter,
  UseCharactersCacheData,
  UseCommentsData,
  UserPermission,
} from '@/hooks/Mapper/types';
import { useCharactersCache, useComments, useMapRootHandlers } from '@/hooks/Mapper/mapRootProvider/hooks';
import { WithChildren } from '@/hooks/Mapper/types/common.ts';
import {
  ToggleWidgetVisibility,
  useStoreWidgets,
  WindowStoreInfo,
} from '@/hooks/Mapper/mapRootProvider/hooks/useStoreWidgets.ts';
import { WindowsManagerOnChange } from '@/hooks/Mapper/components/ui-kit/WindowManager';
import { DetailedKill } from '../types/kills';
import {
  InterfaceStoredSettings,
  JumpPlannerSettings,
  KillsWidgetSettings,
  LocalWidgetSettings,
  MapSettings,
  MapUserSettings,
  OnTheMapSettingsType,
  RoutesByType,
  RoutesType,
  // CHEWY PATCH: map beautifier settings.
  BeautifySettings,
  // CHEWY PATCH: map region/wormhole-chain collapse settings.
  MapGroupsSettings,
} from '@/hooks/Mapper/mapRootProvider/types.ts';
import {
  DEFAULT_KILLS_WIDGET_SETTINGS,
  DEFAULT_JUMP_PLANNER_SETTINGS,
  DEFAULT_MAP_SETTINGS,
  DEFAULT_ON_THE_MAP_SETTINGS,
  DEFAULT_ROUTES_BY_SETTINGS,
  DEFAULT_ROUTES_SETTINGS,
  DEFAULT_WIDGET_LOCAL_SETTINGS,
  STORED_INTERFACE_DEFAULT_VALUES,
  // CHEWY PATCH: map beautifier settings.
  DEFAULT_BEAUTIFY_SETTINGS,
  // CHEWY PATCH: map region/wormhole-chain collapse settings.
  DEFAULT_MAP_GROUPS_SETTINGS,
} from '@/hooks/Mapper/mapRootProvider/constants.ts';
import { useMapUserSettings } from '@/hooks/Mapper/mapRootProvider/hooks/useMapUserSettings.ts';
import { useGlobalHooks } from '@/hooks/Mapper/mapRootProvider/hooks/useGlobalHooks.ts';
import { DEFAULT_SIGNATURE_SETTINGS, SignatureSettingsType } from '@/hooks/Mapper/constants/signatures';

export type MapRootData = MapUnionTypes & {
  selectedSystems: string[];
  selectedConnections: Pick<SolarSystemConnection, 'source' | 'target'>[];
  linkSignatureToSystem: CommandLinkSignatureToSystem | null;
  detailedKills: Record<string, DetailedKill[]>;
  showCharacterActivity: boolean;
  characterActivityData: {
    activity: ActivitySummary[];
    loading?: boolean;
  };
  trackingCharactersData: TrackingCharacter[];
  loadingPublicRoutes: boolean;
  map_slug: string | null;
  expiredCharacters: string[];
  // Mirrors `storedSettings.interfaceSettings` (separate, localStorage-backed React state, not
  // part of this store) into the store so `useMapRootSelector` can select a single field out of
  // it (e.g. `isShowUnsplashedSignatures`) without the caller also subscribing to every OTHER
  // field on `MapRootContextProps` the way a plain `useMapRootState()` read would. Kept in sync
  // by a `useEffect` in `MapRootProvider` below - one extra frame behind the real value on a
  // settings change, which is a user-initiated, rare event, not the frequent server-pushed
  // writes (characters/kills/signatures) this store exists to isolate.
  interfaceSettings: InterfaceStoredSettings;
  // Mirrors `storedSettings.settingsGroups` (same reasoning as `interfaceSettings` above) so
  // `useMapGroups.ts` (the map region/wormhole-chain collapse choke point, called once in
  // `Map.tsx`'s `MapComp`) can select these without re-subscribing the whole canvas to every
  // other `MapRootContextProps` field.
  collapsedGroupKeys: string[];
  groupPositions: Record<string, { x: number; y: number }>;
};

const INITIAL_DATA: MapRootData = {
  wormholesData: {},
  wormholes: [],
  effects: {},
  characters: [],
  showCharacterActivity: false,
  characterActivityData: {
    activity: [],
    loading: false,
  },
  trackingCharactersData: [],
  userCharacters: [],
  presentCharacters: [],
  systems: [],
  systemSignatures: {},
  hubs: [],
  userHubs: [],
  routes: undefined,
  userRoutes: undefined,
  routesListBy: undefined,
  availableRoutesBy: [],
  kills: [],
  connections: [],
  detailedKills: {},
  selectedSystems: [],
  selectedConnections: [],
  userPermissions: {},
  options: {
    allowed_copy_for: UserPermission.VIEW_SYSTEM,
    allowed_paste_for: UserPermission.VIEW_SYSTEM,
    layout: '',
    restrict_offline_showing: 'false',
    show_linked_signature_id: 'false',
    show_linked_signature_id_temp_name: 'false',
    show_temp_system_name: 'false',
    store_custom_labels: 'false',
  },
  isSubscriptionActive: false,
  linkSignatureToSystem: null,
  mainCharacterEveId: null,
  followingCharacterEveId: null,
  pings: [],
  loadingPublicRoutes: false,
  map_slug: null,
  expiredCharacters: [],
  interfaceSettings: STORED_INTERFACE_DEFAULT_VALUES,
  collapsedGroupKeys: [],
  groupPositions: {},
};

export enum InterfaceStoredSettingsProps {
  isShowMenu = 'isShowMenu',
  isShowKSpace = 'isShowKSpace',
  isThickConnections = 'isThickConnections',
  isShowUnsplashedSignatures = 'isShowUnsplashedSignatures',
  isShowBackgroundPattern = 'isShowBackgroundPattern',
  isSoftBackground = 'isSoftBackground',
  theme = 'theme',
}

export interface MapRootContextProps {
  update: ContextStoreDataUpdate<MapRootData>;
  data: MapRootData;
  outCommand: OutCommandHandler;
  windowsSettings: WindowStoreInfo;
  toggleWidgetVisibility: ToggleWidgetVisibility;
  updateWidgetSettings: WindowsManagerOnChange;
  resetWidgets: () => void;
  comments: UseCommentsData;
  charactersCache: UseCharactersCacheData;

  /**
   * !!!
   * DO NOT PASS THIS PROP INTO COMPONENT
   * !!!
   * */
  storedSettings: {
    interfaceSettings: InterfaceStoredSettings;
    setInterfaceSettings: Dispatch<SetStateAction<InterfaceStoredSettings>>;
    settingsRoutes: RoutesType;
    settingsRoutesUpdate: Dispatch<SetStateAction<RoutesType>>;
    settingsRoutesBy: RoutesByType;
    settingsRoutesByUpdate: Dispatch<SetStateAction<RoutesByType>>;
    settingsLocal: LocalWidgetSettings;
    settingsLocalUpdate: Dispatch<SetStateAction<LocalWidgetSettings>>;
    settingsSignatures: SignatureSettingsType;
    settingsSignaturesUpdate: Dispatch<SetStateAction<SignatureSettingsType>>;
    settingsOnTheMap: OnTheMapSettingsType;
    settingsOnTheMapUpdate: Dispatch<SetStateAction<OnTheMapSettingsType>>;
    settingsKills: KillsWidgetSettings;
    settingsKillsUpdate: Dispatch<SetStateAction<KillsWidgetSettings>>;
    mapSettings: MapSettings;
    mapSettingsUpdate: Dispatch<SetStateAction<MapSettings>>;
    settingsJumpPlanner: JumpPlannerSettings;
    settingsJumpPlannerUpdate: Dispatch<SetStateAction<JumpPlannerSettings>>;
    // CHEWY PATCH: map beautifier settings.
    settingsBeautify: BeautifySettings;
    settingsBeautifyUpdate: Dispatch<SetStateAction<BeautifySettings>>;
    // CHEWY PATCH: map region/wormhole-chain collapse settings.
    settingsGroups: MapGroupsSettings;
    settingsGroupsUpdate: Dispatch<SetStateAction<MapGroupsSettings>>;
    isReady: boolean;
    hasOldSettings: boolean;
    getSettingsForExport(): string | undefined;
    applySettings(settings: MapUserSettings): boolean;
    resetSettings(): void;
    checkOldSettings(): void;
  };
}

// Every key `MapRootData` has, computed once at module scope: used to restore "re-render on any
// store write" for every PLAIN `useMapRootState()` consumer (89 files at the time of writing -
// see docs/chewy/map-perf-findings.md) that has not been converted to `useMapRootSelector`.
// `useContextStore` no longer forces its OWNER (`MapRootProvider`) to re-render internally on
// `update()` (that mechanism was removed so per-key-selector consumers aren't woken on
// irrelevant writes - see `useContextStore.ts`), so without this, `MapRootProvider` would simply
// stop re-rendering on character/kill/signature/etc. updates, and every one of its 89 unconverted
// consumers would silently go stale. Subscribing to every key here exactly reconstructs the OLD
// behavior (the whole Provider re-rendered on any `update()` call, through its own React state),
// just driven explicitly through `subscribe` instead of implicitly through `useContextStore`.
const ALL_MAP_ROOT_DATA_KEYS = Object.keys(INITIAL_DATA) as (keyof MapRootData)[];

const MapRootContext = createContext<MapRootContextProps>({
  update: () => {},
  data: { ...INITIAL_DATA },
  // @ts-ignore
  outCommand: async () => void 0,
  comments: {
    loadComments: async () => {},
    comments: new Map(),
    lastUpdateKey: 0,
    addComment: function (): void {
      throw new Error('Function not implemented.');
    },
    removeComment: function (): void {
      throw new Error('Function not implemented.');
    },
  },
  charactersCache: {
    loadCharacter: function (): Promise<void> {
      throw new Error('Function not implemented.');
    },
    characters: new Map(),
    lastUpdateKey: 0,
  },
  storedSettings: {
    interfaceSettings: STORED_INTERFACE_DEFAULT_VALUES,
    setInterfaceSettings: () => null,
    settingsRoutes: DEFAULT_ROUTES_SETTINGS,
    settingsRoutesUpdate: () => null,
    settingsRoutesBy: { ...DEFAULT_ROUTES_BY_SETTINGS, routes: { ...DEFAULT_ROUTES_BY_SETTINGS.routes } },
    settingsRoutesByUpdate: () => null,
    settingsLocal: DEFAULT_WIDGET_LOCAL_SETTINGS,
    settingsLocalUpdate: () => null,
    settingsSignatures: DEFAULT_SIGNATURE_SETTINGS,
    settingsSignaturesUpdate: () => null,
    settingsOnTheMap: DEFAULT_ON_THE_MAP_SETTINGS,
    settingsOnTheMapUpdate: () => null,
    settingsKills: DEFAULT_KILLS_WIDGET_SETTINGS,
    settingsKillsUpdate: () => null,
    mapSettings: DEFAULT_MAP_SETTINGS,
    mapSettingsUpdate: () => null,
    settingsJumpPlanner: DEFAULT_JUMP_PLANNER_SETTINGS,
    settingsJumpPlannerUpdate: () => null,
    // CHEWY PATCH: map beautifier settings.
    settingsBeautify: DEFAULT_BEAUTIFY_SETTINGS,
    settingsBeautifyUpdate: () => null,
    // CHEWY PATCH: map region/wormhole-chain collapse settings.
    settingsGroups: DEFAULT_MAP_GROUPS_SETTINGS,
    settingsGroupsUpdate: () => null,
    isReady: false,
    hasOldSettings: false,
    getSettingsForExport: () => '',
    applySettings: () => false,
    resetSettings: () => null,
    checkOldSettings: () => null,
  },
});

// Narrow, STABLE context used only by `useMapRootSelector`: identity never changes for the
// Provider's lifetime (frozen via `useRef`, same pattern as `MapProvider.tsx`'s
// `contextValueRef`). This is deliberately a SEPARATE context from `MapRootContext` (whose value
// is, and must stay, a fresh object on every `MapRootProvider` render so the 89 unconverted
// `useMapRootState()` consumers keep reacting to `storedSettings`/`windowsSettings`/`comments`/
// `charactersCache` changes exactly as before) - a selector-based consumer that instead called
// `useContext(MapRootContext)` would still be woken by React's native context propagation on
// EVERY one of those renders regardless of its own selector, defeating the point of selecting.
interface MapRootStoreContextProps {
  data: MapRootData;
  update: ContextStoreDataUpdate<MapRootData>;
  subscribe: (keys: (keyof MapRootData)[], listener: ContextStoreListener) => ContextStoreUnsubscribe;
}

const noopSubscribe = () => () => {};

const MapRootStoreContext = createContext<MapRootStoreContextProps>({
  data: { ...INITIAL_DATA },
  update: () => {},
  subscribe: noopSubscribe,
});

type MapRootProviderProps = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  fwdRef: ForwardedRef<any>;
  outCommand: OutCommandHandler;
} & WithChildren;

// eslint-disable-next-line react/display-name
const MapRootHandlers = forwardRef(({ children }: WithChildren, fwdRef: ForwardedRef<any>) => {
  useMapRootHandlers(fwdRef);
  useGlobalHooks();
  return <>{children}</>;
});

// eslint-disable-next-line react/display-name
export const MapRootProvider = ({ children, fwdRef, outCommand }: MapRootProviderProps) => {
  const { update, ref, subscribe } = useContextStore<MapRootData>({ ...INITIAL_DATA });

  // Restores "the Provider re-renders on any store write" for the 89 unconverted
  // `useMapRootState()` consumers - see `ALL_MAP_ROOT_DATA_KEYS`'s comment above.
  const [, forceRerender] = useReducer((x: number) => x + 1, 0);
  useEffect(() => subscribe(ALL_MAP_ROOT_DATA_KEYS, () => forceRerender()), [subscribe]);

  const storedSettings = useMapUserSettings(ref, outCommand);

  // Mirrors `storedSettings.interfaceSettings` (independent, localStorage-backed React state)
  // into the store so `useMapRootSelector` callers (e.g. `useSolarSystemNode.ts`,
  // `SolarSystemEdge.tsx`) can select a single field out of it without pulling in a plain
  // `useMapRootState()` read, which would re-subscribe them to every OTHER field on
  // `MapRootContextProps` via `MapRootContext`'s (deliberately still-reactive) native propagation.
  useEffect(() => {
    update({ interfaceSettings: storedSettings.interfaceSettings });
  }, [storedSettings.interfaceSettings, update]);

  // Same mirroring reasoning, for the map region/wormhole-chain collapse settings.
  useEffect(() => {
    update({
      collapsedGroupKeys: storedSettings.settingsGroups.collapsedGroups,
      groupPositions: storedSettings.settingsGroups.groupPositions,
    });
  }, [storedSettings.settingsGroups, update]);

  const { windowsSettings, toggleWidgetVisibility, updateWidgetSettings, resetWidgets } =
    useStoreWidgets(storedSettings);

  const comments = useComments({ outCommand });
  const charactersCache = useCharactersCache({ outCommand });

  const storeContextRef = useRef<MapRootStoreContextProps>({ data: ref, update, subscribe });

  return (
    <MapRootStoreContext.Provider value={storeContextRef.current}>
      <MapRootContext.Provider
        value={{
          update,
          data: ref,
          outCommand,
          windowsSettings,
          updateWidgetSettings,
          toggleWidgetVisibility,
          resetWidgets,
          comments,
          charactersCache,
          storedSettings,
        }}
      >
        <MapRootHandlers ref={fwdRef}>{children}</MapRootHandlers>
      </MapRootContext.Provider>
    </MapRootStoreContext.Provider>
  );
};

export const useMapRootState = () => {
  const context = useContext<MapRootContextProps>(MapRootContext);
  return context;
};

/**
 * Subscribes a component to exactly the slice of `MapRootData` it needs - the per-node/per-edge
 * equivalent of `useMapSelector` (`MapProvider.tsx`), for the hottest `useMapRootState()`
 * consumers (one instance per node/edge on the map): only re-renders when `selector(data)`'s
 * result actually changes AND only on an `update()` call that wrote one of the declared `keys`.
 * Reads from the SEPARATE, stable `MapRootStoreContext`, not `MapRootContext` - see that
 * context's comment for why a plain `useMapRootState()` read can't be made selective this way.
 */
export function useMapRootSelector<T>(
  keys: (keyof MapRootData)[],
  selector: (data: MapRootData) => T,
  isEqual: (a: T, b: T) => boolean = Object.is,
): T {
  const context = useContext<MapRootStoreContextProps>(MapRootStoreContext);
  return useContextSelector(context.data, context.subscribe, keys, selector, isEqual, 'useMapRootSelector');
}
