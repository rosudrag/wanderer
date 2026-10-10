defmodule WandererAppWeb.CharactersLive do
  use WandererAppWeb, :live_view

  import Pathex

  alias BetterNumber, as: Number

  def mount(_params, %{"user_id" => user_id} = _session, socket)
      when not is_nil(user_id) do
    {:ok, characters} = WandererApp.Api.Character.active_by_user(%{user_id: user_id})

    characters
    |> Enum.map(& &1.id)
    |> Enum.each(fn character_id ->
      Phoenix.PubSub.subscribe(
        WandererApp.PubSub,
        "character:#{character_id}:alliance"
      )

      Phoenix.PubSub.subscribe(
        WandererApp.PubSub,
        "character:#{character_id}:corporation"
      )

      Phoenix.PubSub.subscribe(
        WandererApp.PubSub,
        "character:#{character_id}"
      )

      :ok = WandererApp.Character.TrackerManager.start_tracking(character_id)
    end)

    {:ok,
     socket
     |> assign(
       show_characters_add_alert: true,
       mode: :blocks,
       wallet_tracking_enabled?: WandererApp.Env.wallet_tracking_enabled?(),
       characters: characters |> Enum.sort_by(& &1.name, :asc) |> Enum.map(&map_ui_character/1),
       user_id: user_id
     )}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(characters: [], user_id: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("restore_show_characters_add_alert", %{"value" => value}, socket) do
    {:noreply,
     socket
     |> assign(show_characters_add_alert: value)}
  end

  @impl true
  def handle_event("authorize", form, socket) do
    track_wallet = form |> Map.get("track_wallet", false)

    active_pool = WandererApp.Character.TrackingConfigUtils.get_active_pool!()

    {:ok, esi_config} =
      Cachex.get(
        :esi_auth_cache,
        "config_#{active_pool}"
      )

    WandererApp.Cache.put("invite_#{esi_config.uuid}", true, ttl: :timer.minutes(30))

    {:noreply,
     socket |> push_navigate(to: ~p"/auth/eve?invite=#{esi_config.uuid}&w=#{track_wallet}")}
  end

  @impl true
  def handle_event("delete", %{"character_id" => character_id}, socket) do
    user_id = socket.assigns.user_id

    case WandererAppWeb.HandlerAuth.authorize_character(character_id, user_id) do
      {:ok, character} ->
        WandererApp.Character.TrackerManager.stop_tracking(character_id)

        {:ok, map_character_settings} =
          WandererApp.Api.MapCharacterSettings.tracked_by_character(%{character_id: character_id})

        map_character_settings
        |> Enum.each(fn settings ->
          {:ok, _} = WandererApp.MapCharacterSettingsRepo.untrack(settings)
        end)

        {:ok, _updated_character} = WandererApp.Api.Character.mark_as_deleted(character)

        WandererApp.Character.update_character(character_id, %{deleted: true, user_id: nil})

        {:ok, characters} =
          WandererApp.Api.Character.active_by_user(%{user_id: user_id})

        {:noreply, socket |> assign(characters: characters |> Enum.map(&map_ui_character/1))}

      {:error, :not_found} ->
        {:noreply, socket |> put_flash(:error, "Character not found.")}
    end
  end

  @impl true
  def handle_event(
        "validate",
        params,
        socket
      ) do
    {:noreply, assign(socket, form: params)}
  end

  @impl true
  def handle_event("show_table", %{"value" => "on"}, socket) do
    {:noreply, socket |> assign(mode: :table)}
  end

  @impl true
  def handle_event("show_table", _, socket) do
    {:noreply, socket |> assign(mode: :blocks)}
  end

  @impl true
  def handle_info(
        {:character_alliance, _update},
        socket
      ) do
    {:ok, characters} =
      WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

    {:noreply, socket |> assign(characters: characters |> Enum.map(&map_ui_character/1))}
  end

  @impl true
  def handle_info(
        {:character_corporation, _update},
        socket
      ) do
    {:ok, characters} =
      WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

    {:noreply, socket |> assign(characters: characters |> Enum.map(&map_ui_character/1))}
  end

  @impl true
  def handle_info(
        {:character_wallet_balance, _character_id},
        socket
      ) do
    {:ok, characters} =
      WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

    {:noreply, socket |> assign(characters: characters |> Enum.map(&map_ui_character/1))}
  end

  @impl true
  def handle_info(
        event,
        socket
      )
      when event in [:character_token_invalid, :token_updated] do
    {:ok, characters} =
      WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

    {:noreply, socket |> assign(characters: characters |> Enum.map(&map_ui_character/1))}
  end

  @impl true
  def handle_info(
        _event,
        socket
      ) do
    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:active_page, :characters)
    |> assign(:page_title, "Characters")
  end

  # CHEWY PATCH: `character_id` is optional and only ever a DEFAULT for
  # the wallet checkbox.
  #
  # Re-authorising is now something the page actively asks for (the
  # stale-scope banner), and the modal it sends you to had the wallet
  # box unchecked every time -- so following that prompt on a character
  # that HAD wallet access would have silently revoked it, since EVE
  # grants exactly what the login requested. The box arrives ticked for
  # a character that already granted it; unticking it is still a real
  # choice a user can make.
  defp apply_action(socket, :authorize, params) do
    socket
    |> assign(:active_page, :characters)
    |> assign(:page_title, "Authorize Character - Characters")
    |> assign(:form, to_form(%{"track_wallet" => refreshing_wallet?(socket, params)}))
  end

  defp refreshing_wallet?(socket, %{"character_id" => eve_id}) do
    case Enum.find(socket.assigns.characters, &(&1.eve_id == eve_id)) do
      nil -> false
      character -> Map.get(character, :track_wallet?, false)
    end
  end

  defp refreshing_wallet?(_socket, _params), do: false

  defp map_ui_character(character) do
    can_track_wallet? = WandererApp.Character.can_track_wallet?(character)

    character
    |> Map.take([
      :id,
      :eve_id,
      :name,
      :corporation_id,
      :corporation_name,
      :corporation_ticker,
      :alliance_id,
      :alliance_name,
      :alliance_ticker
    ])
    |> Map.put_new(:show_wallet_balance?, can_track_wallet?)
    |> maybe_add_wallet_balance(character, can_track_wallet?)
    # CHEWY PATCH: a token can be perfectly valid and still be missing a
    # permission this deployment started asking for after it was issued.
    # See WandererApp.Character.Scopes -- that is a different failure
    # from the `invalid_token` flag below and needs its own badge,
    # because the two look identical from the outside: everything works
    # except the one feature nobody thinks to check.
    |> Map.put_new(:missing_scopes, WandererApp.Character.Scopes.missing(character))
    |> Map.put_new(:missing_scopes_summary, WandererApp.Character.Scopes.summary(character))
    |> Map.put_new(:track_wallet?, WandererApp.Character.Scopes.wallet?(character))
    |> Map.put_new(:ship, WandererApp.Character.get_ship(character))
    |> Map.put_new(:location, WandererApp.Character.get_location(character))
    |> Map.put_new(:invalid_token, is_nil(character.access_token))
  end

  defp maybe_add_wallet_balance(map, character, true) do
    case WandererApp.Character.can_track_wallet?(character) do
      true ->
        {:ok, %{eve_wallet_balance: eve_wallet_balance}} =
          character
          |> Ash.load([:eve_wallet_balance])

        Map.put_new(map, :eve_wallet_balance, eve_wallet_balance)

      _ ->
        Map.put_new(map, :eve_wallet_balance, 0.0)
    end
  end

  defp maybe_add_wallet_balance(map, _character, _can_track_wallet?),
    do: Map.put_new(map, :eve_wallet_balance, 0.0)
end
