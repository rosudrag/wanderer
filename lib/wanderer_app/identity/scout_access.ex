defmodule WandererApp.Identity.ScoutAccess do
  @moduledoc """
  CHEWY PATCH: the `:scout_intel_view` permission and the one tier that
  is allowed to hand it out.

  ## Why this is not just another corp_suite_admin permission

  Every other permission in the suite is grantable by anyone holding
  `:corp_suite_admin`. This one is not: the scout log records where a
  named character was, when, and what it found — it is the fleet's
  operational intel, and the requirement was that only the deployment
  owner decides who reads it.

  So `grant/2` and `revoke/1` are gated on `superadmin?/1`, which is true
  for exactly one user: the one owning the character named by
  `WANDERER_BOOTSTRAP_ADMIN_CHARACTER`. A `:corp_suite_admin` cannot
  grant it, cannot revoke it, and cannot grant it to themselves. With the
  env var unset there is no superadmin and the permission can only be
  granted by direct database access — deliberately, since an unset
  bootstrap character means the deployment has no declared owner.

  The permission itself is an ordinary `WandererApp.Api.GroupPermission`
  row on a managed group, so it composes with the rest of the suite
  (`PermissionCache.has_permission?/2` answers for it like any other) and
  needed no schema change.
  """

  require Logger

  alias WandererApp.Api.{Character, Group, GroupMembership, GroupPermission, User}
  alias WandererApp.Identity.PermissionCache

  @permission :scout_intel_view
  @group_name "Scout Intel Viewers"

  # Backstop only -- grant/revoke invalidate explicitly. See
  # can_view_cached?/1.
  @cache_ttl :timer.minutes(5)

  @doc "The permission atom this module manages."
  def permission, do: @permission

  @doc "Name of the managed group carrying the permission."
  def group_name, do: @group_name

  @doc """
  True for the single user owning `WANDERER_BOOTSTRAP_ADMIN_CHARACTER`.

  Not `corp_admin?/2`: the upstream `:admin` role and `:corp_suite_admin`
  both deliberately fail this check. See the moduledoc.
  """
  def superadmin?(nil), do: false

  def superadmin?(user_id) when is_binary(user_id) do
    case superadmin_user_id() do
      nil -> false
      ^user_id -> true
      _other -> false
    end
  end

  @doc """
  True if the user may read the scout log: the superadmin always, plus
  anyone the superadmin has granted `:scout_intel_view`.
  """
  def can_view?(nil), do: false

  def can_view?(user_id) when is_binary(user_id) do
    superadmin?(user_id) or PermissionCache.has_permission?(user_id, @permission)
  end

  @doc """
  `can_view?/1` behind a short-lived cache, for callers on a hot path.

  `WandererAppWeb.Nav.on_mount/4` runs for EVERY LiveView mount, the map
  canvas included, so deciding whether to draw the sidebar icon must not
  cost two `Ash` reads per mount — that rule is in AGENTS.md and it is why
  no other `/corp` nav entry is permission-gated. Grants and revokes both
  call `invalidate/1`, so the TTL is only a backstop for writes that
  bypassed this module (a direct DB edit); a stale `false` costs one page
  reload, a stale `true` still hits the real check in the LiveView's own
  `mount/3`, which is never cached.
  """
  def can_view_cached?(nil), do: false

  def can_view_cached?(user_id) when is_binary(user_id) do
    case WandererApp.Cache.get(cache_key(user_id)) do
      nil ->
        allowed = can_view?(user_id)
        WandererApp.Cache.put(cache_key(user_id), allowed, ttl: @cache_ttl)
        allowed

      allowed ->
        allowed
    end
  end

  @doc "Drops the `can_view_cached?/1` entry for one user."
  def invalidate(user_id) when is_binary(user_id),
    do: WandererApp.Cache.delete(cache_key(user_id))

  defp cache_key(user_id), do: "scout_access:can_view:#{user_id}"

  @doc """
  Grants `:scout_intel_view` to the user owning `character_name`.

  `granted_by_user_id` must be the superadmin; anything else returns
  `{:error, :forbidden}` without touching the database. Idempotent.
  """
  def grant_by_character_name(character_name, granted_by_user_id)
      when is_binary(character_name) do
    with :ok <- authorize(granted_by_user_id),
         {:ok, user} <- resolve_user(character_name) do
      grant_user(user, granted_by_user_id)
    end
  end

  @doc """
  Revokes `:scout_intel_view` from `user_id` by removing the group
  membership. Superadmin-only. Revoking a user who does not hold it is
  `:ok`.
  """
  def revoke(user_id, revoked_by_user_id) when is_binary(user_id) do
    with :ok <- authorize(revoked_by_user_id),
         {:ok, group} <- ensure_group() do
      result =
        case GroupMembership.by_group_and_user(group.id, user_id, authorize?: false) do
          {:ok, membership} ->
            case GroupMembership.destroy(membership, authorize?: false) do
              :ok -> :ok
              {:ok, _} -> :ok
              {:error, reason} -> {:error, reason}
            end

          {:error, _not_found} ->
            :ok
        end

      if result == :ok do
        # Before logging: the nav gate reads this cache, and a revoked user
        # keeping the icon for five minutes is the whole reason it exists.
        invalidate(user_id)
        Logger.info("[ScoutAccess] Revoked #{@permission} from user #{user_id}")
      end

      result
    end
  end

  @doc """
  Everyone currently holding the permission, as
  `%{user_id:, user_name:, granted_at:}`, oldest grant first.

  Includes the superadmin only if they were explicitly granted it —
  `can_view?/1` lets them in regardless, and listing an implicit grant as
  a revokable row would be a lie.
  """
  def members do
    case ensure_group() do
      {:ok, group} ->
        case GroupMembership.active_by_group(group.id, authorize?: false) do
          {:ok, memberships} ->
            memberships
            |> Enum.map(&describe_member/1)
            |> Enum.sort_by(& &1.granted_at, DateTime)

          _error ->
            []
        end

      _error ->
        []
    end
  end

  @doc """
  The configured superadmin's user id, or nil when
  `WANDERER_BOOTSTRAP_ADMIN_CHARACTER` is unset or names a character that
  has never logged in.
  """
  def superadmin_user_id do
    with character_name when is_binary(character_name) <-
           WandererApp.Env.bootstrap_admin_character(),
         {:ok, character} <- Character.by_name(character_name, authorize?: false) do
      character.user_id
    else
      _ -> nil
    end
  end

  # -------------------------------------------------------------------

  defp authorize(user_id) do
    if superadmin?(user_id), do: :ok, else: {:error, :forbidden}
  end

  defp resolve_user(character_name) do
    trimmed = String.trim(character_name)

    with false <- trimmed == "",
         {:ok, character} <- Character.by_name(trimmed, authorize?: false),
         user_id when is_binary(user_id) <- character.user_id,
         {:ok, user} <- User.by_id(user_id, authorize?: false) do
      {:ok, user}
    else
      true -> {:error, :blank_character_name}
      nil -> {:error, :character_has_no_user}
      {:error, _reason} -> {:error, :character_not_found}
    end
  end

  defp grant_user(user, granted_by_user_id) do
    with {:ok, group} <- ensure_group(),
         {:ok, _membership} <- ensure_member(group, user, granted_by_user_id) do
      invalidate(user.id)
      Logger.info("[ScoutAccess] Granted #{@permission} to user #{user.id} (#{user.name})")
      {:ok, user}
    end
  end

  defp ensure_member(group, user, granted_by_user_id) do
    case GroupMembership.by_group_and_user(group.id, user.id, authorize?: false) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, _not_found} ->
        GroupMembership.create(
          %{
            group_id: group.id,
            user_id: user.id,
            source: :manual_grant,
            status: :active,
            granted_by_user_id: granted_by_user_id
          },
          authorize?: false
        )
    end
  end

  # Same shape as BootstrapAdmin.ensure_admin_group/0, and the same
  # reason for using the purpose-built `get_by` reads rather than an
  # `Ash.read |> Ash.Query.filter` pipeline (which compiles and then
  # raises at runtime).
  defp ensure_group do
    case Group.by_name(@group_name, authorize?: false) do
      {:ok, group} ->
        ensure_permission(group)

      {:error, _not_found} ->
        with {:ok, group} <-
               Group.create(
                 %{
                   name: @group_name,
                   description:
                     "Grants read access to the scout intel log. Managed from /scout/access; " <>
                       "only the bootstrap admin can change its membership.",
                   kind: :manual
                 },
                 authorize?: false
               ),
             {:ok, group} <- ensure_permission(group) do
          Logger.info("[ScoutAccess] Created group #{@group_name}")
          {:ok, group}
        end
    end
  end

  defp ensure_permission(group) do
    case GroupPermission.by_group_and_permission(group.id, @permission, authorize?: false) do
      {:ok, _perm} ->
        {:ok, group}

      {:error, _not_found} ->
        with {:ok, _} <-
               GroupPermission.create(
                 %{group_id: group.id, permission: @permission},
                 authorize?: false
               ) do
          {:ok, group}
        end
    end
  end

  defp describe_member(membership) do
    %{
      user_id: membership.user_id,
      user_name: user_name(membership.user_id),
      granted_at: membership.inserted_at
    }
  end

  defp user_name(user_id) do
    case User.by_id(user_id, authorize?: false) do
      {:ok, user} -> user.name
      _ -> nil
    end
  end
end
