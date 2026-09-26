# CHEWY PATCH: single source of brand strings for the private ChewyTech
# instance. Every caller that shows a product name/tagline/copyright line
# goes through here instead of hard-coding "Wanderer" so the fork can be
# re-skinned without touching upstream copy in a dozen templates.
defmodule WandererApp.Branding do
  @moduledoc """
  Single source of truth for brand strings, gated by
  `WandererApp.Env.private_branding?/0`.

  When `WANDERER_PRIVATE_BRANDING` is unset (default), every function here
  returns upstream Wanderer copy byte-for-byte. When it is `"true"`, the
  instance presents itself as "ChewyTech" and disables the public news
  surface and upstream analytics.
  """

  alias WandererApp.Env

  @doc "True when this instance is running under private ChewyTech branding."
  def private?(), do: Env.private_branding?()

  @doc "Product name shown in nav/chrome."
  def name(), do: if(private?(), do: "ChewyTech", else: "Wanderer")

  @doc "Tagline shown on the landing page."
  def tagline(), do: if(private?(), do: "EVE Online Assistant", else: "THE #1 EVE MAPPER TOOL")

  @doc "Suffix appended to `<title>` via `<.live_title>`."
  def title_suffix(), do: if(private?(), do: " · ChewyTech", else: " · Wanderer")

  @doc "Entity named in the footer copyright line."
  def copyright_holder(), do: if(private?(), do: "ChewyTech", else: "Wanderer Industries")

  @doc "Whether the public news board (`/news`) and contact page are reachable."
  def news_enabled?(), do: not private?()

  @doc "Whether upstream's Google Analytics tags should be emitted."
  def analytics_enabled?(), do: not private?()

  @doc """
  Whether upstream's community/funding links (YouTube, Patreon, Discord,
  the `/sponsors` nav entry) should be advertised. A private instance has
  no ChewyTech equivalents for these — they are just hidden, not replaced.
  """
  def community_links?(), do: not private?()
end
