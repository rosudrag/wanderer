import { act } from 'react-dom/test-utils';
import { createRoot } from 'react-dom/client';
import { MapProvider, useMapSelector, useMapState } from '@/hooks/Mapper/components/map/MapProvider';

test('useMapSelector bails when the selected boolean does not change', async () => {
  let renderCount = 0;
  let capturedUpdate: ((v: { visibleNodes: Set<string> }) => void) | null = null;

  function Probe({ id }: { id: string }) {
    const { update } = useMapState();
    capturedUpdate = update;
    const visible = useMapSelector(['visibleNodes'], d => d.visibleNodes.has(id));
    renderCount++;
    return <div>{String(visible)}</div>;
  }

  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);

  await act(async () => {
    root.render(
      <MapProvider onCommand={async () => ({}) as never}>
        <Probe id="a" />
      </MapProvider>,
    );
  });

  expect(renderCount).toBe(1);

  const allIds = ['a', 'b', 'c'];

  // First establish 'a' as actually visible (a REAL transition from the initial empty Set -
  // this one SHOULD, correctly, cause exactly one re-render).
  await act(async () => {
    capturedUpdate!({ visibleNodes: new Set(allIds) });
    const { promise, resolve } = Promise.withResolvers<void>();
    requestAnimationFrame(() => resolve());
    await promise;
  });
  expect(renderCount).toBe(2);

  // NOW queue 10 more updates with the SAME membership as the current (already-established)
  // state - 'a' stays in the set every time, so `visible` never actually changes again.
  await act(async () => {
    for (let i = 0; i < 10; i++) {
      capturedUpdate!({ visibleNodes: new Set(allIds) });
    }
    const { promise, resolve } = Promise.withResolvers<void>();
    requestAnimationFrame(() => resolve());
    await promise;
  });

  // eslint-disable-next-line no-console
  console.log('UNIT renderCount after 10 genuinely-no-op updates:', renderCount);
  expect(renderCount).toBe(2); // no further renders - selector output never changed

  root.unmount();
});
