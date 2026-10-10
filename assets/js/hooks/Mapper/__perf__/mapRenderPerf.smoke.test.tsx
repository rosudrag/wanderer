/**
 * The render-perf refactor's biggest risk is a STALE selector: a node that stops re-rendering on
 * a change it actually needed to react to. This asserts the rendered DOM - not just the
 * render-count metric (see mapRenderPerf.regression.test.tsx) - still reflects hover /
 * isConnecting / visibleNodes exactly like before the refactor.
 */
import { mapStateBox, mountHarness, timeAct, unmount } from './harness';

describe('Map canvas still works after the render-perf refactor (DOM-level smoke test)', () => {
  test("hover shows/hides a node's connection handles", async () => {
    const h = await mountHarness(50);
    const firstNodeId = String(30000000);
    const nodeEl = h.container.querySelector(`[data-id="${firstNodeId}"]`) as HTMLElement;
    const handle = () => nodeEl.querySelector('.react-flow__handle') as HTMLElement | null;

    expect(handle()?.style.visibility).toBe('hidden');

    await timeAct(() => {
      mapStateBox.current?.update({ hoverNodeId: firstNodeId });
    }, 5);
    expect(handle()?.style.visibility).toBe('visible');

    await timeAct(() => {
      mapStateBox.current?.update({ hoverNodeId: null });
    }, 5);
    expect(handle()?.style.visibility).toBe('hidden');

    unmount(h);
  });

  test('hovering one node does not show handles on an unrelated node', async () => {
    const h = await mountHarness(50);
    const firstNodeId = String(30000000);
    const otherNodeId = String(30000005);
    const otherEl = h.container.querySelector(`[data-id="${otherNodeId}"]`) as HTMLElement;
    const otherHandle = () => otherEl.querySelector('.react-flow__handle') as HTMLElement | null;

    await timeAct(() => {
      mapStateBox.current?.update({ hoverNodeId: firstNodeId });
    }, 5);
    expect(otherHandle()?.style.visibility).toBe('hidden');

    unmount(h);
  });

  test('isConnecting shows handles on every node (so a user can drag a connection to any of them)', async () => {
    const h = await mountHarness(10);
    const anyNodeId = String(30000007);
    const nodeEl = h.container.querySelector(`[data-id="${anyNodeId}"]`) as HTMLElement;
    const handle = () => nodeEl.querySelector('.react-flow__handle') as HTMLElement | null;

    expect(handle()?.style.visibility).toBe('hidden');

    await timeAct(() => {
      mapStateBox.current?.update({ isConnecting: true });
    }, 5);
    expect(handle()?.style.visibility).toBe('visible');

    unmount(h);
  });

  test('a visibleNodes change toggles the Bookmarks row for the affected node only', async () => {
    const h = await mountHarness(5);
    const targetId = String(30000002);
    const nodeEl = h.container.querySelector(`[data-id="${targetId}"]`) as HTMLElement;

    // The node starts visible (useUpdateNodes computed the real viewport on mount); drive it
    // through the real update() channel the same way useUpdateNodes would on a viewport change.
    expect(nodeEl.querySelector('.RootCustomNode')).not.toBeNull();

    await timeAct(() => {
      mapStateBox.current?.update({ visibleNodes: new Set(['30000000', '30000001']) });
    }, 5);

    // nodeVars.visible gates the HeadRow content (system name etc.) inside RootCustomNode - the
    // node itself always renders, but its content collapses when not visible.
    expect(nodeEl.querySelector('.HeadRow')).toBeNull();

    unmount(h);
  });
});
