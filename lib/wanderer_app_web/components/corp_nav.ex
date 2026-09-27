defmodule WandererAppWeb.CorpNav do
  @moduledoc """
  Chewy-owned sidebar entries for the `/corp` scope. New, not `layouts.ex` —
  every later phase adds nav entries here, never touching
  `sidebar_nav_links/1` again after this file's introduction. See
  docs/chewy/corp-suite-plan.md §9 Phase 0 hook #5.

  Deliberately only two icons, not one per page. The sidebar is a fixed
  column of 14px-tall icons shared with the map, and a suite that grows to
  19 phases cannot grow the sidebar with it. `/corp` is the hub every
  feature is listed on (`WandererAppWeb.CorpShellLive`); only the roster
  earns a second icon, because it is the one page a member opens
  repeatedly rather than once.

  Admin-only pages are NOT linked here on purpose: deciding whether to show
  them needs `WandererApp.Identity.PermissionCache.corp_admin?/2`, a
  database round trip, and this component renders inside `Nav.on_mount/4`
  for EVERY LiveView including the map canvas. Paying a query per map mount
  to decide whether to draw an icon is the wrong trade; the hub page
  computes it once and lists them there.

  Each entry highlights on its own `active_tab` (`WandererAppWeb.Nav`'s
  `set_active_tab/3`), not a shared `:corp`, so the sidebar shows where you
  actually are.
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
          @active_tab in [:corp, :corp_identity, :corp_map_grants] && "text-white"
        ]}
        data-tip="Corp"
      >
        <.icon name="hero-identification-solid" class="w-6 h-6" />
      </.link>
    </div>
    <div :if={
      @corp_flags[:identity_suite_enabled?] and @corp_flags[:corp_roster_enabled?] and
        @show_sidebar
    }>
      <.link
        navigate={~p"/corp/roster"}
        class={[
          "flex-1 w-full h-14 block text-gray-400 hover:text-white p-3 tooltip tooltip-right",
          @active_tab == :corp_roster && "text-white"
        ]}
        data-tip="Roster"
      >
        <.icon name="hero-users-solid" class="w-6 h-6" />
      </.link>
    </div>
    """
  end
end
