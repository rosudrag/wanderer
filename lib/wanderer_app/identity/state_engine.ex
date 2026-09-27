defmodule WandererApp.Identity.StateEngine do
  @moduledoc """
  Computes and persists a `WandererApp.Api.User`'s alliance `state`
  (`:member`/`:blue`/`:applicant`/`:guest`) from their designated **main**
  character only — never from any linked alt — and reconciles
  `:auto_rule`-sourced `GroupMembership` rows against every
  `GroupAutoRule` after each recompute. See
  docs/chewy/corp-suite-plan.md §2.2/§2.3 for the full design and the
  security rationale for the main-only rule.
  """

  require Logger

  alias WandererApp.Api.{
    Character,
    GroupAutoRule,
    GroupMembership,
    OwnedCorporation,
    StandingGrant,
    User,
    UserIdentity
  }

  alias WandererApp.Identity.{Audit, DirectorCheck}

  @doc """
  Idempotently recomputes and persists `user`'s state, then reconciles
  auto-rule group membership against the new state. Safe to call on every
  login, on a main-character change, and from the daily sweep
  (`recompute_all/0`) — always derives from scratch, never trusts a
  previous value.
  """
  def recompute!(%User{} = user) do
    identity = fetch_or_create_identity!(user.id)

    new_state =
      if identity.disabled_at do
        :guest
      else
        compute_state(identity)
      end

    {:ok, identity} =
      identity
      |> UserIdentity.set_state(%{state: new_state, state_computed_at: DateTime.utc_now()})

    sync_auto_rule_groups!(user, identity, new_state)

    identity
  end

  @doc """
  Returns `user`'s current state without recomputing — a plain read of the
  persisted value, with the `disabled_at` override applied ahead of
  whatever was last persisted.
  """
  def state_of(%User{} = user) do
    case UserIdentity.by_user(user.id) do
      {:ok, %{disabled_at: disabled_at}} when not is_nil(disabled_at) -> :guest
      {:ok, %{state: state}} -> state
      _ -> :guest
    end
  end

  @doc """
  Designates `character` as `user`'s main. Raises if `character` does not
  belong to `user`. Recomputes state immediately.
  """
  def set_main!(%User{} = user, %Character{} = character) do
    if character.user_id != user.id do
      raise ArgumentError, "character does not belong to user"
    end

    identity = fetch_or_create_identity!(user.id)

    {:ok, _identity} =
      identity
      |> UserIdentity.set_main_character(%{main_character_id: character.id})

    Audit.log!(%{
      actor_user_id: user.id,
      target_user_id: user.id,
      action: :main_character_change,
      details: %{main_character_id: character.id}
    })

    recompute!(user)
  end

  @doc """
  Forces `target`'s state to `:guest` regardless of computed value, cutting
  every downstream consequence (group membership, therefore map access and
  Discord roles once those phases are live) through the normal recompute
  path — no phase-specific integration code. See
  docs/chewy/corp-suite-plan.md §2.8.3.
  """
  def disable!(%User{} = target, %User{} = admin, reason: reason) do
    identity = fetch_or_create_identity!(target.id)

    {:ok, _identity} =
      identity
      |> UserIdentity.disable(%{
        disabled_at: DateTime.utc_now(),
        disabled_by_user_id: admin.id,
        disabled_reason: reason
      })

    Audit.log!(%{
      actor_user_id: admin.id,
      target_user_id: target.id,
      action: :account_disabled,
      details: %{reason: reason}
    })

    recompute!(target)
  end

  @doc """
  Clears a disable override. Does **not** restore prior manual group
  grants — only lifts the `:guest` short-circuit, so state recomputes from
  scratch.
  """
  def reactivate!(%User{} = target, %User{} = admin) do
    identity = fetch_or_create_identity!(target.id)

    {:ok, _identity} = identity |> UserIdentity.reactivate(%{})

    Audit.log!(%{
      actor_user_id: admin.id,
      target_user_id: target.id,
      action: :account_reactivated,
      details: %{}
    })

    recompute!(target)
  end

  @doc """
  Recomputes every user's state — the daily Quantum sweep
  (`config/runtime.exs`'s `identity_suite_jobs`). Catches anyone whose
  state should have changed but who hasn't logged in since (kicked from
  corp while offline, a `:blue` grant added by an admin).
  """
  def recompute_all do
    users = Ash.read!(User)

    Enum.each(users, fn user ->
      try do
        recompute!(user)
      rescue
        error ->
          Logger.warning("[StateEngine] recompute_all skipped user #{user.id}: #{inspect(error)}")
      end
    end)

    :ok
  end

  @doc """
  Called from `character/tracker.ex`'s affiliation-change handlers. Only
  recomputes when `character` is the affected user's designated main — an
  alt's affiliation churn must not move the needle on state.
  """
  def maybe_recompute_for_character!(%Character{user_id: nil}), do: :ok

  def maybe_recompute_for_character!(%Character{} = character) do
    case UserIdentity.by_user(character.user_id) do
      {:ok, %{main_character_id: main_id}} when main_id == character.id ->
        {:ok, user} = User.by_id(character.user_id)
        recompute!(user)
        :ok

      _ ->
        :ok
    end
  end

  # -- state computation ----------------------------------------------

  defp compute_state(%UserIdentity{main_character_id: nil}), do: :guest

  defp compute_state(%UserIdentity{main_character_id: main_character_id}) do
    case Character.by_id(main_character_id) do
      {:ok, %{corporation_id: corporation_id, alliance_id: alliance_id} = character} ->
        if member?(corporation_id, alliance_id) do
          :member
        else
          blue_or_guest(corporation_id, alliance_id, character)
        end

      _ ->
        :guest
    end
  end

  defp member?(corporation_id, alliance_id) do
    {:ok, owned} = OwnedCorporation.read()

    Enum.any?(owned, fn corp ->
      (not is_nil(corporation_id) and corp.eve_corporation_id == corporation_id) or
        (not is_nil(alliance_id) and not is_nil(corp.alliance_id) and
           corp.alliance_id == alliance_id)
    end)
  end

  defp blue_or_guest(corporation_id, alliance_id, character) do
    character_eve_id =
      case Integer.parse(character.eve_id) do
        {int, _} -> int
        :error -> nil
      end

    {:ok, grants} = StandingGrant.matching(character_eve_id, corporation_id, alliance_id)

    if Enum.any?(grants), do: :blue, else: :guest
  end

  # -- auto-rule group reconciliation ----------------------------------

  defp sync_auto_rule_groups!(user, identity, new_state) do
    {:ok, rules} = GroupAutoRule.read()
    character = main_character(identity)

    rules
    |> Enum.group_by(& &1.group_id)
    |> Enum.each(fn {group_id, group_rules} ->
      matches? = Enum.any?(group_rules, &rule_matches?(&1, new_state, character))
      reconcile_auto_membership!(user, group_id, matches?)
    end)
  end

  defp main_character(%UserIdentity{main_character_id: nil}), do: nil

  defp main_character(%UserIdentity{main_character_id: id}) do
    case Character.by_id(id) do
      {:ok, character} -> character
      _ -> nil
    end
  end

  defp rule_matches?(%{match_kind: :state, match_value: value}, new_state, _character) do
    to_string(new_state) == value
  end

  defp rule_matches?(%{match_kind: :corporation_id}, _new_state, nil), do: false

  defp rule_matches?(%{match_kind: :corporation_id, match_value: value}, _new_state, character) do
    to_string(character.corporation_id) == value
  end

  defp rule_matches?(%{match_kind: :alliance_id}, _new_state, nil), do: false

  defp rule_matches?(%{match_kind: :alliance_id, match_value: value}, _new_state, character) do
    not is_nil(character.alliance_id) and to_string(character.alliance_id) == value
  end

  # No title data source exists yet — always false, never matches.
  defp rule_matches?(%{match_kind: :title}, _new_state, _character), do: false

  defp rule_matches?(%{match_kind: :esi_director_role}, _new_state, nil), do: false

  defp rule_matches?(%{match_kind: :esi_director_role}, _new_state, character) do
    DirectorCheck.esi_director?(character, character.corporation_id)
  end

  defp reconcile_auto_membership!(user, group_id, true) do
    case GroupMembership.by_group_and_user(group_id, user.id) do
      {:ok, _existing} ->
        :ok

      {:error, _not_found} ->
        {:ok, _} =
          GroupMembership.create(%{
            group_id: group_id,
            user_id: user.id,
            source: :auto_rule,
            status: :active
          })

        :ok
    end
  end

  defp reconcile_auto_membership!(user, group_id, false) do
    case GroupMembership.by_group_and_user(group_id, user.id) do
      {:ok, %{source: :auto_rule} = membership} -> GroupMembership.destroy(membership)
      _ -> :ok
    end
  end

  defp fetch_or_create_identity!(user_id) do
    case UserIdentity.by_user(user_id) do
      {:ok, identity} ->
        identity

      _ ->
        {:ok, identity} = UserIdentity.create(%{user_id: user_id, state: :guest})
        identity
    end
  end
end
