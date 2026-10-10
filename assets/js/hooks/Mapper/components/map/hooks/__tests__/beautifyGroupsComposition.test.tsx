/**
 * Proves the collapse/beautify composition decision: beautify ALWAYS solves the full,
 * uncollapsed system graph - the collapse transform (`deriveCollapsedView`) only re-derives
 * group tiles from whatever positions beautify (or anything else) wrote, it never changes what
 * beautify itself sees. `useBeautify.ts` is untouched (owned by the concurrent layout-worker
 * session) - this test proves the claim from the OUTSIDE, by mounting it twice with different
 * collapse state and confirming its solve input is byte-identical both times, not by reading its
 * source and assuming.
 */
import { act } from 'react-dom/test-utils';
(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
import { createRoot } from 'react-dom/client';
import { MapRootProvider, useMapRootState } from '@/hooks/Mapper/mapRootProvider';
import { ToastProvider } from '@/hooks/Mapper/ToastProvider';
import { useBeautify } from '@/hooks/Mapper/components/map/hooks/useBeautify';
import { Commands, CommandInit, MapHandlers } from '@/hooks/Mapper/types/mapHandlers';
import { RoutesList } from '@/hooks/Mapper/types/routes';
import { UserPermission, UserPermissions } from '@/hooks/Mapper/types/permissions';
import { SolarSystemRawType } from '@/hooks/Mapper/types';

// Same ESM-transitive-import gap `__perf__/harness.tsx` documents in full ("Harness
// limitations"): `MapRootProvider` -> `useStoreWidgets` -> `mapInterface/constants.tsx` pulls in
// the whole widget render tree (MarkdownEditor/@codemirror, react-markdown, ...), none of which
// this test's `useBeautify()` probe ever touches.
jest.mock('@/hooks/Mapper/components/mapInterface/components/MarkdownEditor', () => ({
  MarkdownEditor: () => null,
}));
jest.mock('@/hooks/Mapper/components/mapInterface/widgets', () => ({
  CommentsWidget: () => null,
  LocalCharacters: () => null,
  SystemInfo: () => null,
  SystemSignatures: () => null,
  SystemStructures: () => null,
  WRoutesPublic: () => null,
  WRoutesUser: () => null,
  WRoutesBy: () => null,
  WSystemKills: () => null,
}));

let lastRunBeautifyArgs: unknown[] | null = null;
jest.mock('@/hooks/Mapper/components/map/layout/beautifyClient', () => ({
  runBeautify: async (...args: unknown[]) => {
    lastRunBeautifyArgs = args;
    return {
      positions: {},
      movedCount: 0,
      mode: 'full',
      quality: { before: { occlusions: 0, overlaps: 0, crossings: 0, offAngle: 0 }, after: { occlusions: 0, overlaps: 0, crossings: 0, offAngle: 0 } },
    };
  },
}));

const mockOutCommand = async () => ({}) as never;

function buildSystems(n: number): SolarSystemRawType[] {
  const systems: SolarSystemRawType[] = [];
  for (let i = 0; i < n; i++) {
    systems.push({
      id: String(30000000 + i),
      position: { x: i * 100, y: 0 },
      description: null,
      labels: null,
      locked: false,
      tag: null,
      status: 0,
      name: null,
      temporary_name: null,
      linked_sig_eve_id: null,
      comments_count: 0,
      system_static_info: {
        region_id: 10000000 + (i % 5),
        constellation_id: 1,
        solar_system_id: 30000000 + i,
        solar_system_name: `Sys${i}`,
        solar_system_name_lc: `sys${i}`,
        constellation_name: 'C',
        region_name: `Region ${i % 5}`,
        system_class: 7,
        security: '0.5',
        type_description: '',
        class_title: '',
        is_shattered: false,
        effect_name: '',
        effect_power: 0,
        statics: [],
        wandering: [],
        triglavian_invasion_status: 'Normal',
        sun_type_id: 1,
      },
      system_signatures: [],
    });
  }
  return systems;
}

const EMPTY_USER_PERMISSIONS: UserPermissions = {
  [UserPermission.ADMIN_MAP]: false,
  [UserPermission.MANAGE_MAP]: false,
  [UserPermission.VIEW_SYSTEM]: false,
  [UserPermission.VIEW_CHARACTER]: false,
  [UserPermission.VIEW_CONNECTION]: false,
  [UserPermission.ADD_SYSTEM]: false,
  [UserPermission.ADD_CONNECTION]: false,
  [UserPermission.UPDATE_SYSTEM]: false,
  [UserPermission.TRACK_CHARACTER]: false,
  [UserPermission.DELETE_CONNECTION]: false,
  [UserPermission.DELETE_SYSTEM]: false,
  [UserPermission.LOCK_SYSTEM]: false,
  [UserPermission.ADD_ACL]: false,
  [UserPermission.DELETE_ACL]: false,
  [UserPermission.DELETE_MAP]: false,
};

async function mountAndBeautify(
  mapSlug: string,
  collapsedGroups: string[],
  opts?: { scope?: 'all' | 'selection'; selectedSystems?: string[] },
): Promise<unknown[] | null> {
  const LS_KEY = 'map-user-settings-v3';
  localStorage.setItem(
    LS_KEY,
    JSON.stringify({
      [mapSlug]: {
        version: 11,
        migratedFromOld: true,
        widgets: { visible: [], windows: {} },
        groups: { collapsedGroups, groupPositions: {} },
      },
    }),
  );

  const mapRootRef: { current: MapHandlers | null } = { current: null };
  const beautifyRef: { current: ((params: { scope: 'all' | 'selection' }) => Promise<void>) | null } = { current: null };
  // Captures the REAL `MapRootProvider.update()` - the exact function
  // `MapWrapper.tsx`'s `onSelectionChange` calls with `{ selectedSystems }` after FIX 3 expands
  // any selected group tile into its real member ids. Using it directly here sidesteps needing
  // to mount `MapWrapper.tsx`'s whole tree just to simulate "the user selected these systems".
  const updateRef: { current: ((patch: { selectedSystems?: string[] }) => void) | null } = { current: null };

  function Probe() {
    const { beautify } = useBeautify();
    const { update } = useMapRootState();
    beautifyRef.current = beautify;
    updateRef.current = update;
    return null;
  }

  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);

  await act(async () => {
    root.render(
      <ToastProvider>
        <MapRootProvider outCommand={mockOutCommand} fwdRef={mapRootRef}>
          <Probe />
        </MapRootProvider>
      </ToastProvider>,
    );
  });

  const systems = buildSystems(25);
  const initCommand: CommandInit = {
    systems,
    connections: [],
    system_signatures: {},
    kills: [],
    system_static_infos: [],
    wormholes: [],
    effects: [],
    characters: [],
    present_characters: [],
    user_characters: [],
    user_permissions: EMPTY_USER_PERMISSIONS,
    hubs: [],
    user_hubs: [],
    routes: { loading: false, solar_system_id: '', routes: [], systems_static_data: [] } satisfies RoutesList,
    options: {
      allowed_copy_for: UserPermission.VIEW_SYSTEM,
      allowed_paste_for: UserPermission.VIEW_SYSTEM,
      layout: '',
      restrict_offline_showing: 'false',
      show_linked_signature_id: 'false',
      show_linked_signature_id_temp_name: 'false',
      show_temp_system_name: 'false',
      store_custom_labels: 'false',
      beautifier_enabled: 'true',
      groups_enabled: 'true',
    },
    expired_characters: [],
    map_slug: mapSlug,
  };

  await act(async () => {
    mapRootRef.current?.command(Commands.init, initCommand);
  });
  await act(async () => {
    const { promise, resolve } = Promise.withResolvers<void>();
    setTimeout(resolve, 30);
    await promise;
  });
  await act(async () => {
    for (let i = 0; i < 10; i++) {
      const { promise, resolve } = Promise.withResolvers<void>();
      requestAnimationFrame(() => resolve());
      await promise;
    }
  });
  if (opts?.selectedSystems) {
    act(() => {
      updateRef.current?.({ selectedSystems: opts.selectedSystems });
    });
    await act(async () => {
      for (let i = 0; i < 5; i++) {
        const { promise, resolve } = Promise.withResolvers<void>();
        requestAnimationFrame(() => resolve());
        await promise;
      }
    });
  }

  lastRunBeautifyArgs = null;
  await act(async () => {
    await beautifyRef.current?.({ scope: opts?.scope ?? 'all' });
  });

  const result = lastRunBeautifyArgs;
  act(() => {
    root.unmount();
  });
  container.remove();
  localStorage.clear();
  return result;
}

