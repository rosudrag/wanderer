// CHEWY PATCH: new file. Runs `beautifyLayout` (the pure layout engine —
// no DOM, no React, no side input besides the dynamically-imported
// `data/regionLayouts.json`, which resolves fine from a module worker the
// same way it does from the main thread) off the main thread. The engine
// itself is UNCHANGED and lives in exactly one place (`./index`); this file
// is a message-passing transport only — `handleBeautifyRequest` in
// `./beautifyProtocol` is the actual routing logic, shared with the jest
// test that cannot construct a real Worker in jsdom, so there is no second
// copy of either the algorithm or the request/response handling to keep in
// sync.
import { beautifyLayout } from './index';
import { handleBeautifyRequest } from './beautifyProtocol';
import type { BeautifyWorkerRequest } from './beautifyProtocol';

self.onmessage = async (event: MessageEvent<BeautifyWorkerRequest>) => {
  const response = await handleBeautifyRequest(beautifyLayout, event.data);
  (self as unknown as Worker).postMessage(response);
};
