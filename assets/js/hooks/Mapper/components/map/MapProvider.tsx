import React, { createContext, useContext, useRef } from 'react';
import { OutCommandHandler } from '@/hooks/Mapper/types/mapHandlers.ts';
import { CharacterTypeRaw, MapUnionTypes, SystemSignature } from '@/hooks/Mapper/types';
import {
  ContextStoreDataUpdate,
  ContextStoreListener,
  ContextStoreUnsubscribe,
  useContextSelector,
  useContextStore,
} from '@/hooks/Mapper/utils';

export type MapData = MapUnionTypes & {
  isConnecting: boolean;
  hoverNodeId: string | null;
  visibleNodes: Set<string>;
  showKSpaceBG: boolean;
  isThickConnections: boolean;
  linkedSigEveId: string;
  localShowShipName: boolean;
  systemHighlighted: string | undefined;
  // Derived from `characters` at every write site (see `helpers/indexCharactersBySystem.ts`):
  // O(1) per-system lookup instead of an O(characters) `.filter()` inside every node's own render.
  charactersBySystem: Map<number, CharacterTypeRaw[]>;
};

interface MapProviderProps {
  children: React.ReactNode;
  onCommand: OutCommandHandler;
}

const INITIAL_DATA: MapData = {
  wormholesData: {},
  wormholes: [],
  effects: {},
  characters: [],
  userCharacters: [],
  presentCharacters: [],
  systems: [],
  hubs: [],
  kills: {},
  isConnecting: false,
  connections: [],
  hoverNodeId: null,
  linkedSigEveId: '',
  visibleNodes: new Set(),
  showKSpaceBG: false,
  isThickConnections: false,
  userPermissions: {},
  systemSignatures: {} as Record<string, SystemSignature[]>,
  options: {} as Record<string, string | boolean>,
  isSubscriptionActive: false,
  mainCharacterEveId: null,
  followingCharacterEveId: null,
  userHubs: [],
  pings: [],
  localShowShipName: false,
  systemHighlighted: undefined,
  charactersBySystem: new Map(),
};

export interface MapContextProps {
  update: ContextStoreDataUpdate<MapData>;
  data: MapData;
  outCommand: OutCommandHandler;
  subscribe: (keys: (keyof MapData)[], listener: ContextStoreListener) => ContextStoreUnsubscribe;
}

const noopSubscribe = () => () => {};

const MapContext = createContext<MapContextProps>({
  update: () => {},
  data: { ...INITIAL_DATA },
  // @ts-ignore
  outCommand: async () => void 0,
  subscribe: noopSubscribe,
});

export const MapProvider = ({ children, onCommand }: MapProviderProps) => {
  const { update, ref, subscribe } = useContextStore<MapData>({ ...INITIAL_DATA });

  // The context VALUE never changes identity for the Provider's lifetime: `data` is the same
  // mutable object `useContextStore` mutates in place (never replaced), `update`/`subscribe` are
  // stable `useCallback`s, so there is nothing left that would ever need a new object here except
  // `outCommand`, which is kept current via a plain mutation instead of a new context value - a
  // changing `outCommand` identity is not a reason for every `useMapState()`/`useMapSelector()`
  // consumer on the map to re-render. This is what stops ANY `update()` call (e.g. a hover on one
  // node) from re-rendering every OTHER consumer of this context; readers that need to react to a
  // specific `data` field use `useMapSelector`, which subscribes itself via `subscribe`.
  const contextValueRef = useRef<MapContextProps>({
    update,
    data: ref,
    outCommand: onCommand,
    subscribe,
  });
  contextValueRef.current.outCommand = onCommand;

  return <MapContext.Provider value={contextValueRef.current}>{children}</MapContext.Provider>;
};

export const useMapState = () => {
  const context = useContext<MapContextProps>(MapContext);
  return context;
};

/**
 * Subscribes a component to exactly the slice of `MapData` it needs: the component only
 * re-renders when `selector(data)`'s result actually changes (`isEqual`, default `Object.is`) AND
 * only on an `update()` call that actually wrote one of the DECLARED `keys` - not on every
 * `update()` call anywhere on the map. `keys` must list every `MapData` field the selector reads,
 * INCLUDING ones read only on some branch of a conditional (see `useContextSelector`'s
 * `assertDeclaredKeysCoverActualReads`, which enforces this in development).
 *
 * Prefer selecting a SCALAR (boolean/string/number) over an object/array where possible - e.g.
 * `d => d.visibleNodes.has(id)` instead of `d => d.visibleNodes` - so unrelated writes to the same
 * field (a different node's visibility flipping) don't change the selected value's identity.
 */
export function useMapSelector<T>(
  keys: (keyof MapData)[],
  selector: (data: MapData) => T,
  isEqual: (a: T, b: T) => boolean = Object.is,
): T {
  const context = useContext<MapContextProps>(MapContext);
  return useContextSelector(context.data, context.subscribe, keys, selector, isEqual, 'useMapSelector');
}
