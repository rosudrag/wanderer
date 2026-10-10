defmodule WandererApp.Character.ScopesTest do
  @moduledoc """
  What the Characters page can tell a user about a token that is valid
  and still useless.

  EVE SSO grants exactly what the login asked for and a refresh never
  widens a token, so the day this fork started requesting
  `esi-characters.read_notifications.v1` every existing character fell
  behind — and nothing said so: the page only ever flagged a NIL access
  token, which is a different failure. These cases pin the three things
  that make the new badge trustworthy:

    * the required set is read from the RUNNING login request, so adding
      a scope to `config/runtime.exs` reports itself with no second edit;
    * the opt-in tiers (wallet) are NOT required, or every ordinary
      character would be permanently stale;
    * a character with no recorded scopes is stale, not fine — "we do
      not know what it granted" must not render as a tick.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Character.Scopes

  @required "esi-location.read_location.v1 esi-ui.write_waypoint.v1 " <>
              "esi-characters.read_notifications.v1"

  setup do
    previous = Application.get_env(:ueberauth, Ueberauth)

    Application.put_env(:ueberauth, Ueberauth,
      providers: [eve: {WandererApp.Ueberauth.Strategy.Eve, [default_scope: @required]}]
    )

    on_exit(fn -> Application.put_env(:ueberauth, Ueberauth, previous) end)
  end

  test "required/0 is whatever an ordinary login asks EVE for right now" do
    assert "esi-characters.read_notifications.v1" in Scopes.required()
    assert length(Scopes.required()) == 3
  end

  test "a character authorised before a scope was added is stale, and says which" do
    character = %{scopes: "esi-location.read_location.v1 esi-ui.write_waypoint.v1"}

    assert Scopes.stale?(character)
    assert Scopes.missing(character) == ["esi-characters.read_notifications.v1"]
    assert Scopes.summary(character) == "asset-safety alerts on /scout"
  end

  test "a character holding everything asked for is not stale" do
    refute Scopes.stale?(%{scopes: @required})
    assert Scopes.missing(%{scopes: @required}) == []
  end

  test "an extra scope beyond the request does not make it stale" do
    character = %{scopes: @required <> " esi-wallet.read_character_wallet.v1"}

    refute Scopes.stale?(character)
    assert Scopes.wallet?(character)
  end

  test "wallet is opt-in, so its absence is never reported as missing" do
    refute "esi-wallet.read_character_wallet.v1" in Scopes.missing(%{scopes: ""})
    refute Scopes.wallet?(%{scopes: @required})
  end

  test "a character with no recorded scopes is stale rather than assumed complete" do
    assert Scopes.stale?(%{scopes: nil})
    assert Scopes.stale?(%{scopes: ""})
    assert Scopes.missing(%{scopes: nil}) == Scopes.required()
  end

  test "an unconfigured provider makes this inert rather than noisy" do
    Application.put_env(:ueberauth, Ueberauth, [])

    assert Scopes.required() == []
    refute Scopes.stale?(%{scopes: nil})
  end
end
