defmodule WandererAppWeb.CorpNav do
  @moduledoc """
  Chewy-owned sidebar entry for the `/corp` scope, rendered INSIDE
  `WandererAppWeb.Layouts.sidebar_nav_links/1`'s list — not as a sibling of
  it. That list is `h-full`, so anything placed after it lays out below the
  aside's bottom edge and is invisible; that bug shipped once. See
  docs/chewy/corp-suite-plan.md §9 Phase 0 hook #5.

  One icon, on purpose. `/corp` is the management page every suite feature
  is reachable from (`WandererAppWeb.CorpManagementLive`); the sidebar is a
  fixed column shared with the map canvas and cannot grow an icon per phase.

  Admin-only pages are NOT linked here: deciding whether to show them needs
  `WandererApp.Identity.PermissionCache.corp_admin?/2`, a database round
  trip, and this component renders inside `Nav.on_mount/4` for EVERY
  LiveView including the map canvas. The management page computes it once
  and links them there.
  """
  use WandererAppWeb, :html

  attr :corp_flags, :map, required: true
  attr :active_tab, :atom
  attr :show_sidebar, :boolean

  def corp_nav_links(assigns) do
    ~H"""
    <div :if={@corp_flags[:identity_suite_enabled?] and @show_sidebar}>
      <.link
        navigate={~p"/corp"}
        class={[
          "flex-1 w-full h-14 block text-gray-400 hover:text-white p-3 tooltip tooltip-right",
          @active_tab in [:corp, :corp_identity, :corp_map_grants, :corp_scout, :corp_scout_access] &&
            "text-white"
        ]}
        data-tip="Management"
      >
        <.icon name="hero-identification-solid" class="w-6 h-6" />
      </.link>
    </div>
    """
  end
end
