defmodule WandererApp.BootstrapAdminTest do
  @moduledoc """
  Proves `WandererApp.Identity.BootstrapAdmin` end-to-end through the real
  `WandererApp.Api.Group`/`GroupPermission`/`GroupMembership` write paths:
  with `WANDERER_BOOTSTRAP_ADMIN_CHARACTER` unset, `maybe_bootstrap/0` is a
  no-op; with it set to a seeded character's name, a first run creates
  exactly one `Group` (named "Corp Suite Administrators"), one
  `GroupPermission` (`:corp_suite_admin`) and one `GroupMembership` row for
  the character's owning user, a second run changes no row counts, and the
  user ends up holding `:corp_suite_admin` per
  `WandererApp.Identity.PermissionCache`. Also proves a configured name
  that matches no character, or matches a character with no linked user,
  returns `{:error, _}` without raising, and that an unexpected exception
  anywhere underneath `maybe_bootstrap/0` is caught rather than
  propagated — `maybe_bootstrap/0` runs unconditionally on every login
  (`auth_controller.ex`), so any of these must degrade to a logged error,
  never a crash that would break login for everyone, not just the named
  admin.

  See docs/chewy/corp-suite-plan.md §9 Phase 0 bootstrap and
  `lib/wanderer_app/identity/bootstrap_admin.ex`.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{Group, GroupMembership, GroupPermission}
  alias WandererApp.Identity.{BootstrapAdmin, PermissionCache}

  @bootstrap_group_name "Corp Suite Administrators"

  setup do
    on_exit(fn ->
      Application.delete_env(:wanderer_app, :bootstrap_admin_character)
    end)

    :ok
  end

  defp bootstrap_group_row_counts() do
    case Group.by_name(@bootstrap_group_name, authorize?: false) do
      {:ok, group} ->
        {:ok, perms} = GroupPermission.by_group(group.id)
        {:ok, memberships} = GroupMembership.by_group(group.id)
        {1, length(perms), length(memberships)}

      {:error, _not_found} ->
        {0, 0, 0}
    end
  end

  test "with the env var unset, maybe_bootstrap/0 is a no-op and writes nothing" do
    Application.delete_env(:wanderer_app, :bootstrap_admin_character)

    assert :ok = BootstrapAdmin.maybe_bootstrap()
    assert {0, 0, 0} = bootstrap_group_row_counts()
  end

  test "run 1 creates exactly one group/permission/membership row, run 2 is a no-op, and PermissionCache reflects it" do
    user = create_user()
    character = create_character(%{user_id: user.id, name: "Bootstrap Admin Character"})

    Application.put_env(:wanderer_app, :bootstrap_admin_character, character.name)

    assert {0, 0, 0} = bootstrap_group_row_counts()

    assert :ok = BootstrapAdmin.run(character.name)
    assert {1, 1, 1} = bootstrap_group_row_counts()

    assert :ok = BootstrapAdmin.run(character.name)
    assert {1, 1, 1} = bootstrap_group_row_counts()

    assert PermissionCache.has_permission?(user.id, :corp_suite_admin)

    assert :ok = BootstrapAdmin.maybe_bootstrap()
    assert {1, 1, 1} = bootstrap_group_row_counts()
  end

  test "a configured character name that matches nothing returns an error without raising" do
    assert {:error, _reason} = BootstrapAdmin.run("Nobody Named This " <> "#{System.unique_integer([:positive])}")
    assert {0, 0, 0} = bootstrap_group_row_counts()
  end

  test "a configured character with no linked user returns an error without raising" do
    character = create_character(%{name: "Unlinked Bootstrap Character"})
    assert is_nil(character.user_id)

    assert {:error, :no_user_linked} = BootstrapAdmin.run(character.name)
    assert {0, 0, 0} = bootstrap_group_row_counts()
  end

  test "an unexpected exception underneath maybe_bootstrap/0 (e.g. a bad env value) is caught, not raised" do
    # WandererApp.Env.bootstrap_admin_character/0 calls String.trim/1 on
    # whatever is configured; a non-string value raises FunctionClauseError
    # deep inside maybe_bootstrap/0, before `run/1` is ever reached. This is
    # the exact shape of "bad env value" the call site
    # (`auth_controller.ex`, called on every login) must survive.
    Application.put_env(:wanderer_app, :bootstrap_admin_character, 12_345)

    assert {:error, :bootstrap_failed} = BootstrapAdmin.maybe_bootstrap()
    assert {0, 0, 0} = bootstrap_group_row_counts()
  end
end
