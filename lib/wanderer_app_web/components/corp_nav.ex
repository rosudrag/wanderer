defmodule WandererAppWeb.CorpNav do
  @moduledoc """
  Chewy-owned sidebar entry for the `/corp` scope. New, not `layouts.ex` —
  every later phase adds nav entries here, never touching
  `sidebar_nav_links/1` again after this file's introduction. See
  docs/chewy/corp-suite-plan.md §9 Phase 0 hook #5.
  """
  use WandererAppWeb, :html

  attr :corp_flags, :map, required: true
  attr :active_tab, :atom
  attr :show_sidebar, :boolean

  def corp_nav_links(assigns) do
    ~H"""
    <div :if={@corp_flags[:identity_suite_enabled?] and @show_sidebar}>
      <.link
        navigate={~p"/corp/identity"}
        class={[
          "flex-1 w-full h-14 block text-gray-400 hover:text-white p-3 tooltip tooltip-right",
          @active_tab == :corp && "text-white"
        ]}
        data-tip="Corp"
      >
        <.icon name="hero-identification-solid" class="w-6 h-6" />
      </.link>
    </div>
    """
  end
end
