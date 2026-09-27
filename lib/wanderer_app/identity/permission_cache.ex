defmodule WandererApp.Identity.PermissionCache do
  @moduledoc """
  Answers "does this user hold permission X via any active group
  membership" — a direct read of the `GroupMembership`/`GroupPermission`
  grant tables, no TTL cache needed: it's invalidated by row changes, not
  time. See docs/chewy/corp-suite-plan.md §2.7.
  """

  alias WandererApp.Api.{GroupMembership, GroupPermission}

  @doc "true if `user_id` holds `permission` via any active group membership."
  def has_permission?(user_id, permission) when is_binary(user_id) and is_atom(permission) do
    case GroupMembership.by_user(user_id) do
      {:ok, memberships} ->
        memberships
        |> Enum.filter(&(&1.status == :active))
        |> Enum.any?(fn membership -> group_has_permission?(membership.group_id, permission) end)

      _ ->
        false
    end
  end

  @doc """
  true if `current_user_role` is the existing upstream `:admin` concept
  **or** `user_id` holds the `:corp_suite_admin` permission via a
  group. The one check every `/corp/*` admin-only page/panel/link
  should call -- was previously three separately-maintained copies of
  `current_user_role == :admin and not has_permission?(...)` across
  `WandererAppWeb.GroupMapGrantsLive`, `WandererAppWeb.CorpRosterLive`'s
  director-token panel, and `WandererAppWeb.CorpShellLive`'s "Map
  access grants" link -- the last two of which had drifted out of sync
  with the first (a `:corp_suite_admin` user could reach a page but
  never see the link to it). See docs/chewy/corp-suite-plan.md §9
  Phase 3.
  """
  def corp_admin?(current_user_role, user_id) do
    current_user_role == :admin or has_permission?(user_id, :corp_suite_admin)
  end

  defp group_has_permission?(group_id, permission) do
    case GroupPermission.by_group(group_id) do
      {:ok, perms} -> Enum.any?(perms, &(&1.permission == permission))
      _ -> false
    end
  end
end
