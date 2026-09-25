defmodule WandererAppWeb.DevAuthController do
  @moduledoc """
  DEV-ONLY authentication bypass, letting an agentic developer exercise the
  map UI without an EVE Online account and without EVE SSO.

  This endpoint is a genuine authentication bypass and MUST be impossible to
  enable by accident:

    * It is a 404 — with no observable difference from a non-existent route —
      unless `WANDERER_DEV_AUTH_TOKEN` is configured to a value at least 16
      bytes long. See `WandererApp.Env.dev_auth_enabled?/0`.
    * The supplied `token` query param is compared to the configured token
      with `Plug.Crypto.secure_compare/2` (constant-time).
    * Every successful use is logged with `Logger.warning/1`.

  On success it finds-or-creates a single fixed dev user/character pair
  (`hash: "dev-auth-agent"`, `eve_id: "2100000001"`) — the same identity
  `WandererApp.Dev.Seed` seeds map ownership for — puts `user_id` in the
  session exactly like `WandererAppWeb.AuthController.callback/2` does for a
  real EVE SSO login, and redirects to `/maps`.
  """
  use WandererAppWeb, :controller

  require Logger

  @dev_user_hash "dev-auth-agent"
  @dev_character_eve_id "2100000001"
  @dev_default_name "Agent Smith"
  @dev_fake_token "dev-auth-fake-token"
  # Matches the `default_scope` EVE SSO requests in config/runtime.exs, so a
  # dev-auth character looks like a normally-scoped SSO character.
  @dev_scopes "esi-location.read_location.v1 esi-location.read_ship_type.v1 esi-location.read_online.v1 esi-ui.write_waypoint.v1 esi-search.search_structures.v1"
  # Year 3000 — far enough in the future that nothing ever tries to refresh it.
  @dev_expires_at 32_503_680_000

  def login(conn, params) do
    if WandererApp.Env.dev_auth_enabled?() do
      handle_enabled(conn, params)
    else
      reject(conn)
    end
  end

  defp handle_enabled(conn, params) do
    supplied = Map.get(params, "token")
    configured = WandererApp.Env.dev_auth_token()

    if is_binary(supplied) and is_binary(configured) and
         Plug.Crypto.secure_compare(supplied, configured) do
      authenticate(conn, params)
    else
      reject(conn)
    end
  end

  defp authenticate(conn, params) do
    name = params["name"] || @dev_default_name

    Logger.warning(
      "[DevAuthController] DEV AUTH BYPASS login used — issuing a session for " <>
        "hash=#{@dev_user_hash} eve_id=#{@dev_character_eve_id} name=#{inspect(name)}. " <>
        "This must never happen against a production deployment."
    )

    user_id = find_or_create_user!()
    character = find_or_create_character!(name)

    WandererApp.Api.Character.assign_user!(character, %{user_id: user_id})

    conn
    |> put_session(:user_id, user_id)
    |> redirect(to: "/maps")
  end

  defp reject(conn) do
    Logger.debug("[DevAuthController] rejected /dev/login attempt")

    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end

  defp find_or_create_user!() do
    case WandererApp.Api.User.by_hash(@dev_user_hash) do
      {:ok, user} ->
        user.id

      {:error, _not_found} ->
        WandererApp.Api.User
        |> Ash.Changeset.for_create(:create, %{name: @dev_default_name, hash: @dev_user_hash})
        |> Ash.create!()
        |> Map.get(:id)
    end
  end

  defp find_or_create_character!(name) do
    character_data = %{
      eve_id: @dev_character_eve_id,
      name: name,
      access_token: @dev_fake_token,
      refresh_token: @dev_fake_token,
      expires_at: @dev_expires_at,
      scopes: @dev_scopes
    }

    case WandererApp.Api.Character.by_eve_id(@dev_character_eve_id) do
      {:ok, character} ->
        # The :update action does not accept :eve_id (it is the identity), so
        # refresh only the mutable fields.
        {:ok, character} =
          WandererApp.Api.Character.update(character, Map.delete(character_data, :eve_id))

        character

      {:error, _not_found} ->
        {:ok, character} = WandererApp.Api.Character.create(character_data)
        character
    end
  end
end
