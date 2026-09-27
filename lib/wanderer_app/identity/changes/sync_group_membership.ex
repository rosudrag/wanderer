defmodule WandererApp.Identity.Changes.SyncGroupMembership do
  @moduledoc """
  Attached to `WandererApp.Api.GroupMembership`'s own `:create`/`:update`/
  `:destroy` actions (a resource this suite owns, not an upstream file) so
  `WandererApp.Identity.MapAclSync` fires on every membership change
  regardless of call site — including `WandererApp.Identity.StateEngine`'s
  existing `reconcile_auto_membership!/3`, with zero edits to
  `state_engine.ex`. See docs/chewy/corp-suite-plan.md §2.5, §9 Phase 1.
  """

  use Ash.Resource.Change

  alias WandererApp.Identity.MapAclSync

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      handle(changeset, result)
      {:ok, result}
    end)
  end

  defp handle(%{action: %{type: :create}}, result) do
    MapAclSync.membership_added!(result)
  end

  defp handle(%{action: %{type: :destroy}, data: data}, _result) do
    MapAclSync.membership_removed!(data)
  end

  defp handle(
         %{action: %{type: :update}, data: %{status: old_status}},
         %{status: new_status} = result
       ) do
    cond do
      old_status != :active and new_status == :active ->
        MapAclSync.membership_added!(result)

      old_status == :active and new_status != :active ->
        MapAclSync.membership_removed!(result)

      true ->
        :ok
    end
  end
end
