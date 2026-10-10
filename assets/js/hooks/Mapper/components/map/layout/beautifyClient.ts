// CHEWY PATCH: new file. Main-thread entry point for `useBeautify.ts`:
// runs the layout solve in `beautify.worker.ts` (off the main thread) when
// a Worker can be constructed, and falls back to calling `beautifyLayout`
// directly, in-process, when it cannot (SSR, a test runner without Worker,
// a browser/CSP policy that blocks module workers, the worker throwing on
// construction, or the worker crashing mid-flight) — so the feature cannot
// break anywhere workers are unavailable, including the one click in
// flight when a worker dies. Exactly one algorithm either way: both paths
// call the same `beautifyLayout` from `./index`, via the same
// `handleBeautifyRequest` from `./beautifyProtocol`, never a duplicate.
//
// `./index` (the engine, which pulls in `regionLayouts.json`) is imported
// DYNAMICALLY here, only inside the fallback path — when the worker is
// available and healthy, the main thread never needs the engine's own code
// at all, only the small request/response plumbing in `./beautifyProtocol`.
// A static top-level import would keep the whole engine (and its dataset)
// in the main bundle regardless of whether the worker ever runs, which is
// exactly what duplicated `regionLayouts.json` between the main bundle and
// the worker's bundle instead of removing it from the main one.
import { handleBeautifyRequest, recoverPendingViaFallback } from './beautifyProtocol';
import type { BeautifyWorkerRequest, BeautifyWorkerResponse, PendingBeautifyEntry } from './beautifyProtocol';
import type { BeautifyOptions, LayoutEdgeInput, LayoutNodeInput, LayoutResult } from './types';
import type { beautifyLayout } from './index';

let worker: Worker | null | undefined; // undefined = not yet attempted, null = attempted and failed (permanent fallback)
let nextRequestId = 1;
const pending = new Map<number, PendingBeautifyEntry>();

let enginePromise: Promise<{ beautifyLayout: typeof beautifyLayout }> | null = null;
const loadEngine = (): Promise<{ beautifyLayout: typeof beautifyLayout }> => {
  if (!enginePromise) enginePromise = import('./index');
  return enginePromise;
};

const runFallback = async (request: BeautifyWorkerRequest): Promise<LayoutResult> => {
  const { beautifyLayout } = await loadEngine();
  const response = await handleBeautifyRequest(beautifyLayout, request);
  if (response.error) throw new Error(response.error);
  return response.result!;
};

/**
 * The worker itself died (crashed, or sent a payload that failed to
 * structured-clone) rather than one request failing — a per-request
 * failure arrives as a normal `{requestId, error}` message and is handled
 * in `onmessage`, not here. Every request still in flight is re-run
 * through the in-process fallback and settled from THAT outcome, not
 * rejected outright, so the click the user is actually waiting on still
 * resolves — "the feature cannot break" has to hold for the in-flight
 * request too, not just the next one. The worker is never retried this
 * session; every future call falls back directly.
 */
const recoverFromWorkerDeath = (): void => {
  const snapshot = new Map(pending);
  pending.clear();
  worker = null;
  void recoverPendingViaFallback(snapshot, runFallback);
};

const getWorker = (): Worker | null => {
  if (worker !== undefined) return worker;
  if (typeof Worker === 'undefined') {
    worker = null;
    return null;
  }
  try {
    const w = new Worker(new URL('./beautify.worker.ts', import.meta.url), { type: 'module' });
    w.onmessage = (event: MessageEvent<BeautifyWorkerResponse>) => {
      const { requestId, result, error } = event.data;
      const entry = pending.get(requestId);
      if (!entry) return;
      pending.delete(requestId);
      if (error) entry.reject(new Error(error));
      else entry.resolve(result!);
    };
    w.onerror = recoverFromWorkerDeath;
    // A response that fails to structured-clone (should not happen —
    // `LayoutResult` is plain data — but a corrupted/unexpected payload is
    // exactly the kind of thing that must not silently hang a pending
    // promise forever) is the same "the worker cannot be trusted anymore"
    // case as onerror, not a per-request failure.
    w.onmessageerror = recoverFromWorkerDeath;
    worker = w;
    return w;
  } catch {
    worker = null;
    return null;
  }
};

/**
 * Runs `beautifyLayout` off the main thread via `beautify.worker.ts` when
 * possible, else synchronously in-process via the SAME `handleBeautifyRequest`
 * the real worker calls (see ./beautifyProtocol). Same return shape either way.
 */
export const runBeautify = async (
  nodes: LayoutNodeInput[],
  edges: LayoutEdgeInput[],
  options: BeautifyOptions,
): Promise<LayoutResult> => {
  const requestId = nextRequestId++;
  const request: BeautifyWorkerRequest = { requestId, nodes, edges, options };

  const w = getWorker();
  if (!w) return runFallback(request);

  // CHEWY PATCH: plain `new Promise` constructor, not `Promise.withResolvers`
  // — this app's declared browser floor (`vite.config.js`'s `build.target:
  // 'es2018'`) is a SYNTAX transpilation target only, it does not polyfill
  // runtime methods, and `Promise.withResolvers` (ES2024) is a runtime
  // method lookup that would throw on any engine below Chrome 119/Safari
  // 17.4/Node 22, with no fallback — the throw happens before the
  // worker/fallback choice even matters.
  return new Promise<LayoutResult>((resolve, reject) => {
    pending.set(requestId, { request, resolve, reject });
    w.postMessage(request);
  });
};
