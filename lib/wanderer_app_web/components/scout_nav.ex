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
  # `{count, capped?}` of structures reported unanchored. The badge is the
  # only part of that alert visible from the map canvas, which is the only
  # page most people have open; see `WandererApp.Scout.Alerts`.
  attr :scout_alerts, :any, default: {0, false}
  attr :active_tab, :atom
  attr :show_sidebar, :boolean

  def scout_nav_links(assigns) do
    {count, capped?} = assigns.scout_alerts
    assigns = assigns |> assign(:alert_count, count) |> assign(:alert_capped?, capped?)

    ~H"""
    <li :if={@show_scout? and @show_sidebar} class="flex-1 w-full">
      <div
        class="tooltip tooltip-right"
        data-tip={
          if @alert_count > 0,
            do: "Scout Log — #{@alert_count}#{if @alert_capped?, do: "+", else: ""} unanchored",
            else: "Scout Log"
        }
      >
        <.link
          navigate={~p"/scout"}
          class={[
            "h-full w-full text-gray-400 hover:text-white block p-3 relative",
            @active_tab in [:scout, :scout_access, :scout_refresh] &&
              "border-r-4 text-white border-r-orange-400"
          ]}
          aria-current={
            if @active_tab in [:scout, :scout_access, :scout_refresh], do: "true", else: "false"
          }
        >
          <%!-- Not `hero-viewfinder-circle-solid`: that is the Map entry's
                icon, two rows up, and the sidebar had the same glyph twice. --%>
          <.icon
            name="hero-eye-solid"
            class={if @alert_count > 0, do: "w-6 h-6 text-error", else: "w-6 h-6"}
          />
          <span
            :if={@alert_count > 0}
            id="scout-nav-alert-badge"
            class="absolute top-1 right-1 min-w-[1rem] h-4 px-1 rounded-full bg-error text-white text-[10px] font-bold leading-4 animate-pulse"
          >
            {@alert_count}{if @alert_capped?, do: "+"}
          </span>
        </.link>
      </div>
    </li>
    """
  end
end
