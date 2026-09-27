defmodule WandererApp.Identity.MapAclSync do
  @moduledoc """
  Materializes `WandererApp.Api.GroupMapAccessGrant` rows into ordinary
  `WandererApp.Api.AccessListMember` rows through that resource's existing,
  unmodified `:create`/`:update_role`/`:destroy` code-interface actions
  (`lib/wanderer_app/api/access_list_member.ex:57-69`), with `authorize?:
  false` — an internal/system write, not a session-actor write, so it
  intentionally skips policy evaluation entirely rather than impersonating a
  user. Every read of `AccessListMember`/`AccessList` in this module also
  passes `authorize?: false` explicitly, and uses the purpose-built
  `read_by_access_list` action rather than a bare actor-less `read` — see
  `AGENTS.md`'s note on `MapConnection`'s actor-filtered primary read
  silently returning 0 rows for the exact failure mode this avoids.

  `WandererApp.Api.GroupMapSyncedMember` is the ownership ledger: every
  `AccessListMember` row this module creates gets exactly one shadow row.
  Removal ever only walks shadow rows — a hand-added `AccessListMember` has
  no shadow row and is therefore structurally unreachable from this module.

  Two sync strategies, chosen per `WandererApp.Api.Group` via its
  `WandererApp.Api.GroupAutoRule` rows (`strategy/1`):

    * **`:affiliation`** — a group whose only auto-rules are `:state`,
      `:corporation_id`, or `:alliance_id`. One `AccessListMember` row per
      matching corp/alliance ID, keyed by `eve_corporation_id`/
      `eve_alliance_id` — no per-character enumeration. A `:state` rule
      matching `"member"` expands to every `owned_corporations_v1` row's
      corp/alliance ID (that is the literal definition of `:member`, see
      `WandererApp.Identity.StateEngine`).
    * **`:manual`** — every other group (no auto-rules, or any auto-rule
      that isn't one of the three above, e.g. `:esi_director_role`,
      `:title`). One `AccessListMember` row per active member's
      character(s), keyed by `eve_character_id`.

  Trigger points (all event-driven, no polling): `WandererApp.Api.
  GroupMembership`'s own `:create`/`:update`/`:destroy` actions
  (`WandererApp.Identity.Changes.SyncGroupMembership`) and
  `WandererApp.Api.GroupMapAccessGrant`'s own `:create`/`:update_role`/
  `:destroy` actions (`WandererApp.Identity.Changes.SyncMapAccessGrant`).
  Both are `change`s on resources this suite owns, so
  `WandererApp.Identity.StateEngine`'s existing auto-rule reconciliation
  (`reconcile_auto_membership!/3`, which already calls
  `GroupMembership.create/1` and `.destroy/1`) drives this module for free,
  with zero edits to `state_engine.ex`. See
  docs/chewy/corp-suite-plan.md §2.5, §9 Phase 1.

  Every public function here is a no-op, and writes nothing, when
  `WandererApp.Env.group_map_sync_enabled?/0` is false — the single choke
  point every trigger path funnels through, so "flag off" is enforced once,
  not per call site.
  """

  require Logger

  alias WandererApp.Api.{
    AccessListMember,
    Character,
    GroupAutoRule,
    GroupMapAccessGrant,
    GroupMapSyncedMember,
    GroupMembership,
    OwnedCorporation,
    User
  }

  @doc """
  (Re-)syncs a single grant against its group's current members/affiliation
  targets. Called on grant create and on grant role update — idempotent,
  safe to call repeatedly.
  """
  def sync_grant!(%GroupMapAccessGrant{} = grant) do
    if enabled?() do
      case strategy(grant.group_id) do
        :affiliation -> sync_affiliation_grant!(grant)
        :manual -> sync_manual_grant!(grant)
      end
    end

    :ok
  end

  @doc """
  Removes every `AccessListMember` row this module created for `grant`
  (via its `GroupMapSyncedMember` shadow rows), never a hand-added row.
  Called when a grant is destroyed.
  """
  def remove_grant!(%GroupMapAccessGrant{id: grant_id}) do
    if enabled?() do
      grant_id
      |> synced_members_for_grant()
      |> Enum.each(&remove_synced_member!/1)
    end

    :ok
  end

  @doc """
  A `GroupMembership` became active (created active, or transitioned into
  `:active`). Only `:manual`-strategy grants act on individual membership
  changes — `:affiliation`-strategy grants are keyed by corp/alliance ID,
  not by membership row, and are already fully synced by `sync_grant!/1`.
  """
  def membership_added!(%GroupMembership{status: :active} = membership) do
    if enabled?() do
      membership.group_id
      |> manual_grants_for_group()
      |> Enum.each(&add_member_to_grant!(&1, membership.user_id))
    end

    :ok
  end

  def membership_added!(%GroupMembership{}), do: :ok

  @doc """
  A `GroupMembership` was destroyed, or transitioned away from `:active`.
  Removes only the shadow-tracked rows belonging to this specific user's
  characters, for this specific group's `:manual`-strategy grants — every
  other member's row, and every hand-added row, is untouched.
  """
  def membership_removed!(%GroupMembership{group_id: group_id, user_id: user_id}) do
    if enabled?() do
      group_id
      |> manual_grants_for_group()
      |> Enum.each(&remove_member_from_grant!(&1, user_id))
    end

    :ok
  end

  defp enabled?, do: WandererApp.Env.group_map_sync_enabled?()

  # -- strategy -----------------------------------------------------------

  defp strategy(group_id) do
    {:ok, rules} = GroupAutoRule.by_group(group_id, authorize?: false)

    if rules != [] and
         Enum.all?(rules, &(&1.match_kind in [:state, :corporation_id, :alliance_id])) do
      :affiliation
    else
      :manual
    end
  end

  defp manual_grants_for_group(group_id) do
    {:ok, grants} = GroupMapAccessGrant.by_group(group_id, authorize?: false)
    Enum.filter(grants, fn grant -> strategy(grant.group_id) == :manual end)
  end

  # -- affiliation strategy -------------------------------------------------

  defp sync_affiliation_grant!(grant) do
    {:ok, rules} = GroupAutoRule.by_group(grant.group_id, authorize?: false)
    targets = affiliation_targets(rules)

    Enum.each(targets, &upsert_affiliation_member!(grant, &1))

    target_keys = MapSet.new(targets)

    grant.id
    |> synced_members_for_grant()
    |> Enum.each(fn shadow ->
      case fetch_member(shadow.access_list_member_id) do
        {:ok, member} ->
          unless member_target_key(member) in target_keys, do: remove_synced_member!(shadow)

        :error ->
          remove_synced_member!(shadow)
      end
    end)
  end

  defp affiliation_targets(rules) do
    rules |> Enum.flat_map(&affiliation_targets_for_rule/1) |> Enum.uniq()
  end

  defp affiliation_targets_for_rule(%{match_kind: :corporation_id, match_value: value}),
    do: [{:corporation_id, value}]

  defp affiliation_targets_for_rule(%{match_kind: :alliance_id, match_value: value}),
    do: [{:alliance_id, value}]

  defp affiliation_targets_for_rule(%{match_kind: :state, match_value: "member"}) do
    {:ok, owned} = OwnedCorporation.read(authorize?: false)

    Enum.flat_map(owned, fn corp ->
      [{:corporation_id, to_string(corp.eve_corporation_id)}] ++
        if corp.alliance_id, do: [{:alliance_id, to_string(corp.alliance_id)}], else: []
    end)
  end

  # :blue/:applicant/:guest states, and any other rule shape, carry no
  # corp/alliance ID of their own -- not representable by this strategy.
  defp affiliation_targets_for_rule(_other), do: []

  defp upsert_affiliation_member!(grant, {:corporation_id, id} = target),
    do: upsert_member!(grant, %{eve_corporation_id: id}, target)

  defp upsert_affiliation_member!(grant, {:alliance_id, id} = target),
    do: upsert_member!(grant, %{eve_alliance_id: id}, target)

  defp member_target_key(%{eve_corporation_id: id}) when not is_nil(id),
    do: {:corporation_id, id}

  defp member_target_key(%{eve_alliance_id: id}) when not is_nil(id), do: {:alliance_id, id}
  defp member_target_key(_member), do: nil

  # -- manual strategy ------------------------------------------------------

  defp sync_manual_grant!(grant) do
    {:ok, memberships} = GroupMembership.active_by_group(grant.group_id, authorize?: false)
    Enum.each(memberships, &add_member_to_grant!(grant, &1.user_id))
  end

  defp add_member_to_grant!(grant, user_id) do
    user = User.by_id!(user_id, authorize?: false)
    %{characters: characters} = Ash.load!(user, :characters, authorize?: false)

    Enum.each(characters, fn character ->
      upsert_member!(
        grant,
        %{eve_character_id: character.eve_id},
        {:character_id, character.eve_id}
      )
    end)
  end

  defp remove_member_from_grant!(grant, user_id) do
    user = User.by_id!(user_id, authorize?: false)
    %{characters: characters} = Ash.load!(user, :characters, authorize?: false)
    character_eve_ids = MapSet.new(characters, & &1.eve_id)

    grant.id
    |> synced_members_for_grant()
    |> Enum.each(fn shadow ->
      case fetch_member(shadow.access_list_member_id) do
        {:ok, %{eve_character_id: id}} when is_binary(id) ->
          if id in character_eve_ids, do: remove_synced_member!(shadow)

        _other ->
          :ok
      end
    end)
  end

  # -- shared upsert/remove primitives --------------------------------------

  defp upsert_member!(grant, target_attrs, _target) do
    case find_existing_member(grant.access_list_id, target_attrs) do
      nil ->
        create_synced_member!(grant, target_attrs)
        :ok

      member ->
        reconcile_existing_member!(grant, member)
        :ok
    end
  end

  defp reconcile_existing_member!(grant, member) do
    case synced_owner_grant_id(member.id) do
      nil ->
        # A hand-added row already occupies this identity slot. Sync's
        # goal (this target has the granted role) may not literally be
        # met if the hand-added role differs, but claiming it would risk
        # deleting an admin's own row on a later group-leave -- never
        # touch a row this module didn't create.
        :ok

      grant_id when grant_id == grant.id ->
        maybe_update_role!(member, grant.role)

      _other_grant_id ->
        # Owned by a different grant (e.g. two groups targeting the same
        # ACL + same corp/alliance). Leave it to its owner.
        :ok
    end
  end

  defp maybe_update_role!(%{role: role}, role), do: :ok

  defp maybe_update_role!(member, role),
    do: AccessListMember.update_role(member, %{role: role}, authorize?: false)

  defp create_synced_member!(grant, target_attrs) do
    {:ok, member} =
      target_attrs
      |> Map.merge(%{
        access_list_id: grant.access_list_id,
        name: member_name(target_attrs),
        role: grant.role
      })
      |> AccessListMember.create(authorize?: false)

    {:ok, _shadow} =
      GroupMapSyncedMember.create(
        %{group_map_access_grant_id: grant.id, access_list_member_id: member.id},
        authorize?: false
      )

    member
  end

  defp remove_synced_member!(%GroupMapSyncedMember{} = shadow) do
    case fetch_member(shadow.access_list_member_id) do
      {:ok, member} -> AccessListMember.destroy(member, authorize?: false)
      :error -> :ok
    end

    case GroupMapSyncedMember.by_id(shadow.id, authorize?: false) do
      {:ok, still_there} -> GroupMapSyncedMember.destroy(still_there, authorize?: false)
      _not_found -> :ok
    end

    :ok
  end

  defp synced_members_for_grant(grant_id) do
    {:ok, synced} = GroupMapSyncedMember.by_grant(grant_id, authorize?: false)
    synced
  end

  defp synced_owner_grant_id(access_list_member_id) do
    case GroupMapSyncedMember.by_access_list_member(access_list_member_id, authorize?: false) do
      {:ok, %{group_map_access_grant_id: id}} -> id
      _not_found -> nil
    end
  end

  defp fetch_member(access_list_member_id) do
    case AccessListMember.by_id(access_list_member_id, authorize?: false) do
      {:ok, member} -> {:ok, member}
      _not_found -> :error
    end
  end

  defp find_existing_member(access_list_id, %{eve_character_id: id}),
    do: find_member_by(access_list_id, &(&1.eve_character_id == id))

  defp find_existing_member(access_list_id, %{eve_corporation_id: id}),
    do: find_member_by(access_list_id, &(&1.eve_corporation_id == id))

  defp find_existing_member(access_list_id, %{eve_alliance_id: id}),
    do: find_member_by(access_list_id, &(&1.eve_alliance_id == id))

  defp find_member_by(access_list_id, pred) do
    {:ok, members} =
      AccessListMember.read_by_access_list(%{access_list_id: access_list_id}, authorize?: false)

    Enum.find(members, pred)
  end

  defp member_name(%{eve_character_id: id}) do
    case Character.by_eve_id(id, authorize?: false) do
      {:ok, character} -> character.name
      _not_found -> "Character #{id}"
    end
  end

  defp member_name(%{eve_corporation_id: id}) do
    case OwnedCorporation.by_corporation_id(String.to_integer(id), authorize?: false) do
      {:ok, corp} -> corp.name
      _not_found -> "Corporation #{id}"
    end
  end

  defp member_name(%{eve_alliance_id: id}) do
    case OwnedCorporation.read(authorize?: false) do
      {:ok, corps} ->
        case Enum.find(corps, &(not is_nil(&1.alliance_id) and to_string(&1.alliance_id) == id)) do
          %{alliance_name: name} when is_binary(name) -> name
          _no_match -> "Alliance #{id}"
        end

      _error ->
        "Alliance #{id}"
    end
  end
end
