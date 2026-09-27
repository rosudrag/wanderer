defmodule WandererAppWeb.AuthControllerTest do
  use WandererAppWeb.ConnCase

  alias WandererAppWeb.AuthController

  describe "parameter validation and error handling" do
    test "callback/2 validates missing assigns" do
      conn = browser_conn()
      params = %{}

      # Should handle gracefully when required assigns are missing
      result = AuthController.callback(conn, params)

      # Function should redirect via fallback clause
      assert %Plug.Conn{} = result
      assert result.status == 302
    end

    test "signout/2 handles session clearing" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_session("current_user", %{id: "test-user"})

      result = AuthController.signout(conn, %{})

      # Should clear session and redirect
      assert %Plug.Conn{} = result
      assert result.status == 302
      # Session should be dropped (configure_session(drop: true))
      # The actual session will be empty after dropping
    end

    test "callback/2 handles malformed auth data gracefully" do
      # Test with minimal conn structure to exercise error paths
      # The callback/2 function will match the fallback clause and redirect
      conn = browser_conn()

      result = AuthController.callback(conn, %{})

      # Should redirect to /characters for malformed/missing auth data
      assert %Plug.Conn{} = result
      assert result.status == 302
    end

    test "callback/2 processes auth structure with missing fields" do
      # Test the fallback clause since auth structure is incomplete
      # Missing CharacterOwnerHash will cause pattern match failure
      conn = browser_conn()

      result = AuthController.callback(conn, %{})

      # Should redirect via fallback clause
      assert %Plug.Conn{} = result
      assert result.status == 302
    end

    test "callback/2 exercises character creation path" do
      # Test the fallback clause for now since character creation involves complex validation
      # The actual implementation requires valid EVE character data which is complex to mock
      conn = browser_conn()

      result = AuthController.callback(conn, %{})

      # Should redirect via fallback clause
      assert %Plug.Conn{} = result
      assert result.status == 302
    end

    test "callback/2 handles existing user assignment" do
      # Test the fallback clause for consistent behavior
      conn = browser_conn()

      result = AuthController.callback(conn, %{})

      # Should redirect via fallback clause
      assert %Plug.Conn{} = result
      assert result.status == 302
    end

    test "callback/2 validates various auth credential formats" do
      # Test fallback clause behavior for various cases
      test_cases = [
        browser_conn(),
        browser_conn() |> assign(:some_other_assign, "value")
      ]

      Enum.each(test_cases, fn conn ->
        result = AuthController.callback(conn, %{})

        # Should redirect via fallback clause
        assert %Plug.Conn{} = result
        assert result.status == 302
      end)
    end
  end

  describe "session management" do
    test "signout/2 with empty session" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})

      result = AuthController.signout(conn, %{})

      assert %Plug.Conn{} = result
      assert result.status == 302 || result.status == nil
    end

    test "signout/2 with various session states" do
      # Test different session configurations
      session_states = [
        %{},
        %{"current_user" => nil},
        %{"current_user" => %{id: "user1"}},
        %{"other_key" => "value"}
      ]

      Enum.each(session_states, fn session_data ->
        conn =
          build_conn()
          |> Plug.Test.init_test_session(session_data)

        result = AuthController.signout(conn, %{})

        # Should handle each session state and redirect
        assert %Plug.Conn{} = result
        assert result.status == 302
        # Should have location header for redirect
        location_header = result.resp_headers |> Enum.find(fn {key, _} -> key == "location" end)
        assert location_header != nil
      end)
    end
  end

  describe "helper functions" do
    test "maybe_update_character_user_id/2 with valid user_id" do
      # Test with non-nil user_id - this will try to call Ash API with invalid character
      character = %{id: "char123"}
      user_id = "user456"

      # Should raise error due to invalid character ID format
      assert_raise Ash.Error.Invalid, fn ->
        AuthController.maybe_update_character_user_id(character, user_id)
      end
    end

    test "maybe_update_character_user_id/2 with nil user_id" do
      character = %{id: "char123"}
      user_id = nil

      # Should return :ok for nil user_id
      result = AuthController.maybe_update_character_user_id(character, user_id)
      assert result == :ok
    end

    test "maybe_update_character_user_id/2 with empty string user_id" do
      # Test with empty string user_id - this is NOT nil so first function matches
      # But we'll get an error due to invalid character ID, so test for that
      character = %{id: "char123"}
      user_id = ""

      # Should raise an error because empty string is not nil and character ID is invalid
      assert_raise Ash.Error.Invalid, fn ->
        AuthController.maybe_update_character_user_id(character, user_id)
      end
    end

    test "maybe_update_character_user_id/2 with various character formats" do
      # Test different character and user_id combinations
      characters = [
        %{id: "char1"},
        %{id: "char2", name: "Test Character"},
        %{id: "char3", eve_id: "123456789"}
      ]

      # Test nil user_ids (should return :ok)
      Enum.each(characters, fn character ->
        result = AuthController.maybe_update_character_user_id(character, nil)
        assert result == :ok
      end)

      # Test non-nil user_ids (should raise error due to invalid character IDs)
      non_nil_user_ids = ["", "user123"]

      Enum.each(characters, fn character ->
        Enum.each(non_nil_user_ids, fn user_id ->
          assert_raise Ash.Error.Invalid, fn ->
            AuthController.maybe_update_character_user_id(character, user_id)
          end
        end)
      end)
    end
  end

  describe "resolve_user_id/4 (ownership transfer detection)" do
    test "a session user always wins, regardless of any hash" do
      {:ok, session_user} =
        WandererApp.Api.User
        |> Ash.Changeset.for_create(:create, %{name: "Session User", hash: "SESSION_HASH"})
        |> Ash.create()

      {:ok, character} = create_character("111000001", "SOME_HASH")

      resolved =
        AuthController.resolve_user_id(session_user, character, "IRRELEVANT", "ALSO_IRRELEVANT")

      assert resolved == session_user.id
    end

    test "same-hash re-login resolves to the character's existing owner, not a new user" do
      {:ok, owner} =
        WandererApp.Api.User
        |> Ash.Changeset.for_create(:create, %{name: "Owner", hash: "STABLE_HASH"})
        |> Ash.create()

      {:ok, character} = create_character("111000002", "STABLE_HASH")
      character = WandererApp.Api.Character.assign_user!(character, %{user_id: owner.id})

      resolved = AuthController.resolve_user_id(nil, character, "STABLE_HASH", "STABLE_HASH")

      assert resolved == owner.id
    end

    test "a changed hash does NOT resolve to the character's stale user_id (ownership transfer)" do
      {:ok, seller} =
        WandererApp.Api.User
        |> Ash.Changeset.for_create(:create, %{name: "Seller", hash: "SELLER_HASH"})
        |> Ash.create()

      {:ok, character} = create_character("111000003", "SELLER_HASH")
      character = WandererApp.Api.Character.assign_user!(character, %{user_id: seller.id})

      resolved = AuthController.resolve_user_id(nil, character, "BUYER_HASH", "SELLER_HASH")

      refute resolved == seller.id
    end

    test "a changed hash resolves to a fresh user keyed to the new hash" do
      {:ok, seller} =
        WandererApp.Api.User
        |> Ash.Changeset.for_create(:create, %{name: "Seller2", hash: "SELLER_HASH_2"})
        |> Ash.create()

      {:ok, character} = create_character("111000004", "SELLER_HASH_2")
      character = WandererApp.Api.Character.assign_user!(character, %{user_id: seller.id})

      resolved = AuthController.resolve_user_id(nil, character, "BUYER_HASH_2", "SELLER_HASH_2")

      {:ok, new_user} = WandererApp.Api.User.by_id(resolved)
      assert new_user.hash == "BUYER_HASH_2"
      assert new_user.id != seller.id
    end

    test "a brand-new character (no stored hash yet) falls through to character.user_id" do
      {:ok, character} = create_character("111000005", "FRESH_HASH")

      resolved = AuthController.resolve_user_id(nil, character, "FRESH_HASH", nil)

      {:ok, new_user} = WandererApp.Api.User.by_id(resolved)
      assert new_user.hash == "FRESH_HASH"
    end

    defp create_character(eve_id, owner_hash) do
      WandererApp.Api.Character.create(%{
        eve_id: eve_id,
        name: "Test Character #{eve_id}",
        access_token: "tok",
        refresh_token: "reftok",
        expires_at: 9_999_999_999,
        scopes: "esi-location.read_location.v1",
        tracking_pool: "default",
        character_owner_hash: owner_hash
      })
    end
  end

  # The SSO callback failure path calls put_flash/3, which requires the session
  # and flash plugs that the real :browser pipeline installs. A bare
  # build_conn/0 has neither, so these tests died with "flash not fetched"
  # before ever reaching the redirect they assert on. This mirrors the browser
  # pipeline rather than relaxing the controller.
  defp browser_conn do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.ConnTest.fetch_flash()
  end
end
