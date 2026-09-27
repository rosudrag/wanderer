defmodule WandererApp.GroupMapAccessGrantSyncTest do
  @moduledoc """
  Proves the headline Phase 1 behavior end-to-end through the real
  `WandererApp.Api.GroupMembership`/`WandererApp.Api.GroupMapAccessGrant`
  write paths (never calling `WandererApp.Identity.MapAclSync` directly):
  a user joining a manual group gains an `AccessListMember` row with the
  granted role; leaving removes exactly that row; a hand-added
  `AccessListMember` row for the same character is never touched by
  either; and `WANDERER_GROUP_MAP_SYNC` off means no rows are written at
  all. See docs/chewy/corp-suite-plan.md §2.5, §9 Phase 1.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{
    AccessList,
    AccessListMember,
    Group,
    GroupMapAccessGrant,
    GroupMapSyncedMember,
    GroupMembership
  }

  setup do
    Application.put_env(:wanderer_app, :group_map_sync_enabled, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :group_map_sync_enabled)
    end)

    user = create_user()
    character = create_character(%{user_id: user.id, name: "Grant Test Character"})

    {:ok, group} =
      Group.create(%{name: "FCs #{System.unique_integer([:positive])}", kind: :manual})

    {:ok, access_list} =
      AccessList.create(%{name: "Test Map ACL #{System.unique_integer([:positive])}"},
        authorize?: false
      )

    {:ok, grant} =
      GroupMapAccessGrant.create(
        %{group_id: group.id, access_list_id: access_list.id, role: :manager},
        authorize?: false
      )

    %{user: user, character: character, group: group, access_list: access_list, grant: grant}
  end

  test "joining a manual group adds an AccessListMember row with the granted role",
       %{
         user: user,
         character: character,
         access_list: access_list
       } = ctx do
    assert {:ok, []} =
             AccessListMember.read_by_access_list(%{access_list_id: access_list.id},
               authorize?: false
             )

    {:ok, _membership} =
      GroupMembership.create(%{
        group_id: ctx.group.id,
        user_id: user.id,
        source: :manual_grant,
        status: :active
      })

    assert {:ok, [member]} =
             AccessListMember.read_by_access_list(%{access_list_id: access_list.id},
               authorize?: false
             )

    assert member.eve_character_id == character.eve_id
    assert member.role == :manager

    assert {:ok, _shadow} =
             GroupMapSyncedMember.by_access_list_member(member.id, authorize?: false)
  end

  test "leaving the group removes only the synced row, never a hand-added one", ctx do
    %{user: user, character: character, access_list: access_list, group: group} = ctx

    # A different, unrelated, hand-added ACL member -- never touched.
    {:ok, hand_added} =
      AccessListMember.create(
        %{
          access_list_id: access_list.id,
          name: "Hand-added viewer",
          eve_character_id: "999999999",
          role: :viewer
        },
        authorize?: false
      )

    {:ok, membership} =
      GroupMembership.create(%{
        group_id: group.id,
        user_id: user.id,
        source: :manual_grant,
        status: :active
      })

    assert {:ok, [_synced, _hand_added]} =
             AccessListMember.read_by_access_list(%{access_list_id: access_list.id},
               authorize?: false
             )

    :ok = GroupMembership.destroy(membership)

    assert {:ok, [remaining]} =
             AccessListMember.read_by_access_list(%{access_list_id: access_list.id},
               authorize?: false
             )

    assert remaining.id == hand_added.id
    assert remaining.eve_character_id == "999999999"

    refute Enum.any?(
             AccessListMember.read_by_access_list!(%{access_list_id: access_list.id},
               authorize?: false
             ),
             &(&1.eve_character_id == character.eve_id)
           )
  end

  test "a hand-added ACL member for the same character is never claimed or deleted by sync",
       ctx do
    %{user: user, character: character, access_list: access_list, group: group} = ctx

    {:ok, hand_added} =
      AccessListMember.create(
        %{
          access_list_id: access_list.id,
          name: "Hand-added, same character",
          eve_character_id: character.eve_id,
          role: :viewer
        },
        authorize?: false
      )

    {:ok, membership} =
      GroupMembership.create(%{
        group_id: group.id,
        user_id: user.id,
        source: :manual_grant,
        status: :active
      })

    # Sync found the identity slot already occupied by a hand-added row and
    # left it alone -- still exactly one member row, still :viewer (not
    # overwritten to the grant's :manager role), and no shadow row exists
    # for it.
    assert {:ok, [only_member]} =
             AccessListMember.read_by_access_list(%{access_list_id: access_list.id},
               authorize?: false
             )

    assert only_member.id == hand_added.id
    assert only_member.role == :viewer

    assert {:error, _} =
             GroupMapSyncedMember.by_access_list_member(hand_added.id, authorize?: false)

    :ok = GroupMembership.destroy(membership)

    # Leaving must not delete the hand-added row either -- it was never
    # sync's to remove.
    assert {:ok, [still_there]} =
             AccessListMember.read_by_access_list(%{access_list_id: access_list.id},
               authorize?: false
             )

    assert still_there.id == hand_added.id
  end

  test "with WANDERER_GROUP_MAP_SYNC off, joining/leaving writes no AccessListMember rows", ctx do
    %{user: user, access_list: access_list, group: group} = ctx

    Application.put_env(:wanderer_app, :group_map_sync_enabled, false)

    {:ok, membership} =
      GroupMembership.create(%{
        group_id: group.id,
        user_id: user.id,
        source: :manual_grant,
        status: :active
      })

    assert {:ok, []} =
             AccessListMember.read_by_access_list(%{access_list_id: access_list.id},
               authorize?: false
             )

    :ok = GroupMembership.destroy(membership)

    assert {:ok, []} =
             AccessListMember.read_by_access_list(%{access_list_id: access_list.id},
               authorize?: false
             )

    assert {:ok, []} = GroupMapSyncedMember.by_grant(ctx.grant.id, authorize?: false)
  end
end
