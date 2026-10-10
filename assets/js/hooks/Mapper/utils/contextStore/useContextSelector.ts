import { useRef, useSyncExternalStore } from 'react';
import { ContextStoreListener, ContextStoreUnsubscribe } from './types';

// DEV-ONLY safety net: a declared-keys selector hook (`useMapSelector`/`useMapRootSelector`)
// declares which keys it reads; this runs the selector against a `Proxy` that records ACTUAL
// property access and throws if it touched a key that was not declared. Catches the unsound case
// a one-time discovery probe cannot: a CONDITIONAL read (`||`, `&&`, `?.`, a ternary, an early
// return) that doesn't fire on every render - e.g. `isConnecting || hoverNodeId === id` never
// touches `hoverNodeId` on a render where `isConnecting` happens to be `true` first. A selector
// that under-declares its keys silently stops reacting to a key it sometimes needs - this makes
// that fail loudly in development instead of shipping a stale-UI bug. Runs every render (not just
// once) because the conditional branch that reveals the missing key may not be taken on the first
// render either.
export function assertDeclaredKeysCoverActualReads<T extends object>(
  data: T,
  declaredKeys: (keyof T)[],
  selector: (data: T) => unknown,
  hookName: string,
): void {
  const declared = new Set(declaredKeys);
  const proxy = new Proxy(data, {
    get(target, prop, receiver) {
      const key = prop as keyof T;
      if (!declared.has(key)) {
        throw new Error(
          `${hookName}: selector read "${String(key)}" but it was not in the declared keys ` +
            `[${declaredKeys.map(String).join(', ')}]. A conditionally-read key (||, &&, ?., a ` +
            `ternary, an early return) will under-subscribe and go stale on a render where the ` +
            `condition takes the other branch - add "${String(key)}" to the declared keys array.`,
        );
      }
      return Reflect.get(target, prop, receiver);
    },
  });
  selector(proxy);
}

/**
 * Generic, context-agnostic implementation shared by `useMapSelector` (`MapProvider.tsx`) and
 * `useMapRootSelector` (`MapRootProvider.tsx`): subscribes to exactly the declared `keys` of `T`
 * and only re-renders the caller when `selector(data)`'s result actually changes (`isEqual`,
 * default `Object.is`) AND only on an `update()` call that wrote one of the declared `keys` - not
 * on every write to the underlying store. Built on `useSyncExternalStore` (React 18) so
 * concurrent-rendering tearing is handled the same way any other external store would be.
 *
 * `data` and `subscribe` MUST come from a context value whose OWN identity never changes for the
 * lifetime of its Provider (see `MapProvider.tsx`'s `contextValueRef` / `MapRootProvider.tsx`'s
 * `MapRootStoreContext`) - otherwise the calling component is still woken on every Provider
 * re-render via React's native context propagation, regardless of this hook's own selectivity.
 */
export function useContextSelector<T extends object, S>(
  data: T,
  subscribe: (keys: (keyof T)[], listener: ContextStoreListener) => ContextStoreUnsubscribe,
  keys: (keyof T)[],
  selector: (data: T) => S,
  isEqual: (a: S, b: S) => boolean = Object.is,
  hookName = 'useContextSelector',
): S {
  const selectorRef = useRef(selector);
  selectorRef.current = selector;
  const isEqualRef = useRef(isEqual);
  isEqualRef.current = isEqual;
  const keysRef = useRef(keys);
  keysRef.current = keys;
  const dataRef = useRef(data);
  dataRef.current = data;

  if (process.env.NODE_ENV !== 'production') {
    assertDeclaredKeysCoverActualReads(data, keys, selector, hookName);
  }

  const cacheRef = useRef<{ value: S; has: boolean }>({ value: undefined as S, has: false });

  const getSnapshotRef = useRef(() => {
    const next = selectorRef.current(dataRef.current);
    if (!cacheRef.current.has || !isEqualRef.current(cacheRef.current.value, next)) {
      cacheRef.current = { value: next, has: true };
    }
    return cacheRef.current.value;
  });

  const subscribeRef = useRef((listener: ContextStoreListener) => subscribe(keysRef.current, listener));

  return useSyncExternalStore(subscribeRef.current, getSnapshotRef.current, getSnapshotRef.current);
}
