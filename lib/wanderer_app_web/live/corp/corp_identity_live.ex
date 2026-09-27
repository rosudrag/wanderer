defmodule WandererAppWeb.CorpIdentityLive do
  @moduledoc """
  Self-service main-character designation and computed-state display —
  the page `WandererApp.Identity.StateEngine.set_main!/2` is otherwise
  unreachable without. See docs/chewy/corp-suite-plan.md §2.2, §9 Phase 0.
  """

  use WandererAppWeb, :live_view

  alias WandererApp.Identity.StateEngine

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    identity = StateEngine.recompute!(user)

    {:ok,
     socket
     |> assign(
       active_tab: :corp,
       page_title: "Your Identity",
       characters: user.characters |> Enum.sort_by(& &1.name),
       main_character_id: identity.main_character_id,
       state: identity.state
     )}
  end

  @impl true
  def handle_event("set_main", %{"character_id" => character_id}, socket) do
    user = socket.assigns.current_user

    character = Enum.find(socket.assigns.characters, &(&1.id == character_id))

    case character do
      nil ->
        {:noreply, socket |> put_flash(:error, "Character not found on this account")}

      character ->
        identity = StateEngine.set_main!(user, character)

        {:noreply,
         socket
         |> assign(main_character_id: identity.main_character_id, state: identity.state)
         |> put_flash(:info, "Main character updated")}
    end
  end
end
