import { useCallback, useEffect, useRef } from 'react';

import {
  ContextStoreDataOpts,
  ContextStoreDataUpdate,
  ContextStoreListener,
  ProvideConstateDataReturnType,
  UpdateFunc,
} from './types';

export const useContextStore = <T>(
  initialValue: T,
  { notNeedRerender = false, handleBeforeUpdate, onAfterAUpdate }: ContextStoreDataOpts<T> = {},
): ProvideConstateDataReturnType<T> => {
  const ref = useRef<T>(initialValue);
  const queueRef = useRef<{ valOrFunc: Partial<T> | UpdateFunc<T>; force: boolean }[]>([]);
  // One listener set PER KEY, not one global set: notifying only the listeners registered for
  // the keys a given `update()` call actually wrote is what lets `useMapSelector` wake only the
  // components that read THAT key, instead of every subscriber on the map re-running its render
  // function on every `update()` call anywhere (confirmed by measurement: a single shared
  // `Set<Listener>` still woke all N nodes' render functions on one hover, even though each
  // node's OWN selector correctly bailed out of returning new DOM - the wasted work was the
  // function CALL itself, not just the DOM diff).
  const listenersByKeyRef = useRef<Map<keyof T, Set<ContextStoreListener>>>(new Map());

  const refWrapper = useRef({ notNeedRerender, handleBeforeUpdate, onAfterAUpdate });
  refWrapper.current = { notNeedRerender, handleBeforeUpdate, onAfterAUpdate };

  const update: ContextStoreDataUpdate<T> = useCallback((valOrFunc, force = false) => {
    queueRef.current.push({ valOrFunc, force });
  }, []);

  const subscribe = useCallback((keys: (keyof T)[], listener: ContextStoreListener) => {
    keys.forEach(key => {
      let set = listenersByKeyRef.current.get(key);
      if (!set) {
        set = new Set();
        listenersByKeyRef.current.set(key, set);
      }
      set.add(listener);
    });
    return () => {
      keys.forEach(key => listenersByKeyRef.current.get(key)?.delete(listener));
    };
  }, []);

  // Drains the WHOLE pending queue in one pass instead of one entry per animation frame: every
  // queued patch (in order, same semantics as before - function-form patches still see every
  // earlier patch in the same drain already applied to `ref.current`) is applied, then each
  // affected key's listeners are notified at most ONCE for the frame. Previously
  // `processNextQueue` `.shift()`'d a single entry per rAF tick, so N updates queued in the same
  // frame (e.g. a burst of map events) landed as N separate commits, one frame apart each - extra
  // renders, extra frames of stale UI while the map was already busy.
  const processQueue = useCallback(() => {
    if (queueRef.current.length === 0) {
      return;
    }

    const pending = queueRef.current;
    queueRef.current = [];

    const { notNeedRerender, handleBeforeUpdate, onAfterAUpdate } = refWrapper.current;
    // eslint-disable-next-line @typescript-eslint/ban-ts-comment
    // @ts-expect-error
    const availableKeys = Object.keys(ref.current);

    const changedKeys = new Set<keyof T>();

    pending.forEach(({ valOrFunc, force }) => {
      const values = typeof valOrFunc === 'function' ? valOrFunc(ref.current) : valOrFunc;

      Object.keys(values).forEach(rawKey => {
        const key = rawKey as keyof T;

        if (!availableKeys.includes(rawKey)) {
          // TODO maybe need show error
          return;
        }

        if (!handleBeforeUpdate || force) {
          // eslint-disable-next-line @typescript-eslint/ban-ts-comment
          // @ts-expect-error
          ref.current[key] = values[key];
          if (!notNeedRerender) {
            changedKeys.add(key);
          }
          return;
        }

        // eslint-disable-next-line @typescript-eslint/ban-ts-comment
        // @ts-expect-error
        const updateResult = handleBeforeUpdate(values[key], ref.current[key]);
        if (!updateResult) {
          // eslint-disable-next-line @typescript-eslint/ban-ts-comment
          // @ts-expect-error
          ref.current[key] = values[key];
          if (!notNeedRerender) {
            changedKeys.add(key);
          }
          return;
        }

        if (updateResult?.prevent) {
          return;
        }

        if (Object.keys(updateResult).includes('value')) {
          ref.current[key] = updateResult.value;
          if (!notNeedRerender) {
            changedKeys.add(key);
          }
          return;
        }
      });
    });

    if (changedKeys.size > 0) {
      const toNotify = new Set<ContextStoreListener>();
      changedKeys.forEach(key => {
        listenersByKeyRef.current.get(key)?.forEach(listener => toNotify.add(listener));
      });
      toNotify.forEach(listener => listener());
    }

    onAfterAUpdate?.(ref.current);
  }, []);

  useEffect(() => {
    let requestId: number;
    const process = () => {
      processQueue();
      requestId = requestAnimationFrame(process);
    };

    process();

    return () => {
      cancelAnimationFrame(requestId);
    };
    // Runs once for the component's lifetime: the rAF loop below is self-scheduling, and nothing
    // it reads changes identity (processQueue is a stable useCallback with no deps).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { update, ref: ref.current, subscribe };
};
