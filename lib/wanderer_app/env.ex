defmodule WandererApp.Env do
  @moduledoc false
  use Nebulex.Caching

  @app :wanderer_app

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "vsn_version"
            )
  def vsn(), do: Application.spec(@app)[:vsn]

  def git_sha(), do: get_key(:git_sha, "<GIT_SHA>")
  def base_url(), do: get_key(:web_app_url, "<BASE_URL>")
  def base_metrics_only(), do: get_key(:base_metrics_only, false)
  def custom_route_base_url(), do: get_key(:custom_route_base_url, "<CUSTOM_ROUTE_BASE_URL>")
  def invites(), do: get_key(:invites, false)
  # CHEWY PATCH: keep DB-tracked characters polling while no browser is open.
  # See WandererApp.Map.PersistentTracking.
  def persist_tracking?(), do: get_key(:persist_tracking, false)
  # CHEWY PATCH: map beautifier / tidy-insert layout feature flags, default off.
  def map_beautifier?(), do: get_key(:map_beautifier, false)
  def tidy_insert?(), do: get_key(:tidy_insert, false)
  # CHEWY PATCH: cells of clearance between a wormhole chain and the k-space
  # system it hangs off, for both the beautifier and tidy insert. 0 (default)
  # is upstream behaviour: a scanned hole lands in the cell next to its origin.
  def chain_standoff_cells(), do: get_key(:chain_standoff_cells, 0)
  # CHEWY PATCH: keep map_chain_v1.count_of_passage current and broadcast it,
  # so the UI can weight a connection by how much it is actually used.
  # See WandererApp.Map.ConnectionTraffic.
  def connection_traffic?(), do: get_key(:connection_traffic, false)

  # CHEWY PATCH: DEV-ONLY authentication bypass token for exercising the map
  # UI without EVE SSO (see WandererAppWeb.DevAuthController). Config always
  # stores a string (default ""); normalised to nil here so callers can
  # `is_binary/1`-guard directly instead of special-casing the empty string.
  def dev_auth_token() do
    case get_key(:dev_auth_token, "") do
      "" -> nil
      token -> token
    end
  end

  # CHEWY PATCH: DEV-ONLY authentication bypass. True only when a dev-auth
  # token of at least 16 bytes is configured. MUST stay false unless an
  # operator explicitly opts in via WANDERER_DEV_AUTH_TOKEN — no default, no
  # boolean flag that could be flipped by accident.
  def dev_auth_enabled?() do
    case dev_auth_token() do
      token when is_binary(token) -> byte_size(token) >= 16
      _ -> false
    end
  end

  def map_subscriptions_enabled?(), do: get_key(:map_subscriptions_enabled, false)
  def public_api_disabled?(), do: get_key(:public_api_disabled, false)

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "active_tracking_pool"
            )
  def active_tracking_pool(), do: get_key(:active_tracking_pool, "default")

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "tracking_pool_max_size"
            )
  def tracking_pool_max_size(), do: get_key(:tracking_pool_max_size, 300)
  def character_tracking_pause_disabled?(), do: get_key(:character_tracking_pause_disabled, true)
  def character_api_disabled?(), do: get_key(:character_api_disabled, false)
  def wanderer_kills_service_enabled?(), do: get_key(:wanderer_kills_service_enabled, false)
  def wallet_tracking_enabled?(), do: get_key(:wallet_tracking_enabled, false)
  def admins(), do: get_key(:admins, [])
  def admin_username(), do: get_key(:admin_username)
  def admin_password(), do: get_key(:admin_password)
  def corp_wallet(), do: get_key(:corp_wallet, "")
  def corp_wallet_eve_id(), do: get_key(:corp_wallet_eve_id, "-1")
  def corp_eve_id(), do: get_key(:corp_id, -1)
  def subscription_settings(), do: get_key(:subscription_settings)

  @doc """
  Returns the promo code configuration map.
  Keys are uppercase code strings, values are discount percentages.
  """
  def promo_codes() do
    case subscription_settings() do
      %{promo_codes: codes} when is_map(codes) -> codes
      _ -> %{}
    end
  end

  @doc """
  Validates a promo code and returns the discount percentage.
  Returns {:ok, discount_percent} if valid, {:error, :invalid_code} otherwise.
  Codes are case-insensitive.
  """
  def validate_promo_code(nil), do: {:error, :invalid_code}
  def validate_promo_code(""), do: {:error, :invalid_code}

  def validate_promo_code(code) when is_binary(code) do
    normalized = String.upcase(String.trim(code))

    case Map.get(promo_codes(), normalized) do
      nil -> {:error, :invalid_code}
      discount when is_integer(discount) and discount > 0 and discount <= 100 -> {:ok, discount}
      _ -> {:error, :invalid_code}
    end
  end

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "restrict_maps_creation"
            )
  def restrict_maps_creation?(), do: get_key(:restrict_maps_creation, false)

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "restrict_acls_creation"
            )
  def restrict_acls_creation?(), do: get_key(:restrict_acls_creation, false)

  def sse_enabled?() do
    Application.get_env(@app, :sse, [])
    |> Keyword.get(:enabled, false)
  end

  def webhooks_enabled?() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:webhooks_enabled, false)
  end

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "map-connection-auto-expire-hours"
            )
  def map_connection_auto_expire_hours(), do: get_key(:map_connection_auto_expire_hours)

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "map-connection-auto-eol-hours"
            )
  def map_connection_auto_eol_hours(), do: get_key(:map_connection_auto_eol_hours)

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "map-connection-eol-expire-timeout-mins"
            )
  def map_connection_eol_expire_timeout_mins(),
    do: get_key(:map_connection_eol_expire_timeout_mins)

  def get_key(key, default \\ nil), do: Application.get_env(@app, key, default)

  @doc """
  A single map containing environment variables
  made available to react
  """
  def to_client_env() do
    %{detailedKillsDisabled: not wanderer_kills_service_enabled?()}
  end
end
