# Map region / wormhole-chain collapse (`WANDERER_MAP_GROUPS`)

Default OFF (upstream behaviour unchanged when off). A view-only transform: a collapsed group
replaces a region's or a wormhole chain's member systems with ONE draggable tile on the canvas.
Nothing about what the server stores changes, except that dragging a collapsed group moves its
members' real positions (one bulk out-command, same shape the beautifier already uses).

## Grouping keys (`components/map/groups/computeGroups.ts`, pure, no server call)

- k-space system → `region:<region_id>` (from `getSystemStaticInfo(id).region_id`, the same
  lookup `useSolarSystemNode.ts` already does). Pochven (`region_id === Regions.Pochven`) displays
  its constellation name instead of its region name, matching that hook's existing display rule.
- wormhole system → `chain:<rootId>`: the connected component of J-space systems over CURRENT
  connections (an edge to/from a k-space system, or to a system outside the component, never joins
  it), keyed by the numerically smallest member id so the key stays the same as the chain grows or
  shrinks by one end.
- A group is returned only if it has >= 2 members; a system whose static info has not loaded yet
  (`getSystemStaticInfo` cache miss) is excluded - ungroupable until it loads.
- Pure unit tests: `components/map/groups/__tests__/computeGroups.test.ts`.

## The choke point (`components/map/groups/deriveCollapsedView.ts`)

A single pure function: `(raw ReactFlow nodes/edges, computed groups, which keys are collapsed,
committed group positions, characters/pings for the badges) -> (view nodes, view edges)`. Called
from exactly one place - `Map.tsx`'s `MapComp`, via `useMapGroups.ts` - immediately before
`<ReactFlow nodes={...} edges={...}>`. Every `rf.setNodes`/`rf.setEdges` call site
(`useMapInit.ts`, `useMapAddSystems.ts`, `useMapUpdateSystems.ts`, `useMapRemoveSystems.ts`,
`useCommandsConnections.ts`) keeps writing the RAW arrays exactly as before - there is no second,
parallel derived array anything else could write to and desynchronise from. Returns the SAME array
references, unmodified, when nothing is collapsed (verified by a unit test) - zero extra work in
the `WANDERER_MAP_GROUPS`-off or nothing-collapsed case.

- Collapsed members: `hidden: true, selectable: false, draggable: false`. ReactFlow skips hidden
  nodes and their edges entirely - no DOM, no render, no selection, no context menu - which is the
  whole point and satisfies "hidden members must not be selectable or context-menu-able" for free.
- One synthetic node per collapsed group, `id: group:<key>`, `type: 'group'`
  (`GroupNodeData`: `displayName`, `memberIds`, `onlineCount` - summed over every member via the
  `charactersBySystem` index Fix 4 of `docs/chewy/map-perf-findings.md` built, never filtering the
  whole character list - `hasRally`, `hasCurrentCharacterLocation`). Position: the committed
  `groupPositions[key]` if the group has been dragged before, otherwise the grid-snapped centroid
  of its members at collapse time.
- Edges: an edge whose both endpoints resolve to the SAME collapsed group is internal - dropped.
  An edge crossing a group boundary is replaced by a synthetic edge between the group node id and
  the other (possibly also-group) endpoint, de-duplicated by endpoint pair with a running `count`
  (rendered when > 1). An edge touching no collapsed group passes straight through unmodified. The
  real `connections` list (`MapRootData.connections`) is never touched - this is purely derived.
- Pure unit tests: `components/map/groups/__tests__/deriveCollapsedView.test.ts`.

## `useMapGroups.ts` (`components/map/hooks/`) - wires it into `Map.tsx`

- Reads `systems`/`connections`/`collapsedGroupKeys`/`groupPositions`/`pings` via
  `useMapRootSelector` (per-key, isolated - see the `useMapRootState()` migration section of
  `docs/chewy/map-perf-findings.md`), and `charactersBySystem`/`userCharacters` via
  `MapProvider.tsx`'s `useMapSelector`. Both are selector-based, not plain `useMapRootState()`
  reads, for the same reason `Map.tsx`'s other hot-path reads are: this hook lives inside
  `MapComp`, the parent of every node/edge on the canvas.
