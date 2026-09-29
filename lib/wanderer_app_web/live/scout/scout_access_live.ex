defmodule WandererAppWeb.ScoutAccessLive do
  @moduledoc """
  Superadmin page: hand out and take back `:scout_intel_view`.

  Gated harder than every other `/corp` page. `WandererAppWeb.
  GroupMapGrantsLive` admits any `corp_admin?/2`; this one admits only
  `WandererApp.Identity.ScoutAccess.superadmin?/1` — the single user
  owning `WANDERER_BOOTSTRAP_ADMIN_CHARACTER`. See that module's
  moduledoc for why.

  The mount check is belt-and-braces with the one in `ScoutAccess.grant_
  by_character_name/2`/`revoke/2`: the LiveView redirect stops the page
  being *rendered*, the module check stops the write happening at all,
  including from a crafted event on a socket that was authorized when it
  mounted and is not any more.
  """

  use WandererAppWeb, :live_view

  alias WandererApp.Identity.ScoutAccess

  @impl true
  def mount(_params, _session, socket) do
    # The flag is the scope pipeline's job; this page's own gate is the
    # superadmin tier, which is stricter than the log page's.
    if ScoutAccess.superadmin?(socket.assigns.current_user.id) do
      {:ok,
       socket
       |> assign(active_tab: :scout_access, page_title: "Scout Log Access")
       |> load()}
    else
      {:ok, socket |> push_navigate(to: ~p"/maps")}
    end
  end

  @impl true
  def handle_event("grant", %{"character_name" => character_name}, socket) do
    case ScoutAccess.grant_by_character_name(character_name, socket.assigns.current_user.id) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user.name} can now read the scout log")
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, message(reason))}
    end
  end

  def handle_event("revoke", %{"user_id" => user_id}, socket) do
    case ScoutAccess.revoke(user_id, socket.assigns.current_user.id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Access revoked") |> load()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, message(reason))}
    end
  end

  defp load(socket) do
    assign(socket,
      members: ScoutAccess.members(),
      superadmin_character: WandererApp.Env.bootstrap_admin_character()
    )
  end

  defp message(:blank_character_name), do: "Enter a character name"

  defp message(:character_not_found),
    do: "No such character has ever logged into this app — they must sign in once first"

  defp message(:character_has_no_user), do: "That character is not linked to a user account"
  defp message(:forbidden), do: "Only the bootstrap admin can change scout log access"
  defp message(other), do: "Could not update access: #{inspect(other)}"
end
