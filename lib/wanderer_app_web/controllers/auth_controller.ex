defmodule WandererAppWeb.AuthController do
  use WandererAppWeb, :controller
  plug Ueberauth

  import Plug.Conn
  import Phoenix.Controller

  require Logger

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user} = _assigns} = conn, _params) do
    active_tracking_pool = WandererApp.Character.TrackingConfigUtils.get_active_pool!()

    Logger.info(
      "[AuthController] SSO callback SUCCESS for eve_id=#{auth.info.email}, " <>
        "has_token=#{not is_nil(auth.credentials.token)}, " <>
        "has_refresh=#{not is_nil(auth.credentials.refresh_token)}"
    )

    %{
      "CharacterOwnerHash" => character_owner_hash
    } = auth.extra.raw_info.user

    character_data = %{
      eve_id: "#{auth.info.email}",
      name: auth.info.name,
      access_token: auth.credentials.token,
      refresh_token: auth.credentials.refresh_token,
      expires_at: auth.credentials.expires_at,
      scopes: auth.credentials.scopes,
      tracking_pool: active_tracking_pool,
      character_owner_hash: character_owner_hash
    }

    {:ok, character, stored_owner_hash} =
      case WandererApp.Api.Character.by_eve_id(character_data.eve_id) do
        {:ok, character} ->
          # Captured BEFORE the update below overwrites it — this is the hash
          # as of the character's previous login, compared against the
          # incoming one in resolve_user_id/4 to detect an ownership
          # transfer (CCP changes CharacterOwnerHash when a character moves
          # to a different EVE account; see
          # test/unit/controllers/auth_controller_test.exs's "resolve_user_id/4
          # (ownership transfer detection)" describe block and
          # docs/chewy/corp-suite-plan.md §2.8.1).
          stored_owner_hash = character.character_owner_hash

          character_update = %{
            name: auth.info.name,
            access_token: auth.credentials.token,
            refresh_token: auth.credentials.refresh_token,
            expires_at: auth.credentials.expires_at,
            scopes: auth.credentials.scopes,
            tracking_pool: active_tracking_pool,
            character_owner_hash: character_owner_hash
          }

          {:ok, character} =
            character
            |> WandererApp.Api.Character.update(character_update)

          Logger.info(
            "[AuthController] Character #{character.id} tokens updated in DB, " <>
              "access_token_present=#{not is_nil(character.access_token)}"
          )

          WandererApp.Character.update_character(character.id, character_update)

          # Clear the invalid_grant counter so stale failures don't cause
          # premature token invalidation after a successful re-auth
          WandererApp.Cache.delete("character:#{character.id}:invalid_grant_count")

          # Set a grace period to protect fresh tokens from being wiped by
          # in-flight or immediately-subsequent invalid_grant errors
          WandererApp.Cache.put(
            "character:#{character.id}:reauth_grace",
            true,
            ttl: :timer.minutes(5)
          )

          # Update corporation/alliance data from ESI to ensure access control is current
          update_character_affiliation(character)

          {:ok, character, stored_owner_hash}

        {:error, _error} ->
          {:ok, character} = WandererApp.Api.Character.create(character_data)
          :telemetry.execute([:wanderer_app, :user, :character, :registered], %{count: 1})

          # Fetch initial corporation/alliance data for new characters
          update_character_affiliation(character)

          {:ok, character, nil}
      end

    user_id = resolve_user_id(user, character, character_owner_hash, stored_owner_hash)

    maybe_update_character_user_id(character, user_id)

    # CHEWY PATCH: identity/state/groups suite — recompute state right
    # after login, inert unless WANDERER_IDENTITY_SUITE is on. See
    # docs/chewy/corp-suite-plan.md §2.2, §9 Phase 0 hook #8.
    if WandererApp.Env.identity_suite_enabled?() do
      case WandererApp.Api.User.by_id(user_id) do
        {:ok, current_user} -> WandererApp.Identity.StateEngine.recompute!(current_user)
        _ -> :ok
      end
    end

    WandererApp.Character.TrackingConfigUtils.update_active_tracking_pool()

    conn
    |> put_session(:user_id, user_id)
    |> redirect(to: "/characters")
  end

  def callback(conn, _params) do
    # This runs when Ueberauth auth FAILED — tokens are NOT updated
    ueberauth_failure = conn.assigns[:ueberauth_failure]

    Logger.warning(
      "[AuthController] SSO callback FAILED - no ueberauth_auth in assigns. " <>
        "Failure: #{inspect(ueberauth_failure)}"
    )

    conn
    |> put_flash(:error, "Authorization failed. Please try again.")
    |> redirect(to: "/characters")
  end

  def signout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end

  def maybe_update_character_user_id(character, user_id) when not is_nil(user_id) do
    # First try to load the character by ID to ensure it exists and is valid
    case WandererApp.Api.Character.by_id(character.id) do
      {:ok, loaded_character} ->
        WandererApp.Api.Character.assign_user!(loaded_character, %{user_id: user_id})

      {:error, _} ->
        raise Ash.Error.Invalid,
          errors: [%Ash.Error.Query.NotFound{resource: WandererApp.Api.Character}]
    end
  end

  def maybe_update_character_user_id(_character, _user_id), do: :ok

  # Resolves which `User` a login belongs to.
  #
  # `stored_owner_hash` is the character's `character_owner_hash` as it stood
  # BEFORE this login's update — `nil` for a brand-new character, otherwise
  # the value captured on the character's previous login. Comparing it
  # against the incoming `character_owner_hash` is CCP's own signal that the
  # character has moved to a different EVE account since it last logged in
  # here (a transfer/sale) — see docs/chewy/corp-suite-plan.md §2.8.1/§2.8.2.
  #
  # A detected mismatch is treated exactly like a never-before-seen
  # character (`character.user_id == nil`): the stale `character.user_id`
  # link, which still points at the PREVIOUS owner's account, is never
  # reused. This is the minimum correct fix — full transfer handling (audit
  # logging, detaching the old user, state recompute) is a later change,
  # not built here. Public (not `defp`) so it is directly exercisable, same
  # posture as `maybe_update_character_user_id/2` above.
  def resolve_user_id(nil, character, character_owner_hash, stored_owner_hash) do
    case WandererApp.Api.User.by_hash(character_owner_hash) do
      {:ok, existing_user} ->
        existing_user.id

      _ ->
        if ownership_transferred?(stored_owner_hash, character_owner_hash) do
          Logger.warning(
            "[AuthController] character_owner_hash changed for character " <>
              "#{character.id} (eve_id=#{character.eve_id}) — treating as an " <>
              "ownership transfer, not reusing the previous user_id=" <>
              inspect(character.user_id)
          )

          create_user_for_hash!(character_owner_hash)
        else
          case character.user_id do
            nil -> create_user_for_hash!(character_owner_hash)
            user_id -> user_id
          end
        end
    end
  end

  def resolve_user_id(session_user, _character, _character_owner_hash, _stored_owner_hash) do
    session_user.id
  end

  defp ownership_transferred?(nil, _incoming), do: false
  defp ownership_transferred?(stored, incoming), do: stored != incoming

  defp create_user_for_hash!(character_owner_hash) do
    :telemetry.execute([:wanderer_app, :user, :registered], %{count: 1})

    WandererApp.Api.User
    |> Ash.Changeset.for_create(:create, %{
      name: "User_#{character_owner_hash}",
      hash: character_owner_hash
    })
    |> Ash.create!()
    |> Map.get(:id)
  end

  # Updates character's corporation and alliance data from ESI.
  # This ensures ACL-based access control uses current corporation membership,
  # even for characters not actively being tracked on any map.
  defp update_character_affiliation(%{id: character_id, eve_id: eve_id} = character) do
    # Run async to not block the SSO callback
    Task.start(fn ->
      character_eve_id = eve_id |> String.to_integer()

      case WandererApp.Esi.post_characters_affiliation([character_eve_id]) do
        {:ok, [affiliation_info]} when is_map(affiliation_info) ->
          new_corporation_id = Map.get(affiliation_info, "corporation_id")
          new_alliance_id = Map.get(affiliation_info, "alliance_id")

          # Check if corporation changed
          corporation_changed = character.corporation_id != new_corporation_id
          alliance_changed = character.alliance_id != new_alliance_id

          if corporation_changed or alliance_changed do
            update_affiliation_data(character_id, character, new_corporation_id, new_alliance_id)
          end

        {:error, error} ->
          Logger.warning(
            "[AuthController] Failed to fetch affiliation for character #{character_id}: #{inspect(error)}"
          )

        _ ->
          :ok
      end
    end)
  end

  defp update_character_affiliation(_character), do: :ok

  defp update_affiliation_data(character_id, character, corporation_id, alliance_id) do
    # Fetch corporation info
    corporation_update =
      case WandererApp.Esi.get_corporation_info(corporation_id) do
        {:ok, %{"name" => corp_name, "ticker" => corp_ticker}} ->
          %{
            corporation_id: corporation_id,
            corporation_name: corp_name,
            corporation_ticker: corp_ticker
          }

        _ ->
          %{corporation_id: corporation_id}
      end

    # Fetch alliance info if present
    alliance_update =
      case alliance_id do
        nil ->
          %{alliance_id: nil, alliance_name: nil, alliance_ticker: nil}

        _ ->
          case WandererApp.Esi.get_alliance_info(alliance_id) do
            {:ok, %{"name" => alliance_name, "ticker" => alliance_ticker}} ->
              %{
                alliance_id: alliance_id,
                alliance_name: alliance_name,
                alliance_ticker: alliance_ticker
              }

            _ ->
              %{alliance_id: alliance_id}
          end
      end

    full_update = Map.merge(corporation_update, alliance_update)

    # Update database
    case character.corporation_id != corporation_id do
      true ->
        {:ok, _} = WandererApp.Api.Character.update_corporation(character, corporation_update)

      false ->
        :ok
    end

    case character.alliance_id != alliance_id do
      true ->
        {:ok, _} = WandererApp.Api.Character.update_alliance(character, alliance_update)

      false ->
        :ok
    end

    # Update cache
    WandererApp.Character.update_character(character_id, full_update)

    Logger.info(
      "[AuthController] Updated affiliation for character #{character_id}: " <>
        "corp #{character.corporation_id} -> #{corporation_id}, " <>
        "alliance #{character.alliance_id} -> #{alliance_id}"
    )
  end
end
