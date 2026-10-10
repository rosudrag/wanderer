/**
 * `beautify.worker.ts`'s `onmessage` and `beautifyClient.ts`'s fallback
 * both delegate to `handleBeautifyRequest`/`recoverPendingViaFallback`
 * from `./beautifyProtocol` — the only two pieces of routing logic that
 * can actually be wrong, tested here directly. `beautifyClient.ts` and
 * `beautify.worker.ts` themselves cannot be imported under this repo's
 * `ts-jest` config at all: `new Worker(new URL(..., import.meta.url))`
 * (Vite's own convention for bundling a worker) makes `import.meta` a
 * HARD TypeScript compile error under the CommonJS module target
 * `ts-jest` transforms to — not a missing-`Worker`-in-jsdom limitation,
 * the file fails to PARSE, regardless of which branch would run. Every
 * piece of logic worth testing is therefore pulled into
 * `beautifyProtocol.ts`, which has zero dependency on `Worker` or
 * `import.meta`, so it is importable and testable like any other module.
 */
import { describe, it, expect } from '@jest/globals';
import { beautifyLayout } from '../index';
import { handleBeautifyRequest, recoverPendingViaFallback } from '../beautifyProtocol';
import type { LayoutEdgeInput, LayoutNodeInput, LayoutResult } from '../types';
import type { BeautifyWorkerRequest, PendingBeautifyEntry } from '../beautifyProtocol';

// A small wormhole-chain scenario (no k-space lattice lookup involved).
const chainNodes: LayoutNodeInput[] = [
  { id: 'root', x: 0, y: 0, locked: false },
  { id: 'a', x: 50, y: 10, locked: false },
  { id: 'b', x: 90, y: 40, locked: false },
  { id: 'c', x: 10, y: 90, locked: false },
  { id: 'd', x: 120, y: 120, locked: false },
];
const chainEdges: LayoutEdgeInput[] = [
  { source: 'root', target: 'a', type: 0 },
  { source: 'a', target: 'b', type: 0 },
  { source: 'root', target: 'c', type: 0 },
  { source: 'c', target: 'd', type: 0 },
];

// A small real k-space scenario (Jita, Amarr-ish real ids — exercises the
// dynamically-imported regionLayouts.json path, same as a real map).
const kspaceNodes: LayoutNodeInput[] = [
  { id: '30000142', x: 10, y: 10, locked: false }, // Jita
  { id: '30000144', x: 90, y: 20, locked: false }, // Perimeter
  { id: '30000145', x: 40, y: 80, locked: false }, // New Caldari
];
const kspaceEdges: LayoutEdgeInput[] = [
  { source: '30000142', target: '30000144', type: 1 },
  { source: '30000144', target: '30000145', type: 1 },
];

describe('handleBeautifyRequest matches calling beautifyLayout directly', () => {
  it('chain scenario: same LayoutResult', async () => {
    const direct = await beautifyLayout(chainNodes, chainEdges, {});
    const response = await handleBeautifyRequest(beautifyLayout, {
      requestId: 1,
      nodes: chainNodes,
      edges: chainEdges,
      options: {},
    });
    expect(response.error).toBeUndefined();
    expect(response.result).toEqual(direct);
  });

  it('k-space scenario: same LayoutResult', async () => {
    const direct = await beautifyLayout(kspaceNodes, kspaceEdges, {});
    const response = await handleBeautifyRequest(beautifyLayout, {
      requestId: 2,
      nodes: kspaceNodes,
      edges: kspaceEdges,
      options: {},
    });
    expect(response.error).toBeUndefined();
    expect(response.result).toEqual(direct);
  });

  it('reports a thrown error as a response.error instead of throwing', async () => {
    const throwingEngine = async (): Promise<LayoutResult> => {
      throw new Error('synthetic failure');
    };
    const response = await handleBeautifyRequest(throwingEngine, {
      requestId: 3,
      nodes: chainNodes,
      edges: chainEdges,
      options: {},
    });
    expect(response.result).toBeUndefined();
    expect(response.error).toBe('synthetic failure');
  });
});

describe('recoverPendingViaFallback resolves in-flight requests instead of rejecting them', () => {
  it('settles every pending entry with the fallback result, same as handleBeautifyRequest would give it', async () => {
    const requestA: BeautifyWorkerRequest = { requestId: 1, nodes: chainNodes, edges: chainEdges, options: {} };
    const requestB: BeautifyWorkerRequest = { requestId: 2, nodes: kspaceNodes, edges: kspaceEdges, options: {} };

    const resultsA: LayoutResult[] = [];
    const resultsB: LayoutResult[] = [];
    const pending = new Map<number, PendingBeautifyEntry>([
      [1, { request: requestA, resolve: r => resultsA.push(r), reject: () => {} }],
      [2, { request: requestB, resolve: r => resultsB.push(r), reject: () => {} }],
    ]);

    // The same shape of fallback `beautifyClient.ts`'s `runFallback` is:
    // call the real engine through `handleBeautifyRequest`, throw on an
    // error response.
    const runFallback = async (request: BeautifyWorkerRequest): Promise<LayoutResult> => {
      const response = await handleBeautifyRequest(beautifyLayout, request);
      if (response.error) throw new Error(response.error);
      return response.result!;
    };

    await recoverPendingViaFallback(pending, runFallback);

    const directA = await beautifyLayout(chainNodes, chainEdges, {});
    const directB = await beautifyLayout(kspaceNodes, kspaceEdges, {});
    expect(resultsA).toEqual([directA]);
    expect(resultsB).toEqual([directB]);
  });

  it('rejects (not resolves) a pending entry when the fallback itself fails', async () => {
    const request: BeautifyWorkerRequest = { requestId: 1, nodes: chainNodes, edges: chainEdges, options: {} };
    let rejected: Error | undefined;
    const pending = new Map<number, PendingBeautifyEntry>([
      [1, { request, resolve: () => {}, reject: e => { rejected = e; } }],
    ]);
    const failingFallback = async (): Promise<LayoutResult> => {
      throw new Error('fallback also failed');
    };

    await recoverPendingViaFallback(pending, failingFallback);

    expect(rejected?.message).toBe('fallback also failed');
  });
});