- `collapsedGroupKeys`/`groupPositions` are mirrored from `storedSettings.settingsGroups` into
  `MapRootData` (`MapRootProvider.tsx`, same pattern as the `interfaceSettings` mirror) so they're
  selectable this way at all - `storedSettings` fields are independent, localStorage-backed React
  state, not part of the `useContextStore`-managed store.
- `filterGroupNodeChanges(changes)`: intercepts any `NodeChange` targeting a synthetic group id
  before it would reach the real `onNodesChange`/raw node array (which doesn't recognise that id).
  A `position` change with `dragging: false` (drag stop) computes the delta from the group's last
  COMMITTED position, applies that SAME delta to every member's real position in the raw node
  array, persists the group's new committed position (`settingsGroupsUpdate`), and emits ONE
  `OutCommand.updateSystemPositionsBulk` call with every member's new position - the exact shape
  `useBeautify.ts`'s `applyPositions` already uses. During the drag (not yet dropped), the group's
  rendered position follows a local-only override state so it doesn't snap back to its last
  committed position every render; the override is cleared once the real commit lands.
- `collapseGroup`/`expandGroup`/`collapseAllRegions`/`expandAll`/`isGroupCollapsed`: thin wrappers
  around `settingsGroupsUpdate`, wired into `ContextMenuRoot.tsx` ("Collapse all regions"/"Expand
  all") and `Map.tsx`'s `onNodeClick` (clicking a group tile expands it). "Collapse region
  `<name>`"/"Collapse chain" on a right-clicked system are wired directly in
  `useContextMenuSystemItems.tsx` (not through `useMapGroups`, since that menu lives in
  `MapWrapper.tsx`'s tree, outside `Map.tsx`'s own; it recomputes `computeGroups` locally - fine,
  this menu renders once per right-click, not once per node).
- Focused unit test for the drag -> bulk-update payload (the part that can silently corrupt a
  map, proven with mocked `useMapRootSelector`/`useMapSelector` since jsdom cannot drive a real
  ReactFlow drag - see `docs/chewy/map-perf-findings.md` "Harness limitations"):
  `components/map/hooks/__tests__/useMapGroups.test.tsx`.

## `GroupNode` (`components/map/components/GroupNode/`)

Presentational only, matching `SolarSystemNodeDefault`'s visual language (same scss variables,
same handle convention - 4 source handles at Top/Right/Bottom/Left so boundary edges can route to
it). Shows the group's display name, member count, summed online-pilot count, and a rally/
current-location marker. All data comes from `GroupNodeData`, computed once in
`deriveCollapsedView`, not read live from any store.

## State: `storedSettings.settingsGroups` (per map, localStorage)

`MapGroupsSettings = { collapsedGroups: string[]; groupPositions: Record<string, {x,y}> }`, added
to `MapUserSettings` (`mapRootProvider/types.ts`), migration `to_11.ts` (`STORED_SETTINGS_VERSION`
bumped to 11), following `to_7.ts`'s (the beautify-settings migration) exact convention: defaults
the key in for a blob that predates it, round-trips a blob that already has it.

## Flag: `WANDERER_MAP_GROUPS`

Plumbed exactly like `WANDERER_MAP_BEAUTIFIER`:
`config/runtime.exs` (`map_groups` var, `config :wanderer_app, map_groups: ...`) →
`lib/wanderer_app/env.ex` (`WandererApp.Env.map_groups?/0`) →
`lib/wanderer_app_web/live/map/event_handlers/map_core_event_handler.ex` (adds
`"groups_enabled"` to the client init `options` payload) →
`assets/js/hooks/Mapper/types/options.ts` (`MapOptions.groups_enabled?: StringBoolean`) →
`Map.tsx`'s `MapComp` (`useMapRootSelector(['options'], d => d.options.groups_enabled === 'true')`,
threaded into `useMapGroups({ enabled })`) and `useContextMenuSystemItems.tsx`/`ContextMenuRoot`
(same `options.groups_enabled === 'true'` check gating their menu items).
`infra/docker-compose.yml`'s `environment:` list and `infra/.env.example` both have
`WANDERER_MAP_GROUPS: ${WANDERER_MAP_GROUPS:-false}` / `WANDERER_MAP_GROUPS=false` next to the
beautifier/tidy-insert entries. Flag off: `deriveCollapsedView` always takes its zero-collapsed-
groups fast path (identity pass-through), `ContextMenuRoot`'s collapse items don't render, and the
per-system "Collapse region/chain" menu item doesn't render - proven by a flag-off test, not
assumed (see below).

