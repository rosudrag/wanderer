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

  describe "the login request itself" do
    @compiled_scope "esi-location.read_location.v1"

    # Exactly the prod failure, reproduced: `plug Ueberauth` runs
    # `Ueberauth.init/1` at COMPILE time in a release (dev and test set
    # `:plug_init_mode, :runtime`, prod does not), so the provider
    # options frozen into `conn.private[:ueberauth_request_options]`
    # are the ones from `config/config.exs` at image build, and
    # everything `config/runtime.exs` says about scopes is dead.
    #
    # Three characters were re-authorised on the live deployment after
    # WANDERER_SCOUT_ASSET_SAFETY went on and came back holding exactly
    # the five scopes they already had. This is that conn.
    defp request_conn do
      Plug.Test.conn(:get, "/auth/eve")
      |> Plug.Conn.fetch_query_params()
      |> Plug.Conn.put_private(:ueberauth_request_options, %{
        options: [default_scope: @compiled_scope, callback_path: "/auth/eve/callback"]
      })
    end

    test "asks EVE for the RUNNING scope string, not the one compiled into the release" do
      conn = WandererApp.Ueberauth.Strategy.Eve.handle_request!(request_conn())

      assert conn.status == 302
      location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
      scope = location |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("scope")

      assert scope == @required
      assert scope =~ "esi-characters.read_notifications.v1"
    end

    test "falls back to the compiled options when nothing is configured at runtime" do
      Application.put_env(:ueberauth, Ueberauth, [])

      conn = WandererApp.Ueberauth.Strategy.Eve.handle_request!(request_conn())

      location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
      scope = location |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("scope")

      assert scope == @compiled_scope
    end
  end
end