test('beautify (scope: all) solves the identical system/connection graph whether a region is collapsed or expanded', async () => {
  const expandedArgs = await mountAndBeautify('map-a', []);
  const collapsedArgs = await mountAndBeautify('map-a', ['region:10000000', 'region:10000001']);

  expect(expandedArgs).not.toBeNull();
  expect(collapsedArgs).not.toBeNull();
  // `runBeautify(nodes, edges, options)` - the solve INPUT must be identical: beautify reads
  // `MapRootData.systems`/`connections` directly, never anything collapse-derived.
  expect(JSON.stringify(collapsedArgs)).toEqual(JSON.stringify(expandedArgs));
});

test('FIX 3: beautify scope:"selection" solves the real member systems when MapRootData.selectedSystems holds expanded member ids (what handleSelectionChange now produces, not a synthetic group: id)', async () => {
  // `buildSystems(25)`'s region assignment is `10000000 + (i % 5)` - region:10000000 covers
  // i=0,5,10,15,20, i.e. systems 30000000/30000005/30000010/30000015/30000020. This is exactly
  // what `expandSelectionSystemIds` would have produced from a selected `group:region:10000000`
  // tile BEFORE fix 3 (Map.tsx's `handleSelectionChange`) ever lets `onSelectionChange` - and
  // hence `MapRootData.selectedSystems` - see the synthetic id at all.
  const regionMembers = ['30000000', '30000005', '30000010', '30000015', '30000020'];

  const args = await mountAndBeautify('map-b', ['region:10000000'], {
    scope: 'selection',
    selectedSystems: regionMembers,
  });

  expect(args).not.toBeNull();
  const [nodes] = args as [{ id: string }[]];
  expect(new Set(nodes.map(n => n.id))).toEqual(new Set(regionMembers));
});
