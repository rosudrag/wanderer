defmodule WandererAppWeb.CorpIdentityLiveTest do
  @moduledoc """
  Proves the `/corp/identity` LiveView drives a real alliance-state
  transition through its own UI event (`phx-click="set_main"`), not through
  `WandererApp.Identity.StateEngine` called directly. Exercises the same
  code path a browser click does: `render_click/3` on the "Set as main"
  button for a character whose corp is `WandererApp.Api.OwnedCorporation`,
  then asserts both the rendered `<span id="corp-identity-state">` and the
  persisted `WandererApp.Api.UserIdentity` row moved `:guest` -> `:member`.

  See `docs/chewy/corp-suite-plan.md` §9 Phase 0 and
  `lib/wanderer_app_web/live/corp/corp_identity_live.ex`.
  """

  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WandererAppWeb.Factory

  alias WandererApp.Api.OwnedCorporation
  alias WandererApp.Api.UserIdentity

  setup do
    Application.put_env(:wanderer_app, :identity_suite_enabled, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :identity_suite_enabled)
    end)

    user = create_user()

    # Main-eligible alt: corporation_id matches an OwnedCorporation row.
    {:ok, owned} =
      OwnedCorporation.create(%{
        eve_corporation_id: 98_765_432,
        name: "Test Alliance Corp",
        enabled: true
      })

    alt =
      create_character(%{
        user_id: user.id,
        name: "Alt In Corp",
        corporation_id: owned.eve_corporation_id,
        corporation_name: owned.name
      })

    # Not-yet-main character, corp does not match any OwnedCorporation row.
    _other =
      create_character(%{
        user_id: user.id,
        name: "Unrelated Character"
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"user_id" => user.id})

    %{conn: conn, user: user, alt: alt}
  end

  test "clicking \"Set as main\" flips state from :guest to :member through the UI event", %{
    conn: conn,
    user: user,
    alt: alt
  } do
    {:ok, view, html} = live(conn, ~p"/corp/identity")

    assert html =~ ~s(id="corp-identity-state")
    assert html =~ "guest"
    assert html =~ "Alt In Corp"

    assert {:ok, identity} = UserIdentity.by_user(user.id)
    assert identity.state == :guest
    assert is_nil(identity.main_character_id)

    rendered =
      view
      |> element("#character-row-#{alt.id} button", "Set as main")
      |> render_click()

    assert rendered =~ ~s(id="corp-identity-state">member<)
    assert rendered =~ "Alt In Corp"

    assert {:ok, identity_after} = UserIdentity.by_user(user.id)
    assert identity_after.state == :member
    assert identity_after.main_character_id == alt.id
  end
end
