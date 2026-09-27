defmodule WandererApp.Identity.BootstrapAdmin do
  @moduledoc """
  Bootstrap the identity suite's first admin by character name.

  Idempotent: on every boot/login, looks up the configured bootstrap admin
  character (if set), ensures a Corp Suite Administrators group exists with
  the `:corp_suite_admin` permission, and adds the user who owns that
  character to the group. Safe to call repeatedly.

  See docs/chewy/corp-suite-plan.md §9, Phase 0 bootstrap and AGENTS.md rule 6
  (env var default inert behaviour).
  """

  require Logger
  require Ash.Query
  alias WandererApp.Api.{Character, User, Group, GroupMembership, GroupPermission}

  @bootstrap_admin_permission :corp_suite_admin
  @bootstrap_group_name "Corp Suite Administrators"

  @doc """
  Runs the bootstrap if `WANDERER_BOOTSTRAP_ADMIN_CHARACTER` is set.
  Idempotent: safe to call on every boot and login.

  Returns `:ok` if bootstrap succeeded or was skipped, `{:error, reason}` if
  the named character doesn't exist. Does not raise.
  """
  def maybe_bootstrap() do
    case WandererApp.Env.bootstrap_admin_character() do
      nil ->
        :ok

      character_name ->
        run(character_name)
    end
  end

  @doc false
  def run(character_name) when is_binary(character_name) do
    with {:ok, character} <- Character.by_name(character_name, authorize?: false),
         true <- not is_nil(character.user_id),
         {:ok, user} <- User.by_id(character.user_id, authorize?: false) do
      bootstrap_user(user)
    else
      {:error, reason} ->
        Logger.warning(
          "[BootstrapAdmin] Bootstrap character '#{character_name}' not found or " <>
            "not linked to a user: #{inspect(reason)}"
        )

        {:error, reason}

      false ->
        Logger.warning(
          "[BootstrapAdmin] Bootstrap character '#{character_name}' exists but has no user_id"
        )

        {:error, :no_user_linked}
    end
  end

  defp bootstrap_user(user) do
    with {:ok, group} <- ensure_admin_group(),
         {:ok, _membership} <- ensure_user_in_group(user, group) do
      Logger.info(
        "[BootstrapAdmin] User #{user.id} (#{user.name}) is now in the #{@bootstrap_group_name} group"
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("[BootstrapAdmin] Failed to bootstrap user: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Ensures the Corp Suite Administrators group exists with the
  # corp_suite_admin permission.
  defp ensure_admin_group() do
    case Ash.read(Group, authorize?: false)
         |> Ash.Query.filter(name == ^@bootstrap_group_name)
         |> Ash.read_one(authorize?: false) do
      {:ok, group} when is_struct(group, Group) ->
        # Group exists; ensure permission exists
        ensure_permission(group)
        {:ok, group}

      {:ok, nil} ->
        # Create the group
        with {:ok, group} <-
               Group.create(
                 %{name: @bootstrap_group_name, kind: :manual},
                 authorize?: false
               ),
             {:ok, _} <- ensure_permission(group) do
          Logger.info("[BootstrapAdmin] Created group #{@bootstrap_group_name}")
          {:ok, group}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Ensures the permission exists on the group (idempotent).
  defp ensure_permission(group) do
    case Ash.read(GroupPermission, authorize?: false)
         |> Ash.Query.filter(group_id == ^group.id and permission == ^@bootstrap_admin_permission)
         |> Ash.read_one(authorize?: false) do
      {:ok, perm} when is_struct(perm, GroupPermission) ->
        # Permission already exists
        {:ok, group}

      {:ok, nil} ->
        # Create the permission
        with {:ok, _} <-
               GroupPermission.create(
                 %{group_id: group.id, permission: @bootstrap_admin_permission},
                 authorize?: false
               ) do
          Logger.info(
            "[BootstrapAdmin] Ensured #{@bootstrap_group_name} has :#{@bootstrap_admin_permission} permission"
          )

          {:ok, group}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Adds the user to the group if not already a member (idempotent).
  defp ensure_user_in_group(user, group) do
    case Ash.read(GroupMembership, authorize?: false)
         |> Ash.Query.filter(group_id == ^group.id and user_id == ^user.id)
         |> Ash.read_one(authorize?: false) do
      {:ok, membership} when is_struct(membership, GroupMembership) ->
        # Already a member
        {:ok, membership}

      {:ok, nil} ->
        # Add user to group
        with {:ok, membership} <-
               GroupMembership.create(
                 %{
                   group_id: group.id,
                   user_id: user.id,
                   source: :manual_grant,
                   status: :active
                 },
                 authorize?: false
               ) do
          Logger.info(
            "[BootstrapAdmin] Added user #{user.id} to #{@bootstrap_group_name} group"
          )

          {:ok, membership}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
