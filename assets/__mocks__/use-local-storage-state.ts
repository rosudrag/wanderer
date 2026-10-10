// Jest manual mock for `use-local-storage-state`: the real package ships ESM-only (no CJS
// build), and there is no babel.config in `assets/` for babel-jest to transpile node_modules
// through, so ts-jest's CJS runtime cannot `require()` it at all ("Cannot use import statement
// outside a module") - confirmed pre-existing, not introduced here: `to_6.test.ts` (2 weeks old)
// transitively imports it and could never actually run under `yarn test`, it just failed earlier
// (jest-environment-jsdom was missing entirely) before this gap was ever reached. Wired in via
// `moduleNameMapper` in jest.config.js so every test gets this automatically instead of each test
// file needing its own `jest.mock('use-local-storage-state', ...)`.
//
// Reads/writes the REAL `localStorage` (jsdom provides a real, synchronous implementation) -
// this was a plain in-memory `useState` ignoring `localStorage` entirely in an earlier version,
// which was fine while nothing in the suite asserted on persisted content; the map region/
// wormhole-chain collapse feature's tests now seed `localStorage` BEFORE mount and assert the
// seeded value is read (collapse state surviving a remount, migrating an old stored blob), so
// this needs to behave like the real package for that case, not just match its return shape.
import { useCallback, useState } from 'react';

function readStorage<T>(key: string, defaultValue: T): T {
  try {
    const raw = localStorage.getItem(key);
    if (raw == null) {
      return defaultValue;
    }
    return JSON.parse(raw) as T;
  } catch {
    return defaultValue;
  }
}

export default function useLocalStorageState<T>(
  key: string,
  options: { defaultValue: T },
): [T, (value: T | ((prev: T) => T)) => void] {
  const [value, setValue] = useState<T>(() => readStorage(key, options.defaultValue));

  const setAndPersist = useCallback(
    (next: T | ((prev: T) => T)) => {
      setValue(prev => {
        const resolved = typeof next === 'function' ? (next as (prev: T) => T)(prev) : next;
        try {
          localStorage.setItem(key, JSON.stringify(resolved));
        } catch {
          // ignore - matches the real package's best-effort persistence
        }
        return resolved;
      });
    },
    [key],
  );

  return [value, setAndPersist];
}
