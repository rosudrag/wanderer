defmodule WandererAppWeb.DirectorAccessFlowTest do
  @moduledoc """
  Regression test for a defect caught in review: `director_scope`
  (`config/runtime.exs`) was missing `esi-corporations.track_members.v1`
  -- `WandererApp.Sync.Feeds.CorpRosterFeed` would have 403'd and flipped
  to `:stalled` forever even after a real director completed the
  consent flow, because EVE SSO only grants what's actually requested.
  Also proves the "request director access" entry point
  (`WandererAppWeb.CorpRosterLive`, not a new upstream
  `characters_live.ex` edit) actually reaches EVE SSO with the right
  scope and the right OAuth client credentials. See
  docs/chewy/corp-suite-plan.md §4/§9 Phase 0/Phase 3.

  Deliberately does NOT assert the whole `director_scope` string
  verbatim (a wording test that would rot on the next scope audit) --
  only that the two scopes the already-shipped director-dependent code
  paths actually call
  (`WandererApp.Identity.DirectorCheck.esi_director?/2` and
  `WandererApp.Sync.Feeds.CorpRosterFeed.fetch/2`) are present.
  """

  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WandererAppWeb.Factory

  test "director_scope contains both scopes the shipped director-dependent code paths call" do
    scope =
      Application.get_env(:ueberauth, Ueberauth)[:providers][:eve]
      |> elem(1)
      |> Keyword.fetch!(:director_scope)

    scopes = String.split(scope, " ")

    assert "esi-characters.read_corporation_roles.v1" in scopes,
           "WandererApp.Identity.DirectorCheck.esi_director?/2 needs this scope"

    assert "esi-corporations.track_members.v1" in scopes,
           "WandererApp.Sync.Feeds.CorpRosterFeed.fetch/2 needs this scope -- " <>
             "this is the exact scope that was missing before this fix"
  end

  test "GET /auth/eve?director=true redirects to EVE SSO requesting the director scope tier, " <>
         "using the director OAuth client credentials, not the default ones" do
    conn = get(build_conn(), ~p"/auth/eve?director=true")

    assert conn.status == 302
    location = get_resp_header(conn, "location") |> List.first()
    assert location =~ "login.eveonline.com"

    %URI{query: query} = URI.parse(location)
    params = URI.decode_query(query)

    requested_scopes = params["scope"] |> String.split(" ")
    assert "esi-characters.read_corporation_roles.v1" in requested_scopes
    assert "esi-corporations.track_members.v1" in requested_scopes

    director_client_id = WandererApp.Ueberauth.client_id(is_director?: true)
    default_client_id = WandererApp.Ueberauth.client_id([])

    assert params["client_id"] == director_client_id

    assert director_client_id != default_client_id,
           "the director branch must route to the _with_director credential pair, " <>
             "not silently fall back to the default client_id"
  end

  test "GET /auth/eve (no director param) does not request the director scope tier" do
    conn = get(build_conn(), ~p"/auth/eve")

    assert conn.status == 302
    location = get_resp_header(conn, "location") |> List.first()
    %URI{query: query} = URI.parse(location)
    params = URI.decode_query(query)

    requested_scopes = params["scope"] |> String.split(" ")
    refute "esi-corporations.track_members.v1" in requested_scopes
  end

  test "the /corp/roster page renders a director-access consent link pointing at director=true" do
    Application.put_env(:wanderer_app, :identity_suite_enabled, true)
    Application.put_env(:wanderer_app, :corp_roster_enabled, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :identity_suite_enabled)
      Application.delete_env(:wanderer_app, :corp_roster_enabled)
    end)

    user = create_user()

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"user_id" => user.id})

    {:ok, _view, html} = live(conn, ~p"/corp/roster")

    assert html =~ ~s(href="/auth/eve?director=true")
    assert html =~ "Grant director access"
  end
end
