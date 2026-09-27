defmodule WandererApp.Identity.Changes.SyncMapAccessGrant do
  @moduledoc """
  Attached to `WandererApp.Api.GroupMapAccessGrant`'s own `:create`/
  `:update_role`/`:destroy` actions so `WandererApp.Identity.MapAclSync`
  fires the moment a grant is created, re-roled, or removed. See
  docs/chewy/corp-suite-plan.md §2.5, §9 Phase 1.

  Destroy specifically must run in `before_action`, not `after_action`:
  `WandererApp.Api.GroupMapSyncedMember`'s `group_map_access_grant_id`
  reference is `on_delete: :delete`, a database-level cascade that fires
  as part of the same DELETE statement the data layer issues -- by the
  time an `after_action` hook runs, the shadow rows `remove_grant!/1`
  needs to find its `AccessListMember` rows are already gone, and those
  member rows leak. `before_action` reads them while the grant row (and
  therefore its shadow rows) still exist.
  """

  use Ash.Resource.Change

  alias WandererApp.Identity.MapAclSync

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.action.type do
      :destroy ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          MapAclSync.remove_grant!(changeset.data)
          changeset
        end)

      _create_or_update ->
        Ash.Changeset.after_action(changeset, fn _changeset, result ->
          MapAclSync.sync_grant!(result)
          {:ok, result}
        end)
    end
  end
end
