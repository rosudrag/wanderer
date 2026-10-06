defmodule WandererAppWeb.Router do
  use WandererAppWeb, :router
  use ErrorTracker.Web, :router
  use Plug.ErrorHandler

  import PlugDynamic.Builder

  import WandererAppWeb.UserAuth,
    warn: false,
    only: [redirect_if_user_is_authenticated: 2, require_authenticated_user: 2]

  import WandererAppWeb.BasicAuth,
    warn: false,
    only: [admin_basic_auth: 2]

  # import WandererAppWeb.Plugs.LicenseAuth,
  #   warn: false,
  #   only: [authenticate_lm: 2, authenticate_license: 2]

  @code_reloading Application.compile_env(
                    :wanderer_app,
                    [WandererAppWeb.Endpoint, :code_reloader],
                    false
                  )
  @frame_src_values if(@code_reloading, do: ["'self'"], else: [])

  # Define style sources individually to ensure proper spacing
  @style_src_values [
    "'self'",
    "'unsafe-inline'",
    "https://fonts.googleapis.com",
    "https://cdn.jsdelivr.net/npm/",
    "https://cdnjs.cloudflare.com/ajax/libs/"
  ]

  # Define image sources individually to ensure proper spacing
  @img_src_values [
    "'self'",
    "data:",
    "https://images.evetech.net",
    "https://web.ccpgamescdn.com",
    "https://images.ctfassets.net",
    "https://wanderer-industries.github.io",
    "https://w.appzi.io"
  ]

  # Define font sources individually to ensure proper spacing
  @font_src_values [
    "'self'",
    "https://fonts.gstatic.com",
    "data:",
    "https://web.ccpgamescdn.com",
    "https://w.appzi.io"
  ]

  # Define script sources individually to ensure proper spacing
  @script_src_values [
    "'self'",
    "'unsafe-inline'",
    "https://cdn.jsdelivr.net/npm/",
    "https://cdnjs.cloudflare.com/ajax/libs/",
    "https://unpkg.com",
    "https://cdn.jsdelivr.net",
    "https://w.appzi.io",
    "https://www.googletagmanager.com",
    "https://cdnjs.cloudflare.com"
  ]

  # Define connect sources individually to ensure proper spacing
  @connect_src_values [
    "'self'",
    "https://api.appzi.io",
    "https://www.googletagmanager.com",
    "https://www.google-analytics.com",
    "https://*.google-analytics.com"
  ]

  # Define sandbox values individually to ensure proper spacing
  @sandbox_values [
    "allow-forms",
    "allow-scripts",
    "allow-modals",
    "allow-same-origin",
    "allow-downloads",
    "allow-popups",
    "allow-popups-to-escape-sandbox"
  ]

  pipeline :admin_bauth do
    plug :admin_basic_auth
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WandererAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers

    dynamic_plug PlugContentSecurityPolicy, reevaluate: :first_usage do
      URI.default_port("wss", 443)
      URI.default_port("ws", 80)

      home_url = URI.parse(WandererAppWeb.Endpoint.url())

      ws_url =
        home_url
        |> Map.update!(:scheme, fn
          "http" -> "ws"
          "https" -> "wss"
        end)
        |> Map.put(:path, "")
        |> URI.to_string()

      # Get the HTTP URL from home_url
      http_url = URI.to_string(home_url)

      # Only add script-src-elem when in development mode
      script_src_elem =
        if(@code_reloading,
          do: @script_src_values ++ [ws_url, http_url],
          else: @script_src_values
        )

      directives = %{
        default_src: ~w('none'),
        script_src: @script_src_values ++ [ws_url],
        style_src: @style_src_values,
        img_src: @img_src_values,
        font_src: @font_src_values,
        connect_src: @connect_src_values ++ [ws_url],
        media_src: ~w('none'),
        object_src: ~w('none'),
        child_src: ~w('none'),
        frame_src: @frame_src_values,
        worker_src: ~w('none'),
        frame_ancestors: ~w('none'),
        form_action: ~w('self'),
        block_all_mixed_content: ~w(),
        sandbox: @sandbox_values,
        base_uri: ~w('none'),
        manifest_src: ~w('self')
      }

      # Only add script-src-elem to directives when in development mode
      directives = Map.put(directives, :script_src_elem, script_src_elem)

      directives =
        case home_url do
          %URI{scheme: "http"} -> directives
          %URI{scheme: "https"} -> Map.put(directives, :upgrade_insecure_requests, ~w())
        end

      [
        directives: directives
      ]
    end

    plug WandererAppWeb.Plugs.SetUser
  end

  pipeline :blog do
    plug :put_layout, html: {WandererAppWeb.Layouts, :blog}
  end

  pipeline :require_auth do
    plug :require_authenticated_user
  end

  pipeline :api do
    plug WandererAppWeb.Plugs.ContentNegotiation, accepts: ["json"]
    plug :accepts, ["json"]
    plug WandererAppWeb.Plugs.CheckApiDisabled
  end

  # Versioned API pipeline with enhanced security and validation
  pipeline :api_versioned do
    plug WandererAppWeb.Plugs.ContentNegotiation, accepts: ["json"]
    plug :accepts, ["json"]
    plug WandererAppWeb.Plugs.CheckApiDisabled
    plug WandererAppWeb.Plugs.RequestValidator
    plug WandererAppWeb.Plugs.ApiVersioning
    plug WandererAppWeb.Plugs.ResponseSanitizer
  end

  pipeline :api_map do
    plug WandererAppWeb.Plugs.CheckMapApiKey
    plug WandererAppWeb.Plugs.CheckMapSubscription
    plug WandererAppWeb.Plugs.AssignMapOwner
  end

  pipeline :api_sse do
    plug WandererAppWeb.Plugs.CheckApiDisabled
    plug WandererAppWeb.Plugs.CheckSseDisabled
    plug WandererAppWeb.Plugs.CheckMapApiKey
    plug WandererAppWeb.Plugs.CheckMapSubscription
    plug WandererAppWeb.Plugs.AssignMapOwner
  end

  pipeline :api_kills do
    plug WandererAppWeb.Plugs.CheckApiDisabled
  end

  pipeline :api_character do
    plug WandererAppWeb.Plugs.CheckCharacterApiDisabled
  end

  pipeline :api_webhooks do
    plug WandererAppWeb.Plugs.CheckWebhooksDisabled
  end

  # CHEWY PATCH: scanner-client signature sync. See
  # WandererAppWeb.Plugs.CheckBotSyncDisabled and
  # WandererApp.Map.Operations.SignatureSync.
  pipeline :api_bot_sync do
    plug WandererAppWeb.Plugs.CheckBotSyncDisabled
  end

  # CHEWY PATCH: scout intel log ingest. See
  # WandererAppWeb.Plugs.CheckScoutIntelDisabled and WandererApp.Scout.Ingest.
  pipeline :api_scout_intel do
    plug WandererAppWeb.Plugs.CheckScoutIntelDisabled
  end

  # CHEWY PATCH: scout coverage ingest. See
  # WandererAppWeb.Plugs.CheckScoutCoverageDisabled and
  # WandererApp.Scout.Coverage. Own pipeline (not :api_scout_intel) so the
  # two features can be flagged independently.
  pipeline :api_scout_coverage do
    plug WandererAppWeb.Plugs.CheckScoutCoverageDisabled
  end

  # CHEWY PATCH: scout presence snapshot ingest (requires
  # WANDERER_SCOUT_PRESENCE=true). Own pipeline, deliberately NOT folded
  # into :api_scout_intel: the two features gate independently, and the
  # presence feed is the structure-only successor to the per-row
  # structure feed, not an extension of it.
  pipeline :api_scout_presence do
    plug WandererAppWeb.Plugs.CheckScoutPresenceDisabled
  end

  # CHEWY PATCH: scout plan endpoint (ranking + route). See
  # WandererAppWeb.Plugs.CheckScoutPlannerDisabled and
  # WandererApp.Scout.Planner. Own pipeline, same reasoning as the
  # coverage/presence pipelines above: independent flag, independent
  # route.
  pipeline :api_scout_planner do
    plug WandererAppWeb.Plugs.CheckScoutPlannerDisabled
  end

  # CHEWY PATCH: same flag, browser side (the /scout pages). Separate from
  # :api_scout_intel only because the two are piped after different base
  # pipelines.
  pipeline :scout_intel do
    plug WandererAppWeb.Plugs.CheckScoutIntelDisabled
  end

  # CHEWY PATCH: identity/state/groups suite. See
  # WandererAppWeb.Plugs.CheckIdentitySuiteDisabled and
  # docs/chewy/corp-suite-plan.md §9 Phase 0.
  pipeline :corp do
    plug WandererAppWeb.Plugs.CheckIdentitySuiteDisabled
  end

  pipeline :api_acl do
    plug WandererAppWeb.Plugs.CheckAclApiKey
  end

  pipeline :api_spec do
    plug OpenApiSpex.Plug.PutApiSpec,
      otp_app: :wanderer_app,
      module: WandererAppWeb.ApiSpec
  end

  pipeline :api_spec_v1 do
    plug OpenApiSpex.Plug.PutApiSpec,
      otp_app: :wanderer_app,
      module: WandererAppWeb.OpenApiV1Spec
  end

  pipeline :api_spec_combined do
    plug OpenApiSpex.Plug.PutApiSpec,
      otp_app: :wanderer_app,
      module: WandererAppWeb.ApiSpecV1
  end

  # New v1 API pipeline for ash_json_api
  pipeline :api_v1 do
    plug WandererAppWeb.Plugs.ContentNegotiation, accepts: ["json"]
    plug :accepts, ["json", "json-api"]
    plug :fetch_session
    plug WandererAppWeb.Plugs.CheckApiDisabled
    plug WandererAppWeb.Plugs.JsonApiPerformanceMonitor
    plug WandererAppWeb.Plugs.CheckJsonApiAuth
    # Future: Add rate limiting, advanced permissions, etc.
  end

  # pipeline :api_license_management do
  #   plug :authenticate_lm
  # end

  # pipeline :api_license_validation do
  #   plug :authenticate_license
  # end

  scope "/api/map/systems-kills", WandererAppWeb do
    pipe_through [:api, :api_map, :api_kills]

    get "/", MapAPIController, :list_systems_kills
  end

  scope "/api/map", WandererAppWeb do
    pipe_through [:api, :api_map]
    get "/audit", MapAuditAPIController, :index
    # Deprecated routes - use /api/maps/:map_identifier/systems instead
    get "/systems", MapSystemAPIController, :list_systems
    get "/system", MapSystemAPIController, :show_system
    get "/connections", MapConnectionAPIController, :list_all_connections
    get "/characters", MapAPIController, :list_tracked_characters
    get "/structure-timers", MapAPIController, :show_structure_timers
    get "/character-activity", MapAPIController, :character_activity
    get "/user_characters", MapAPIController, :user_characters

    get "/acls", MapAccessListAPIController, :index
    post "/acls", MapAccessListAPIController, :create
  end

  #
  # SSE endpoint for real-time events (uses separate pipeline without accepts restriction)
  #
  scope "/api/maps/:map_identifier", WandererAppWeb do
    pipe_through [:api_sse]

    get "/events/stream", Api.EventsController, :stream
  end

  #
  # Unified RESTful routes for systems & connections by slug or ID
  #
  scope "/api/maps/:map_identifier", WandererAppWeb do
    pipe_through [:api, :api_map]

    # Map duplication endpoint
    post "/duplicate", MapAPIController, :duplicate_map

    # Map contents export/import
    get "/export", MapAPIController, :export_map
    post "/import", MapAPIController, :import_map

    patch "/connections", MapConnectionAPIController, :update
    delete "/connections", MapConnectionAPIController, :delete
    delete "/systems", MapSystemAPIController, :delete_batch
    resources "/systems", MapSystemAPIController, only: [:index, :show, :create, :update, :delete]

    resources "/connections", MapConnectionAPIController,
      only: [:index, :show, :create, :update, :delete],
      param: "id"

    resources "/structures", MapSystemStructureAPIController, except: [:new, :edit]
    get "/structure-timers", MapSystemStructureAPIController, :structure_timers
    resources "/signatures", MapSystemSignatureAPIController, except: [:new, :edit]
    post "/signatures/:id/link", MapSystemSignatureAPIController, :link
    delete "/signatures/:id/link", MapSystemSignatureAPIController, :unlink
    get "/user-characters", MapAPIController, :show_user_characters
    get "/tracked-characters", MapAPIController, :show_tracked_characters
  end

  # Webhook management endpoints (requires WANDERER_WEBHOOKS_ENABLED=true)
  scope "/api/maps/:map_identifier", WandererAppWeb do
    pipe_through [:api, :api_map, :api_webhooks]

    get "/events", MapEventsAPIController, :list_events

    # This static route must precede the resource routes so "toggle" is not parsed as :id.
    put "/webhooks/toggle", MapAPIController, :toggle_webhooks

    # Webhook management endpoints
    resources "/webhooks", MapWebhooksAPIController, except: [:new, :edit] do
      post "/rotate-secret", MapWebhooksAPIController, :rotate_secret
    end
  end

  # CHEWY PATCH: scanner-client signature sync (requires WANDERER_BOT_SYNC=true).
  # Its own scope rather than a line inside the big /api/maps block above, so an
  # upstream edit to that block never conflicts with ours. POST /signatures/sync
  # cannot collide with the `resources "/signatures"` routes there: those
  # generate POST only on the collection root, never on a sub-path.
  scope "/api/maps/:map_identifier", WandererAppWeb do
    pipe_through [:api, :api_map, :api_bot_sync]

    post "/signatures/sync", MapSignatureSyncAPIController, :sync
  end

  # CHEWY PATCH: scout intel ingest (requires WANDERER_SCOUT_INTEL=true). Own
  # scope, same reasoning as the signature-sync block above. Rides :api_map so
  # the bot authenticates with the map public_api_key it already holds; the
  # stored log is not map-scoped, the map is recorded as provenance only.
  scope "/api/maps/:map_identifier", WandererAppWeb do
    pipe_through [:api, :api_map, :api_scout_intel]

    post "/scout/spawns", ScoutIntelAPIController, :spawns
    post "/scout/structures", ScoutIntelAPIController, :structures
  end

  # CHEWY PATCH: scout coverage ingest (requires WANDERER_SCOUT_COVERAGE=true).
  # Own scope, deliberately NOT folded into the scout-intel scope above: the
  # two flags gate independently, and widening that scope would mean this
  # route goes live (or dark) by accident whenever someone flips
  # WANDERER_SCOUT_INTEL. Rides :api_map so the bot authenticates with the
  # map public_api_key it already holds; coverage is not map-scoped, the map
  # is recorded as provenance only. See WandererApp.Api.ScoutSystemCoverage.
  scope "/api/maps/:map_identifier", WandererAppWeb do
    pipe_through [:api, :api_map, :api_scout_coverage]

    post "/scout/coverage", ScoutCoverageAPIController, :coverage
  end

  # CHEWY PATCH: scout presence snapshot ingest (requires
  # WANDERER_SCOUT_PRESENCE=true). Own scope, same reasoning as the
  # coverage scope above: independent flag, independent route. Rides
  # :api_map so the bot authenticates with the map public_api_key it
  # already holds; stored state is not map-scoped, the map is recorded
  # as provenance only. See WandererApp.Scout.Snapshot.
  scope "/api/maps/:map_identifier", WandererAppWeb do
    pipe_through [:api, :api_map, :api_scout_presence]

    post "/scout/structures/snapshot", ScoutSnapshotAPIController, :snapshot
  end

  # CHEWY PATCH: scout plan endpoint (requires WANDERER_SCOUT_PLANNER=true).
  # Rides :api_map so the bot authenticates with the map public_api_key it
  # already holds -- the :map_identifier in the path is authentication, not
  # scope (docs/design/wanderer-scout-planner.md section 7); origin and
  # scope decide which systems are ranked. See WandererApp.Scout.Planner.
  scope "/api/maps/:map_identifier", WandererAppWeb do
    pipe_through [:api, :api_map, :api_scout_planner]

    get "/scout/plan", ScoutPlanAPIController, :plan

    # The same plan, pushed onto one character's autopilot through ESI --
    # the only way a multi-stop CUSTOM route can be set at all (the game
    # client can set a single destination, not an ordered list). POST,
    # because unlike the read above it changes what a pilot sees.
    post "/scout/plan/waypoints", ScoutPlanAPIController, :waypoints
  end

  #
  # Other API routes
  #
  scope "/api/characters", WandererAppWeb do
    pipe_through [:api, :api_character]
    get "/", CharactersAPIController, :index
  end

  scope "/api/acls", WandererAppWeb do
    pipe_through [:api, :api_acl]

    get "/:id", MapAccessListAPIController, :show
    put "/:id", MapAccessListAPIController, :update
    post "/:acl_id/members", AccessListMemberAPIController, :create
    put "/:acl_id/members/:member_id", AccessListMemberAPIController, :update_role
    delete "/:acl_id/members/:member_id", AccessListMemberAPIController, :delete
  end

  scope "/api/common", WandererAppWeb do
    pipe_through [:api]
    get "/system-static-info", CommonAPIController, :show_system_static
  end

  scope "/route", WandererAppWeb do
    pipe_through [:api]
    post "/findClosest", RouteBuilderController, :find_closest
  end

  scope "/api" do
    pipe_through [:api_spec]
    get "/openapi", OpenApiSpex.Plug.RenderSpec, :show
  end

  # Combined spec needs its own pipeline
  scope "/api" do
    pipe_through [:api_spec_combined]
    get "/openapi-complete", OpenApiSpex.Plug.RenderSpec, :show
  end

  scope "/api/v1" do
    pipe_through [:api_spec_v1]
    # v1 JSON:API spec (bypasses authentication)
    get "/open_api", OpenApiSpex.Plug.RenderSpec, :show
  end

  #
  # Health Check Endpoints
  # Used for monitoring, load balancer health checks, and deployment validation
  #
  scope "/api", WandererAppWeb do
    pipe_through [:api]
  end

  # scope "/api/licenses", WandererAppWeb do
  #   pipe_through [:api, :api_license_management]

  #   post "/", LicenseApiController, :create
  #   put "/:id/validity", LicenseApiController, :update_validity
  #   put "/:id/expiration", LicenseApiController, :update_expiration
  #   get "/map/:map_id", LicenseApiController, :get_by_map_id
  # end

  # scope "/api/license", WandererAppWeb do
  #   pipe_through [:api, :api_license_validation]

  #   get "/validate", LicenseApiController, :validate
  # end

  #
  # Browser / blog stuff
  #
  scope "/", WandererAppWeb do
    pipe_through [:browser, :blog, :redirect_if_user_is_authenticated]
    get "/welcome", BlogController, :index
  end

  scope "/contacts", WandererAppWeb do
    pipe_through [:browser, :blog]
    get "/", BlogController, :contacts
  end

  scope "/changelog", WandererAppWeb do
    pipe_through [:browser, :blog]
    get "/", BlogController, :changelog
  end

  scope "/news", WandererAppWeb do
    pipe_through [:browser, :blog]
    get "/:slug", BlogController, :show
    get "/", BlogController, :list
  end

  scope "/license", WandererAppWeb do
    pipe_through [:browser, :blog]
    get "/", BlogController, :license
  end

  scope "/swaggerui" do
    pipe_through [:browser, :api_spec]

    # v1 JSON:API (AshJsonApi generated)
    get "/v1", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/v1/open_api",
      title: "WandererApp v1 JSON:API Docs",
      css_urls: [
        # Standard Swagger UI CSS
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui.min.css",
        # Material theme from swagger-ui-themes (v3.x):
        "https://cdn.jsdelivr.net/npm/swagger-ui-themes@3.0.0/themes/3.x/theme-material.css"
      ],
      js_urls: [
        # We need both main JS & standalone preset for full styling
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui-bundle.min.js",
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui-standalone-preset.min.js"
      ],
      swagger_ui_config: %{
        "docExpansion" => "none",
        "deepLinking" => true,
        "tagsSorter" => "alpha",
        "operationsSorter" => "alpha"
      }

    # Legacy API only
    get "/legacy", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/openapi",
      title: "WandererApp Legacy API Docs",
      css_urls: [
        # Standard Swagger UI CSS
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui.min.css",
        # Material theme from swagger-ui-themes (v3.x):
        "https://cdn.jsdelivr.net/npm/swagger-ui-themes@3.0.0/themes/3.x/theme-material.css"
      ],
      js_urls: [
        # We need both main JS & standalone preset for full styling
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui-bundle.min.js",
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui-standalone-preset.min.js"
      ],
      swagger_ui_config: %{
        "docExpansion" => "none",
        "deepLinking" => true
      }

    # Complete API (Legacy + v1)
    get "/", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/openapi-complete",
      title: "WandererApp Complete API Docs (Legacy & v1)",
      css_urls: [
        # Standard Swagger UI CSS
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui.min.css",
        # Material theme from swagger-ui-themes (v3.x):
        "https://cdn.jsdelivr.net/npm/swagger-ui-themes@3.0.0/themes/3.x/theme-material.css"
      ],
      js_urls: [
        # We need both main JS & standalone preset for full styling
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui-bundle.min.js",
        "https://cdnjs.cloudflare.com/ajax/libs/swagger-ui/4.5.0/swagger-ui-standalone-preset.min.js"
      ],
      swagger_ui_config: %{
        "docExpansion" => "none",
        "deepLinking" => true,
        "tagsSorter" => "alpha",
        "operationsSorter" => "alpha"
      }
  end

  #
  # Auth
  #
  scope "/auth", WandererAppWeb do
    pipe_through :browser
    get "/signout", AuthController, :signout
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  # CHEWY PATCH: dev-only authentication bypass so an agentic developer can
  # exercise the map UI without an EVE Online account / EVE SSO. The route
  # exists unconditionally; WandererAppWeb.DevAuthController refuses (404)
  # unless WANDERER_DEV_AUTH_TOKEN is configured.
  scope "/dev", WandererAppWeb do
    pipe_through :browser
    get "/login", DevAuthController, :login
  end

  # CHEWY PATCH: identity/state/groups suite. Route exists unconditionally
  # (routes compile before config/runtime.exs runs -- see
  # WandererAppWeb.Plugs.CheckIdentitySuiteDisabled's moduledoc);
  # WANDERER_IDENTITY_SUITE=false makes every request in this scope 404.
  # Later phases add routes inside this same live_session, not a new one.
  scope "/corp", WandererAppWeb do
    pipe_through [:browser, :corp]

    live_session :corp,
      on_mount: [
        {WandererAppWeb.UserAuth, :ensure_authenticated},
        WandererAppWeb.Nav
      ] do
      live "/", CorpManagementLive, :index
      live "/identity", CorpIdentityLive, :index
      live "/map-grants", GroupMapGrantsLive, :index
    end
  end

  # CHEWY PATCH: scout intel log. A TOP-LEVEL scope, not a /corp sub-route:
  # it is not part of the corp suite (its permission is granted by the
  # instance owner, not by a corp admin) and it has its own sidebar entry,
  # so nesting it under /corp would have meant a page reachable only by
  # knowing the URL. Gated by WANDERER_SCOUT_INTEL for the scope, and by
  # WandererApp.Identity.ScoutAccess inside each mount/3.
  scope "/scout", WandererAppWeb do
    pipe_through [:browser, :scout_intel]

    live_session :scout,
      on_mount: [
        {WandererAppWeb.UserAuth, :ensure_authenticated},
        WandererAppWeb.Nav
      ] do
      live "/", ScoutIntelLive, :structures
      live "/structures", ScoutIntelLive, :structures
      live "/spawns", ScoutIntelLive, :spawns
      live "/planner", ScoutIntelLive, :planner
      live "/access", ScoutAccessLive, :index
    end

    # Not a LiveView, so the live_session's auth gate does not cover it:
    # ScoutExportController re-checks both the login and the permission.
    get "/export.csv", ScoutExportController, :export
  end

  #
  # Admin
  #
  scope "/admin", WandererAppWeb do
    pipe_through(:browser)
    pipe_through(:admin_bauth)

    live_session :admin,
      on_mount: [
        {WandererAppWeb.UserAuth, :ensure_authenticated},
        {WandererAppWeb.UserAuth, :ensure_admin},
        WandererAppWeb.Nav
      ] do
      live("/", AdminLive, :index)
      live("/invite", AdminLive, :add_invite_link)
      live("/maps", AdminMapsLive, :index)
      live("/maps/:id/edit", AdminMapsLive, :edit)
      live("/maps/:id/acls", AdminMapsLive, :view_acls)
      live("/characters", AdminCharactersLive, :index)
    end

    error_tracker_dashboard("/errors",
      on_mount: [
        {WandererAppWeb.UserAuth, :ensure_authenticated},
        {WandererAppWeb.UserAuth, :ensure_admin}
      ]
    )
  end

  #
  # Additional routes / Live sessions
  #
  scope "/", WandererAppWeb do
    pipe_through(:browser)

    get "/", RedirectController, :redirect_authenticated
    get "/last", MapsController, :last

    live_session :authenticated,
      on_mount: [
        {WandererAppWeb.UserAuth, :ensure_authenticated},
        WandererAppWeb.Nav
      ] do
      live "/access-lists/new", AccessListsLive, :create
      live "/access-lists/:id/edit", AccessListsLive, :edit
      live "/access-lists/:id/add-members", AccessListsLive, :add_members
      live "/access-lists/:id", AccessListsLive, :members
      live "/access-lists", AccessListsLive, :index

      live "/coming-soon", ComingLive, :index
      live "/tracking/:slug", CharactersTrackingLive, :characters
      live "/tracking", CharactersTrackingLive, :index
      live "/characters", CharactersLive, :index
      live "/characters/authorize", CharactersLive, :authorize
      live "/characters/:eve_id", CharacterProfileLive, :show
      live "/sponsors", SponsorsLive, :index
      live "/maps/new", MapsLive, :create
      live "/maps/:slug/edit", MapsLive, :edit
      live "/maps/:slug/settings", MapsLive, :settings
      live "/maps", MapsLive, :index
      live "/profile", ProfileLive, :index
      live "/profile/deposit", ProfileLive, :deposit
      live "/profile/subscribe", ProfileLive, :subscribe
      live "/:slug/audit", MapAuditLive, :index
      live "/:slug/characters", MapCharactersLive, :index
      live "/:slug", MapLive, :index
    end
  end

  if Application.compile_env(:wanderer_app, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      error_tracker_dashboard("/errors", as: :error_tracker_dev_dashboard)
      live_dashboard("/dashboard", metrics: WandererAppWeb.Telemetry)
    end
  end

  #
  # Versioned API Routes with backward compatibility
  # These routes handle version negotiation and provide enhanced features per version
  # Note: These are experimental routes for testing the versioning system
  #
  scope "/api/versioned" do
    pipe_through :api_versioned

    # Version-aware routes handled by ApiRouter
    forward "/", WandererAppWeb.ApiRouter
  end

  #
  # JSON:API v1 Routes (ash_json_api)
  # These routes provide a modern JSON:API compliant interface
  # while maintaining 100% backward compatibility with existing /api/* routes
  #
  scope "/api/v1" do
    pipe_through :api_v1

    # Custom combined endpoint with map_id in path
    get "/maps/:map_id/systems_and_connections",
        WandererAppWeb.Api.MapSystemsConnectionsController,
        :show

    # Forward all v1 requests to AshJsonApi router
    # This will automatically generate RESTful JSON:API endpoints
    # for all Ash resources once they're configured with the AshJsonApi extension
    #
    # NOTE: AshJsonApi generates flat routes (e.g., /api/v1/map_systems)
    # Phoenix's `forward` cannot be used with dynamic path segments, so proper
    # nested routes like /api/v1/maps/{id}/systems would require custom controllers.
    #
    # Current approach: Use flat routes with map_id in request body or filters:
    #   - POST /api/v1/map_systems with {"data": {"attributes": {"map_id": "..."}}}
    #   - GET /api/v1/map_systems?filter[map_id]=...
    #   - PATCH /api/v1/map_systems/{id} with map_id in body
    #
    # Authentication is handled by CheckJsonApiAuth which validates the Bearer
    # token against the map's API key.
    forward "/", WandererAppWeb.ApiV1Router
  end
end