## Collapse / beautify composition

**Decision**: beautify always solves the FULL, uncollapsed system graph; the collapse transform
never changes what beautify sees. This was not a design choice that needed new code - `useBeautify.ts`
(untouched; owned by the concurrent layout-worker session) reads `systems`/`connections` directly
from `useMapRootState().data` (`MapRootData`, the real, uncollapsed values), never from anything
`deriveCollapsedView`-derived, and `collapsedGroupKeys`/`groupPositions` are mirrored INTO
`MapRootData` for `useMapGroups` to select from, never read FROM it by anything beautify-related.
Proven from the outside (not by reading the source and assuming): `beautifyGroupsComposition.test.tsx`
mounts the real `useBeautify()` hook twice, once with a region collapsed and once fully expanded,
and asserts its solve input (`runBeautify`'s captured `nodes`/`edges` arguments, mocked) is
byte-identical both times.

## Three defects found and fixed in review (reviewed by Main, not self-caught)

1. **The first drag of any never-before-dragged group moved the tile but not its members.**
   `useMapGroups.ts`'s drag-stop resolved the group's pre-drag position as
   `committedGroupPositions[key] ?? newPosition` - for a group with no committed entry yet (the
   common case: it has never been dragged, its rendered position came from
   `deriveCollapsedView`'s centroid fallback), this made `newPosition` its own fallback, so the
   delta was always exactly `{0,0}` and the bulk update silently wrote every member's CURRENT
   (unmoved) position - members didn't follow, and expanding put the group back where it was
   collapsed, the precise failure the code's own comment said it existed to prevent. Fixed by
   extracting `resolveGroupPosition(group, nodes, groupPositions)` out of `deriveCollapsedView.ts`
   (exported) and using it from BOTH the view and the drag-stop delta calculation, so they cannot
   drift. Test: `useMapGroups.test.tsx` "FIX 1" - drags a group with an empty `groupPositions`,
   asserts the bulk payload offsets every member by the real (non-zero) delta, and that the
   persisted committed position matches the actual drop point.
2. **A rubber-band selection containing a group tile sent a synthetic `group:...` id to the
   server** via `OutCommand.updateSystemPositions`. Fixed by `useMapGroups.ts`'s new
   `translateSelectionNodes(selectedNodes)`: expands each group in the selection into its real
   members, offset by that group's own delta (reusing `resolveGroupPosition`/the same shared
   `computeGroupMoveEntries` helper fix 1 uses), applies the matching `setNodes`/
   `settingsGroupsUpdate` side effects once, and returns ONLY real system entries - never a
   `group:` id - for `Map.tsx`'s `handleSelectionDragStop` to send. Test: `useMapGroups.test.tsx`
   "FIX 2" - a selection containing one group tile and one real system, asserting zero `group:`
   ids in the output and the correct per-member delta.
3. **`handleSelectionChange` reported group ids as selected `systems`**, which is what made
   `beautify scope: 'selection'` with a collapsed group selected try to solve an unresolvable
   synthetic id, and fed the same id to the selection context menu and anything else downstream of
   `onSelectionChange`. Fixed at the source: `useMapGroups.ts`'s new
   `expandSelectionSystemIds(ids)` expands any `group:` id into its real member system ids before
   `Map.tsx`'s `handleSelectionChange` ever calls `onSelectionChange` - selecting a region tile
   now means "its member systems are selected" to every downstream consumer, exactly what a user
   means by selecting it. Tests: `useMapGroups.test.tsx` "FIX 3" (the expansion itself) and
   `beautifyGroupsComposition.test.tsx` "FIX 3" (end-to-end: `MapRootData.selectedSystems` holding
   expanded member ids - what `handleSelectionChange` now actually produces - makes `beautify
   scope: 'selection'` solve the real member systems, not zero).

**Still a remaining, separate gap** (not one of the three above, not fixed this round):
`MapWrapper.tsx`'s `handleDeleteSelected` reads ReactFlow's own `getNodes()` directly (the
collapsed VIEW, not `MapRootData.selectedSystems`), so a selected group tile would still reach it
as a node whose `data` has no `locked`/`id` field (`GroupNodeData`'s shape, not
`SolarSystemRawType`'s) - `!x.data.locked` is vacuously `true` for it, and `x.data.id` is
`undefined`. Delete-selected while a group tile is selected is not proven safe or unsafe here;
flagged, not silently left unexplained.

## Verification

`cd assets && npx jest --runInBand`: 70/70 tests pass across 14/15 suites. `cd assets && npx tsc
--noEmit`: no new errors beyond the 2 confirmed pre-existing ones. All group tests
(`mapGroups.test.tsx`, `groups/__tests__/*`, `hooks/__tests__/useMapGroups.test.tsx`,
`hooks/__tests__/beautifyGroupsComposition.test.tsx`) run 3x consecutively, deterministic each
time.

### `migrations/list/to_6.test.ts` - investigated, confirmed NOT caused by this feature

The one failing suite throws `TypeError: Cannot read properties of undefined (reading 'routes')`
at `MapRootProvider.tsx`'s module-level `createContext()` default value
(`DEFAULT_ROUTES_BY_SETTINGS.routes` - `DEFAULT_ROUTES_BY_SETTINGS` is `undefined`), via a genuine
CJS circular import: `to_6.test.ts` -> `to_5.ts` -> `mapRootProvider/constants.ts` ->
`mapInterface/constants.tsx` -> (widgets/ui-kit chain) -> `mapRootProvider/index.ts` ->
`MapRootProvider.tsx` -> back into `mapRootProvider/constants.ts`, which is still mid-evaluation
the second time around, so its `DEFAULT_ROUTES_BY_SETTINGS` export is not yet populated.
`DEFAULT_MAP_GROUPS_SETTINGS` (this feature's new export in the same file) is NOT part of this
cycle - verified, not assumed: `git stash` (fully unmodified tree) reproduces the IDENTICAL
error, same message, same property, same import chain, only the line numbers differ (200 vs 236
in `MapRootProvider.tsx`, 17 vs 19 in `constants.ts`) because of unrelated lines added elsewhere
in those files. This is the same pre-existing failure already documented in
`docs/chewy/map-perf-findings.md` from the prior round's investigation - confirmed again here
independently, with fresh evidence, because a sibling session raised the question.

### A prerequisite fix this round needed

`assets/__mocks__/use-local-storage-state.ts` (the global Jest manual mock for this ESM-only
package, added in the earlier render-perf round) was a plain in-memory `useState` that ignored
`localStorage` entirely - correct at the time ("nothing in the test suite asserts on persisted
localStorage content surviving a reload" was true then). This feature's tests need to seed
`localStorage` before mount and assert the seeded value is read back (collapse state surviving a
remount, migrating an old stored blob), so the mock now actually reads/writes the real
`localStorage` (jsdom provides a real, synchronous implementation) - a strictly more accurate
stand-in for the real package, benefiting any future test with the same need, not just this one.
