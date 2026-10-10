defmodule WandererAppWeb.CharactersLiveTest do
  @moduledoc """
  The one thing this page could not say: a token can be perfectly valid
  and still be missing a permission the instance started asking for
  after it was issued. Everything keeps working except the feature that
  needs it, which simply renders empty forever.

  See `WandererApp.Character.Scopes`.
  """

  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WandererAppWeb.Factory

  @required "esi-location.read_location.v1 esi-characters.read_notifications.v1"

  setup do
    previous = Application.get_env(:ueberauth, Ueberauth)

    Application.put_env(:ueberauth, Ueberauth,
      providers: [eve: {WandererApp.Ueberauth.Strategy.Eve, [default_scope: @required]}]
    )

    on_exit(fn -> Application.put_env(:ueberauth, Ueberauth, previous) end)

    user = create_user()
    character = create_character(%{user_id: user.id, name: "Behind Pilot"})

    conn = build_conn() |> Plug.Test.init_test_session(%{"user_id" => user.id})

    %{conn: conn, user: user, character: character}
  end

  defp grant(character, scopes) do
    {:ok, character} = WandererApp.Api.Character.update(character, %{scopes: scopes})
    Cachex.del(:character_cache, character.id)
    character
  end

  test "a character behind on scopes raises the banner and its own badge", %{
    conn: conn,
    character: character
  } do
    grant(character, "esi-location.read_location.v1")

    {:ok, _view, html} = live(conn, ~p"/characters")

    assert html =~ "characters-stale-scopes-alert"
    assert html =~ "granted fewer EVE permissions"
    # The badge says what is missing in a reader's words, not a scope URN.
    assert html =~ "asset-safety alerts on /scout"
  end

  test "a character holding everything asked for raises nothing", %{
    conn: conn,
    character: character
  } do
    grant(character, @required)

    {:ok, _view, html} = live(conn, ~p"/characters")

    refute html =~ "characters-stale-scopes-alert"
    refute html =~ "asset-safety alerts on /scout"
  end

  test "refreshing a wallet character arrives with wallet still ticked", %{
    conn: conn,
    character: character
  } do
    grant(character, @required <> " esi-wallet.read_character_wallet.v1")

    # The checkbox only exists when the instance tracks wallets at all.
    Application.put_env(:wanderer_app, :wallet_tracking_enabled, true)
    on_exit(fn -> Application.delete_env(:wanderer_app, :wallet_tracking_enabled) end)

    {:ok, view, _html} = live(conn, ~p"/characters")

    modal =
      view
      |> element(~s{a[href="/characters/authorize?character_id=#{character.eve_id}"]})
      |> render_click()

    # Following the page's own "refresh" prompt must not silently REVOKE
    # wallet access: EVE grants exactly what the login requested.
    assert modal =~ ~r/name="track_wallet"[^>]*checked/
  end
end
