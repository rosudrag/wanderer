defmodule WandererAppWeb.CorpShellLive do
  @moduledoc """
  Empty landing shell for the `/corp` scope — proves the route/gate work
  (Phase 0 acceptance criteria) and is the jumping-off point for every
  later phase's page. See docs/chewy/corp-suite-plan.md §9 Phase 0.
  """

  use WandererAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    is_corp_admin? =
      WandererApp.Identity.PermissionCache.corp_admin?(
        socket.assigns.current_user_role,
        socket.assigns.current_user.id
      )

    {:ok, socket |> assign(active_tab: :corp, page_title: "Corp", is_corp_admin?: is_corp_admin?)}
  end
end
