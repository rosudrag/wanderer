defmodule WandererAppWeb.ScoutNav do
  @moduledoc """
  Chewy-owned sidebar entry for `/scout`.

  Rendered INSIDE `WandererAppWeb.Layouts.sidebar_nav_links/1`'s list, for
  the same reason `WandererAppWeb.CorpNav` is: that list is `h-full`, so a
  sibling placed after it lays out below the aside's bottom edge and is
  invisible.

  Unlike every other entry in that sidebar this one IS permission-gated —
  `/scout` is not a page every logged-in user may open, and an icon that
  only ever bounces you to `/maps` is worse than no icon. `CorpNav`'s
  moduledoc says admin-only pages are not linked there precisely because
  deciding costs a database round trip and this component renders on every
  LiveView mount, map canvas included. That constraint has not gone away;
  it is satisfied instead by `WandererApp.Identity.ScoutAccess.
  can_view_cached?/1`, which `WandererAppWeb.Nav.on_mount/4` resolves once
  into `@show_scout?`. Grants and revokes invalidate that cache, so the
  icon appears and disappears on the next page load, not on a TTL.
  """
  use WandererAppWeb, :html

  attr :show_scout?, :boolean, default: false
  attr :active_tab, :atom
  attr :show_sidebar, :boolean

  def scout_nav_links(assigns) do
    ~H"""
    <li :if={@show_scout? and @show_sidebar} class="flex-1 w-full">
      <div class="tooltip tooltip-right" data-tip="Scout Log">
        <.link
          navigate={~p"/scout"}
          class={[
            "h-full w-full text-gray-400 hover:text-white block p-3",
            @active_tab in [:scout, :scout_access] &&
              "border-r-4 text-white border-r-orange-400"
          ]}
          aria-current={if @active_tab in [:scout, :scout_access], do: "true", else: "false"}
        >
          <%!-- Not `hero-viewfinder-circle-solid`: that is the Map entry's
                icon, two rows up, and the sidebar had the same glyph twice. --%>
          <.icon name="hero-eye-solid" class="w-6 h-6" />
        </.link>
      </div>
    </li>
    """
  end
end
