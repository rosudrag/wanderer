// CHEWY PATCH: new file. The message protocol between `beautifyClient.ts`
// (main thread) and `beautify.worker.ts` (worker thread), plus the one
// piece of routing logic that actually runs on both sides of that
// boundary — `handleBeautifyRequest`. Pulling it out of `beautify.worker.ts`
// means a jest test (no real `Worker` in jsdom) can exercise the EXACT same
// function the worker's `onmessage` calls, instead of a parallel
// reimplementation that could silently drift from it.
import type { BeautifyOptions, LayoutEdgeInput, LayoutNodeInput, LayoutResult } from './types';
import type { beautifyLayout } from './index';

export interface BeautifyWorkerRequest {
  requestId: number;
  nodes: LayoutNodeInput[];
  edges: LayoutEdgeInput[];
  options: BeautifyOptions;
}

export type BeautifyWorkerResponse =
  | { requestId: number; result: LayoutResult; error?: undefined }
  | { requestId: number; result?: undefined; error: string };

/**
 * Runs `engine` (always the real `beautifyLayout`, passed in rather than
 * imported, so this module itself has zero dependency on which thread it
 * runs in) against one request and returns the response message. Never
 * throws — a solve failure becomes an `error` response, same contract as a
 * successful one, so the caller's `postMessage`/`Promise` plumbing has one
 * shape to handle either way.
 */
export const handleBeautifyRequest = async (
  engine: typeof beautifyLayout,
  request: BeautifyWorkerRequest,
): Promise<BeautifyWorkerResponse> => {
  try {
    const result = await engine(request.nodes, request.edges, request.options);
    return { requestId: request.requestId, result };
  } catch (err) {
    return { requestId: request.requestId, error: err instanceof Error ? err.message : String(err) };
  }
};

/**
 * The piece of "the worker died mid-flight" recovery logic that is pure
 * data plumbing — no `Worker`, no `import.meta.url` — pulled out of
 * `beautifyClient.ts` for the same reason `handleBeautifyRequest` was:
 * `beautifyClient.ts` itself cannot be imported under this repo's
 * `ts-jest` config at all (`import.meta.url`, required by Vite's
 * `new Worker(new URL(...))` convention, is a hard TypeScript compile
 * error under the CommonJS module target `ts-jest` transforms to — not a
 * missing-`Worker`-global/jsdom limitation, the file fails to PARSE), so
 * the one behaviour that can actually be wrong here — "every request
 * still in flight gets resolved via the fallback, not rejected" — has to
 * live somewhere a test can reach it directly.
 */
export interface PendingBeautifyEntry {
  request: BeautifyWorkerRequest;
  resolve: (r: LayoutResult) => void;
  reject: (e: Error) => void;
}

export const recoverPendingViaFallback = (
  pending: ReadonlyMap<number, PendingBeautifyEntry>,
  runFallback: (request: BeautifyWorkerRequest) => Promise<LayoutResult>,
): Promise<void> => {
  const settlements = [...pending.values()].map(entry => runFallback(entry.request).then(entry.resolve, entry.reject));
  return Promise.all(settlements).then(() => undefined);
};
