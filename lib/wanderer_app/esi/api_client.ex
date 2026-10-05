defmodule WandererApp.Esi.ApiClient do
  use Nebulex.Caching
  @moduledoc false

  require Logger
  alias WandererApp.Cache

  @ttl :timer.hours(1)

  @wanderrer_user_agent "(wanderer-industries@proton.me; +https://github.com/wanderer-industries/wanderer)"

  @cache_opts [cache: true]
  @retry_opts [retry: false, retry_log_level: :warning]
  @timeout_opts [pool_timeout: 15_000, receive_timeout: :timer.minutes(1)]
  @api_retry_count 1

  @logger Application.compile_env(:wanderer_app, :logger)

  # Pool selection for different operation types
  # Character tracking operations use dedicated high-capacity pool
  @character_tracking_pool WandererApp.Finch.ESI.CharacterTracking
  # General ESI operations use standard pool
  @general_pool WandererApp.Finch.ESI.General

  # Helper function to get Req options with appropriate Finch pool
  defp req_options_for_pool(pool) do
    [base_url: "https://esi.evetech.net", finch: pool]
  end

  def get_server_status, do: do_get("/status", [], @cache_opts)

  def set_autopilot_waypoint(add_to_beginning, clear_other_waypoints, destination_id, opts \\ []),
    do:
      do_post_esi(
        "/ui/autopilot/waypoint",
        get_auth_opts(opts)
        |> Keyword.merge(
          params: %{
            add_to_beginning: add_to_beginning,
            clear_other_waypoints: clear_other_waypoints,
            destination_id: destination_id
          }
        )
      )

  def post_characters_affiliation(character_eve_ids, _opts)
      when is_list(character_eve_ids),
      do:
        do_post_esi(
          "/characters/affiliation/",
          [
            json: character_eve_ids,
            params: %{
              datasource: "tranquility"
            }
          ],
          @character_tracking_pool
        )

  def get_routes_custom(hubs, origin, params),
    do:
      do_post(
        "#{get_custom_route_base_url()}/route/multiple",
        [
          json: %{
            origin: origin,
            destinations: hubs,
            flag: params.flag,
            connections: params.connections,
            avoid: params.avoid
          }
        ]
        |> Keyword.merge(@timeout_opts)
      )

  def get_routes_eve(hubs, origin, _params, _opts),
    do:
      {:ok,
       hubs
       |> Task.async_stream(
         fn destination ->
           %{
             "origin" => origin,
             "destination" => destination,
             "systems" => [],
             "success" => false
           }

           # do_get_routes_eve(origin, destination, params, opts)
         end,
         max_concurrency: System.schedulers_online() * 4,
         timeout: :timer.seconds(30),
         on_timeout: :kill_task
       )
       |> Enum.map(fn result ->
         case result do
           {:ok, val} -> val
           {:error, error} -> {:error, error}
           _ -> {:error, :failed}
         end
       end)}

  @decorate cacheable(
              cache: Cache,
              key: "group-info-#{group_id}",
              opts: [ttl: @ttl]
            )
  def get_group_info(group_id, opts),
    do:
      do_get(
        "/universe/groups/#{group_id}/",
        opts,
        @cache_opts
      )

  @decorate cacheable(
              cache: Cache,
              key: "type-info-#{type_id}",
              opts: [ttl: @ttl]
            )
  def get_type_info(type_id, opts),
    do:
      do_get(
        "/universe/types/#{type_id}/",
        opts,
        @cache_opts
      )

  @decorate cacheable(
              cache: Cache,
              key: "alliance-info-#{eve_id}",
              opts: [ttl: @ttl]
            )
  def get_alliance_info(eve_id, opts \\ []) do
    case get_alliance_info(eve_id, "", opts) do
      {:ok, result} when is_map(result) -> {:ok, result |> Map.put("eve_id", eve_id)}
      {:error, error} -> {:error, error}
      error -> error
    end
  end

  @decorate cacheable(
              cache: Cache,
              key: "killmail-#{killmail_id}-#{killmail_hash}",
              opts: [ttl: @ttl]
            )
  def get_killmail(killmail_id, killmail_hash, opts \\ []),
    do: do_get("/killmails/#{killmail_id}/#{killmail_hash}/", opts, @cache_opts)

  @decorate cacheable(
              cache: Cache,
              key: "corporation-info-#{eve_id}",
              opts: [ttl: @ttl]
            )
  def get_corporation_info(eve_id, opts \\ []) do
    case get_corporation_info(eve_id, "", opts) do
      {:ok, result} when is_map(result) -> {:ok, result |> Map.put("eve_id", eve_id)}
      {:error, error} -> {:error, error}
      error -> error
    end
  end

  @decorate cacheable(
              cache: Cache,
              key: "character-info-#{eve_id}",
              opts: [ttl: @ttl]
            )
  def get_character_info(eve_id, opts \\ []) do
    case do_get(
           "/characters/#{eve_id}/",
           opts,
           @cache_opts
         ) do
      {:ok, result} when is_map(result) -> {:ok, result |> Map.put("eve_id", eve_id)}
      {:error, error} -> {:error, error}
      error -> error
    end
  end

  @decorate cacheable(
              cache: Cache,
              key: "get_custom_route_base_url"
            )
  def get_custom_route_base_url, do: WandererApp.Env.custom_route_base_url()

  def get_character_wallet(character_eve_id, opts \\ []),
    do: get_character_auth_data(character_eve_id, "wallet", opts ++ @cache_opts)

  def get_corporation_wallets(corporation_id, opts \\ []),
    do: get_corporation_auth_data(corporation_id, "wallets", opts)

  def get_corporation_wallet_journal(corporation_id, division, opts \\ []),
    do:
      get_corporation_auth_data(
        corporation_id,
        "wallets/#{division}/journal",
        opts
      )

  def get_corporation_wallet_transactions(corporation_id, division, opts \\ []),
    do:
      get_corporation_auth_data(
        corporation_id,
        "wallets/#{division}/transactions",
        opts
      )

  # CHEWY PATCH: corp roster feed (docs/chewy/corp-suite-plan.md §9 Phase 3).
  # get_corporation_auth_data/3 doesn't accept a per-call :etag opt (it's a
  # shared helper every existing wallet/structures caller uses unmodified),
  # so this is a narrow sibling rather than widening that one. `opts` must
  # include `access_token:`/`character_id:` (same shape as every other
  # corp-auth call, e.g. get_corporation_wallet_journal/3) and may include
  # `etag:` -- absent it still activates do_get/4's etag mode with no
  # value to send (first-ever fetch), so a 200 always returns the 3-tuple.
  # KNOWN GAP, disclosed not glossed over, not a silent truncation: this
  # fetches page 1 only, no X-Pages loop. seat-parity.md §8.3 states
  # ESI pages this endpoint at 100 rows/page. Concrete consequence: a
  # corp with 101+ members will have members 101+ silently absent from
  # every roster poll -- and this alliance's own stated target scale
  # (~100 characters, seat-parity.md line 6) sits right at that
  # boundary, not comfortably under it. This is a documented limitation
  # for this phase, not a TODO scoped out of it: closing it means
  # threading corp_roster_feed.ex's fetch/2 loop to call this with
  # `params: [page: n]` for n in 2..x_pages, aggregating before
  # returning to WandererApp.Sync.Scheduler. Revisit before roster size
  # is trusted past 100 members.
  def get_corp_membertracking(corporation_id, opts \\ []) do
    path = "/corporations/#{corporation_id}/membertracking/"

    do_get(
      path,
      [params: opts[:params] || []] ++ get_auth_opts(opts),
      opts |> with_refresh_token() |> Keyword.put_new(:etag, nil)
    )
  end

  # Public, unauthenticated. ESI caps this at 1000 IDs per call; a ~100
  # -member roster's character/location/ship IDs combined stay well under
  # that, so this is a single batch call, not a chunking loop.
  def resolve_universe_names(ids) when is_list(ids) and ids != [] do
    do_post_esi(
      "/universe/names/",
      [json: ids, params: %{datasource: "tranquility"}],
      @general_pool
    )
  end

  def resolve_universe_names([]), do: {:ok, []}

  def get_character_location(character_eve_id, opts \\ []),
    do: get_character_auth_data(character_eve_id, "location", opts ++ @cache_opts)

  def get_character_online(character_eve_id, opts \\ []),
    do: get_character_auth_data(character_eve_id, "online", opts ++ @cache_opts)

  def get_character_ship(character_eve_id, opts \\ []),
    do: get_character_auth_data(character_eve_id, "ship", opts ++ @cache_opts)

  def get_character_roles(character_eve_id, opts \\ []),
    do: get_character_auth_data(character_eve_id, "roles", opts)

  def search(character_eve_id, opts \\ []) do
    params = Keyword.get(opts, :params, %{}) |> Map.new()

    search_val =
      to_string(Map.get(params, :search) || Map.get(params, "search") || "")

    categories_val =
      to_string(
        Map.get(params, :categories) ||
          Map.get(params, "categories") ||
          "character,alliance,corporation"
      )

    query_params = [
      {"search", search_val},
      {"categories", categories_val},
      {"language", "en-us"},
      {"strict", "false"},
      {"datasource", "tranquility"}
    ]

    merged_opts = Keyword.put(opts, :params, query_params)
    get_search(character_eve_id, search_val, categories_val, merged_opts)
  end

  @decorate cacheable(
              cache: Cache,
              key: "search-#{character_eve_id}-#{categories_val}-#{Base.encode64(search_val)}",
              opts: [ttl: @ttl]
            )
  defp get_search(character_eve_id, search_val, categories_val, merged_opts) do
    # Note: search_val and categories_val are used by the @decorate cacheable annotation above
    _unused = {search_val, categories_val}
    get_character_auth_data(character_eve_id, "search", merged_opts)
  end

  defp get_auth_opts(opts), do: [auth: {:bearer, opts[:access_token]}]

  defp get_alliance_info(alliance_eve_id, info_path, opts),
    do:
      do_get(
        "/alliances/#{alliance_eve_id}/#{info_path}",
        opts,
        @cache_opts
      )

  defp get_corporation_info(corporation_eve_id, info_path, opts),
    do:
      do_get(
        "/corporations/#{corporation_eve_id}/#{info_path}",
        opts,
        @cache_opts
      )

  defp get_character_auth_data(character_eve_id, info_path, opts) do
    path = "/characters/#{character_eve_id}/#{info_path}"

    auth_opts =
      [params: opts[:params] || []] ++
        (opts |> get_auth_opts())

    character_id = opts |> Keyword.get(:character_id, nil)

    # Use character tracking pool for character operations
    pool = @character_tracking_pool

    if not is_access_token_expired?(character_id) do
      do_get(
        path,
        auth_opts,
        opts |> with_refresh_token(),
        pool
      )
    else
      do_get_retry(path, auth_opts, opts |> with_refresh_token(), :forbidden, pool)
    end
  end

  defp is_access_token_expired?(character_id) do
    {:ok, %{expires_at: expires_at} = _character} =
      WandererApp.Character.get_character(character_id)

    now = DateTime.utc_now() |> DateTime.to_unix()

    expires_at - now <= 0
  end

  defp get_corporation_auth_data(corporation_eve_id, info_path, opts),
    do:
      do_get(
        "/corporations/#{corporation_eve_id}/#{info_path}",
        [params: opts[:params] || []] ++
          (opts |> get_auth_opts()),
        (opts |> with_refresh_token()) ++ @cache_opts
      )

  defp with_user_agent_opts(opts),
    do:
      opts
      |> Keyword.merge(
        headers: [{:user_agent, "Wanderer/#{WandererApp.Env.vsn()} #{@wanderrer_user_agent}"}]
      )

  defp with_refresh_token(opts), do: opts |> Keyword.merge(refresh_token?: true)

  defp with_cache_opts(opts),
    do: opts |> Keyword.merge(@cache_opts) |> Keyword.merge(cache_dir: System.tmp_dir!())

  # CHEWY PATCH: hook #10 (docs/chewy/corp-suite-plan.md §3.4/§5). Callers
  # that pass an `:etag` opt (only WandererApp.Sync.Feed machinery does;
  # every existing caller's `opts` never has this key, so
  # `with_etag_request_header/2` and this branch are no-ops for them)
  # bypass the generic :api_cache short-circuit entirely -- staleness for
  # those callers is tracked via sync_runs_v1's own etag column, and a
  # conditional request must always reach ESI to learn 304 vs 200, never
  # be satisfied from a local cache that knows nothing about ETags.
  defp do_get(path, api_opts, opts, pool \\ @general_pool) do
    if Keyword.has_key?(opts, :etag) do
      do_get_request(path, api_opts, opts, pool)
    else
      case Cachex.get(:api_cache, path) do
        {:ok, cached_data} when not is_nil(cached_data) ->
          {:ok, cached_data}

        _ ->
          do_get_request(path, api_opts, opts, pool)
      end
    end
  end

  # Appends (never replaces) an If-None-Match header when the caller
  # passed a non-nil `:etag` opt. A caller in etag-mode with no
  # previously-seen etag (first-ever fetch) passes `etag: nil`, which
  # this leaves alone -- no header to send yet, but do_get/4 above still
  # takes the etag-aware branch so the response-handling case below still
  # captures the freshly-issued ETag on the resulting 200.
  defp with_etag_request_header(req_opts, opts) do
    case Keyword.get(opts, :etag) do
      nil ->
        req_opts

      etag ->
        Keyword.update(
          req_opts,
          :headers,
          [{"if-none-match", etag}],
          &(&1 ++ [{"if-none-match", etag}])
        )
    end
  end

  defp response_etag(headers), do: headers |> Map.get("etag", []) |> List.first()

  defp do_get_request(path, api_opts, opts, pool) do
    etag_requested? = Keyword.has_key?(opts, :etag)

    try do
      req_options_for_pool(pool)
      |> Req.new()
      |> Req.get(
        api_opts
        |> Keyword.merge(url: path)
        |> with_user_agent_opts()
        |> with_etag_request_header(opts)
        |> with_cache_opts()
        |> Keyword.merge(@retry_opts)
        |> Keyword.merge(@timeout_opts)
      )
      |> case do
        {:ok, %{status: 304}} when etag_requested? ->
          :not_modified

        {:ok, %{status: 200, body: body, headers: headers}} ->
          maybe_cache_response(path, body, headers, opts)

          if etag_requested? do
            {:ok, body, response_etag(headers)}
          else
            {:ok, body}
          end

        {:ok, %{status: 504}} ->
          {:error, :timeout}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: 420, headers: headers} = _error} ->
          # Extract rate limit information from headers
          reset_seconds = Map.get(headers, "x-esi-error-limit-reset", ["0"]) |> List.first()
          remaining = Map.get(headers, "x-esi-error-limit-remain", ["0"]) |> List.first()

          # Emit telemetry for rate limiting
          :telemetry.execute(
            [:wanderer_app, :esi, :rate_limited],
            %{
              count: 1,
              reset_duration:
                case Integer.parse(reset_seconds || "0") do
                  {seconds, _} -> seconds * 1000
                  _ -> 0
                end
            },
            %{
              method: "GET",
              path: path,
              reset_seconds: reset_seconds,
              remaining_requests: remaining
            }
          )

          Logger.warning("ESI_RATE_LIMITED: GET request rate limited",
            method: "GET",
            path: path,
            reset_seconds: reset_seconds,
            remaining_requests: remaining
          )

          {:error, :error_limited, headers}

        {:ok, %{status: 429, headers: headers} = _error} ->
          # Extract rate limit information from headers
          reset_seconds = Map.get(headers, "retry-after", ["0"]) |> List.first()

          # Emit telemetry for rate limiting
          :telemetry.execute(
            [:wanderer_app, :esi, :rate_limited],
            %{
              count: 1,
              reset_duration:
                case Integer.parse(reset_seconds || "0") do
                  {seconds, _} -> seconds * 1000
                  _ -> 0
                end
            },
            %{
              method: "GET",
              path: path,
              reset_seconds: reset_seconds
            }
          )

          Logger.warning("ESI_RATE_LIMITED: GET request rate limited",
            method: "GET",
            path: path,
            reset_seconds: reset_seconds
          )

          {:error, :error_limited, headers}

        {:ok, %{status: status} = _error} when status in [401, 403] ->
          do_get_retry(path, api_opts, opts)

        {:ok, %{status: status}} ->
          {:error, "Unexpected status: #{status}"}

        {:error, %Mint.TransportError{reason: :timeout}} ->
          # Emit telemetry for pool timeout
          :telemetry.execute(
            [:wanderer_app, :finch, :pool_timeout],
            %{count: 1},
            %{method: "GET", path: path, pool: pool}
          )

          {:error, :pool_timeout}

        {:error, reason} ->
          # Check if this is a Finch pool error
          if is_exception(reason) and
               Exception.message(reason) =~ "unable to provide a connection" do
            :telemetry.execute(
              [:wanderer_app, :finch, :pool_exhausted],
              %{count: 1},
              %{method: "GET", path: path, pool: pool}
            )
          end

          {:error, "Request failed"}
      end
    rescue
      e ->
        error_msg = Exception.message(e)

        # Emit telemetry for pool exhaustion errors
        if error_msg =~ "unable to provide a connection" do
          :telemetry.execute(
            [:wanderer_app, :finch, :pool_exhausted],
            %{count: 1},
            %{method: "GET", path: path, pool: pool}
          )

          Logger.error("FINCH_POOL_EXHAUSTED: #{error_msg}",
            method: "GET",
            path: path,
            pool: inspect(pool)
          )
        else
          Logger.error(error_msg)
        end

        {:error, "Request failed"}
    end
  end

  defp maybe_cache_response(path, body, %{"expires" => [expires]} = _headers, opts)
       when is_binary(path) and not is_nil(expires) do
    try do
      if opts |> Keyword.get(:cache, false) do
        cached_ttl =
          DateTime.diff(Timex.parse!(expires, "{RFC1123}"), DateTime.utc_now(), :millisecond)

        Cachex.put(
          :api_cache,
          path,
          body,
          ttl: cached_ttl
        )
      end
    rescue
      e ->
        @logger.error(Exception.message(e))

        :ok
    end
  end

  defp maybe_cache_response(_path, _body, _headers, _opts), do: :ok

  defp do_post(url, opts) do
    try do
      case Req.post("#{url}", opts |> with_user_agent_opts()) do
        {:ok, %{status: status, body: body}} when status in [200, 201] ->
          {:ok, body}

        {:ok, %{status: 504}} ->
          {:error, :timeout}

        {:ok, %{status: 403}} ->
          {:error, :forbidden}

        {:ok, %{status: 420, headers: headers} = _error} ->
          # Extract rate limit information from headers
          reset_seconds = Map.get(headers, "x-esi-error-limit-reset", ["0"]) |> List.first()
          remaining = Map.get(headers, "x-esi-error-limit-remain", ["0"]) |> List.first()

          # Emit telemetry for rate limiting
          :telemetry.execute(
            [:wanderer_app, :esi, :rate_limited],
            %{
              count: 1,
              reset_duration:
                case Integer.parse(reset_seconds || "0") do
                  {seconds, _} -> seconds * 1000
                  _ -> 0
                end
            },
            %{
              method: "POST",
              path: url,
              reset_seconds: reset_seconds,
              remaining_requests: remaining
            }
          )

          Logger.warning("ESI_RATE_LIMITED: POST request rate limited",
            method: "POST",
            path: url,
            reset_seconds: reset_seconds,
            remaining_requests: remaining
          )

          {:error, :error_limited, headers}

        {:ok, %{status: status}} ->
          {:error, "Unexpected status: #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        @logger.error(Exception.message(e))

        {:error, "Request failed"}
    end
  end

  defp do_post_esi(url, opts, pool \\ @general_pool) do
    try do
      req_opts =
        (opts |> with_user_agent_opts() |> Keyword.merge(@retry_opts)) ++
          [params: opts[:params] || []]

      Req.new(req_options_for_pool(pool) ++ req_opts)
      |> Req.post(url: url)
      |> case do
        # CHEWY PATCH: 204 is a SUCCESS, and for `/ui/autopilot/waypoint`
        # it is the ONLY success ESI documents (`meta/openapi.json`:
        # "204 - Open window request received"). Without it a route that
        # EVE accepted came back `{:error, "Unexpected status: 204"}`,
        # which the map's fire-and-forget button discards and the scout
        # planner could not distinguish from a refusal.
        {:ok, %{status: status, body: body}} when status in [200, 201, 204] ->
          {:ok, body}

        {:ok, %{status: 504}} ->
          {:error, :timeout}

        {:ok, %{status: 403}} ->
          {:error, :forbidden}

        {:ok, %{status: 420, headers: headers} = _error} ->
          # Extract rate limit information from headers
          reset_seconds = Map.get(headers, "x-esi-error-limit-reset", ["0"]) |> List.first()
          remaining = Map.get(headers, "x-esi-error-limit-remain", ["0"]) |> List.first()

          # Emit telemetry for rate limiting
          :telemetry.execute(
            [:wanderer_app, :esi, :rate_limited],
            %{
              count: 1,
              reset_duration:
                case Integer.parse(reset_seconds || "0") do
                  {seconds, _} -> seconds * 1000
                  _ -> 0
                end
            },
            %{
              method: "POST_ESI",
              path: url,
              reset_seconds: reset_seconds,
              remaining_requests: remaining
            }
          )

          Logger.warning("ESI_RATE_LIMITED: POST ESI request rate limited",
            method: "POST_ESI",
            path: url,
            reset_seconds: reset_seconds,
            remaining_requests: remaining
          )

          {:error, :error_limited, headers}

        {:ok, %{status: 429, headers: headers} = _error} ->
          # Extract rate limit information from headers
          reset_seconds = Map.get(headers, "retry-after", ["0"]) |> List.first()

          # Emit telemetry for rate limiting
          :telemetry.execute(
            [:wanderer_app, :esi, :rate_limited],
            %{
              count: 1,
              reset_duration:
                case Integer.parse(reset_seconds || "0") do
                  {seconds, _} -> seconds * 1000
                  _ -> 0
                end
            },
            %{
              method: "POST_ESI",
              path: url,
              reset_seconds: reset_seconds
            }
          )

          Logger.warning("ESI_RATE_LIMITED: POST request rate limited",
            method: "POST_ESI",
            path: url,
            reset_seconds: reset_seconds
          )

          {:error, :error_limited, headers}

        {:ok, %{status: status}} ->
          {:error, "Unexpected status: #{status}"}

        {:error, %Mint.TransportError{reason: :timeout}} ->
          # Emit telemetry for pool timeout
          :telemetry.execute(
            [:wanderer_app, :finch, :pool_timeout],
            %{count: 1},
            %{method: "POST_ESI", path: url, pool: pool}
          )

          {:error, :pool_timeout}

        {:error, reason} ->
          # Check if this is a Finch pool error
          if is_exception(reason) and
               Exception.message(reason) =~ "unable to provide a connection" do
            :telemetry.execute(
              [:wanderer_app, :finch, :pool_exhausted],
              %{count: 1},
              %{method: "POST_ESI", path: url, pool: pool}
            )
          end

          {:error, reason}
      end
    rescue
      e ->
        error_msg = Exception.message(e)

        # Emit telemetry for pool exhaustion errors
        if error_msg =~ "unable to provide a connection" do
          :telemetry.execute(
            [:wanderer_app, :finch, :pool_exhausted],
            %{count: 1},
            %{method: "POST_ESI", path: url, pool: pool}
          )

          @logger.error("FINCH_POOL_EXHAUSTED: #{error_msg}",
            method: "POST_ESI",
            path: url,
            pool: inspect(pool)
          )
        else
          @logger.error(error_msg)
        end

        {:error, "Request failed"}
    end
  end

  defp do_get_retry(path, api_opts, opts, status \\ :forbidden, pool \\ @general_pool) do
    refresh_token? = opts |> Keyword.get(:refresh_token?, false)
    retry_count = opts |> Keyword.get(:retry_count, 0)
    character_id = opts |> Keyword.get(:character_id, nil)

    if not refresh_token? or is_nil(character_id) or retry_count >= @api_retry_count do
      {:error, status}
    else
      case refresh_token(character_id) do
        {:ok, token} ->
          auth_opts = [access_token: token.access_token] |> get_auth_opts()

          do_get(
            path,
            api_opts |> Keyword.merge(auth_opts),
            opts |> Keyword.merge(retry_count: retry_count + 1),
            pool
          )

        {:error, _error} ->
          {:error, status}
      end
    end
  end

  defp refresh_token(character_id) do
    {:ok,
     %{
       expires_at: expires_at,
       refresh_token: refresh_token,
       scopes: scopes,
       tracking_pool: tracking_pool
     } = character} =
      WandererApp.Character.get_character(character_id)

    refresh_token_result =
      WandererApp.Ueberauth.Strategy.Eve.OAuth.get_refresh_token([],
        with_wallet: WandererApp.Character.can_track_wallet?(character),
        is_admin?: WandererApp.Character.can_track_corp_wallet?(character),
        tracking_pool: tracking_pool,
        token: %OAuth2.AccessToken{refresh_token: refresh_token}
      )

    handle_refresh_token_result(refresh_token_result, character, character_id, expires_at, scopes)
  end

  defp handle_refresh_token_result(
         {:ok, %OAuth2.AccessToken{} = token},
         character,
         character_id,
         expires_at,
         scopes
       ) do
    # Log token refresh success with timing info
    expires_at_datetime = DateTime.from_unix!(expires_at)
    time_since_expiry = DateTime.diff(DateTime.utc_now(), expires_at_datetime, :second)

    Logger.debug(
      fn ->
        "TOKEN_REFRESH_SUCCESS: Character token refreshed successfully"
      end,
      character_id: character_id,
      time_since_expiry_seconds: time_since_expiry,
      new_expires_at: token.expires_at
    )

    # Clear any previous invalid_grant failure counter on successful refresh
    WandererApp.Cache.delete("character:#{character_id}:invalid_grant_count")

    {:ok, _character} =
      character
      |> WandererApp.Api.Character.update(%{
        access_token: token.access_token,
        expires_at: token.expires_at,
        scopes: scopes
      })

    WandererApp.Character.update_character(character_id, %{
      access_token: token.access_token,
      expires_at: token.expires_at
    })

    Phoenix.PubSub.broadcast(
      WandererApp.PubSub,
      "character:#{character_id}",
      :token_updated
    )

    {:ok, token}
  end

  defp handle_refresh_token_result(
         {:error, {"invalid_grant", error_message}},
         character,
         character_id,
         expires_at,
         scopes
       ) do
    expires_at_datetime = DateTime.from_unix!(expires_at)
    time_since_expiry = DateTime.diff(DateTime.utc_now(), expires_at_datetime, :second)

    # Track consecutive invalid_grant failures before permanently invalidating tokens.
    # EVE SSO can return invalid_grant for transient server issues, so we require
    # 3 consecutive failures before wiping tokens.
    fail_key = "character:#{character_id}:invalid_grant_count"
    count = WandererApp.Cache.lookup!(fail_key, 0) + 1
    WandererApp.Cache.put(fail_key, count, ttl: :timer.hours(2))

    # Emit telemetry for token refresh failures
    :telemetry.execute([:wanderer_app, :token, :refresh_failed], %{count: 1}, %{
      character_id: character_id,
      error_type: "invalid_grant",
      time_since_expiry: time_since_expiry
    })

    if count >= 3 do
      Logger.warning(
        "TOKEN_REFRESH_FAILED: Invalid grant error (#{count}/3, invalidating tokens)",
        character_id: character_id,
        error_message: error_message,
        time_since_expiry_seconds: time_since_expiry,
        original_expires_at: expires_at
      )

      WandererApp.Cache.delete(fail_key)
      invalidate_character_tokens(character, character_id, expires_at, scopes)
      {:error, :invalid_grant}
    else
      Logger.warning(
        "TOKEN_REFRESH_FAILED: Invalid grant error (#{count}/3, deferring invalidation)",
        character_id: character_id,
        error_message: error_message,
        time_since_expiry_seconds: time_since_expiry,
        original_expires_at: expires_at
      )

      {:error, :token_refresh_failed}
    end
  end

  defp handle_refresh_token_result(
         {:error, %OAuth2.Error{reason: :econnrefused} = error},
         _character,
         character_id,
         expires_at,
         _scopes
       ) do
    expires_at_datetime = DateTime.from_unix!(expires_at)
    time_since_expiry = DateTime.diff(DateTime.utc_now(), expires_at_datetime, :second)

    Logger.warning("TOKEN_REFRESH_FAILED: Connection refused during token refresh",
      character_id: character_id,
      error: inspect(error),
      time_since_expiry_seconds: time_since_expiry,
      original_expires_at: expires_at
    )

    # Emit telemetry for connection failures
    :telemetry.execute([:wanderer_app, :token, :refresh_failed], %{count: 1}, %{
      character_id: character_id,
      error_type: "connection_refused",
      time_since_expiry: time_since_expiry
    })

    {:error, :econnrefused}
  end

  defp handle_refresh_token_result(
         {:error, %OAuth2.Error{} = error},
         _character,
         character_id,
         expires_at,
         _scopes
       ) do
    time_since_expiry =
      DateTime.diff(DateTime.utc_now(), DateTime.from_unix!(expires_at), :second)

    Logger.warning("TOKEN_REFRESH_FAILED: Transient OAuth2 error during token refresh",
      character_id: character_id,
      error: inspect(error),
      time_since_expiry_seconds: time_since_expiry
    )

    :telemetry.execute([:wanderer_app, :token, :refresh_failed], %{count: 1}, %{
      character_id: character_id,
      error_type: "oauth2_error",
      time_since_expiry: time_since_expiry
    })

    {:error, :token_refresh_failed}
  end

  defp handle_refresh_token_result(error, _character, character_id, expires_at, _scopes) do
    time_since_expiry =
      DateTime.diff(DateTime.utc_now(), DateTime.from_unix!(expires_at), :second)

    Logger.warning("TOKEN_REFRESH_FAILED: Unexpected error during token refresh",
      character_id: character_id,
      error: inspect(error),
      time_since_expiry_seconds: time_since_expiry
    )

    :telemetry.execute([:wanderer_app, :token, :refresh_failed], %{count: 1}, %{
      character_id: character_id,
      error_type: "unexpected_error",
      time_since_expiry: time_since_expiry
    })

    {:error, :token_refresh_failed}
  end

  defp invalidate_character_tokens(character, character_id, expires_at, scopes) do
    # Skip invalidation if the character was recently re-authorized via SSO.
    # This protects fresh tokens from being wiped by transient invalid_grant
    # errors that can occur shortly after re-auth.
    if WandererApp.Cache.lookup!("character:#{character_id}:reauth_grace", false) do
      Logger.info(
        "[ApiClient] Skipping token invalidation for #{character_id} - within re-auth grace period"
      )
    else
      # Re-load from DB to avoid race with concurrent re-auth
      case WandererApp.Api.Character.by_id(character_id) do
        {:ok, current_character} ->
          # Only invalidate if tokens haven't been refreshed since we started
          if current_character.access_token == character.access_token do
            attrs = %{
              access_token: nil,
              refresh_token: nil,
              expires_at: expires_at,
              scopes: scopes
            }

            with {:ok, _} <- WandererApp.Api.Character.update(current_character, attrs) do
              WandererApp.Character.update_character(character_id, attrs)
            else
              error ->
                Logger.error("Failed to clear tokens for #{character_id}: #{inspect(error)}")
            end

            Phoenix.PubSub.broadcast(
              WandererApp.PubSub,
              "character:#{character_id}",
              :character_token_invalid
            )
          else
            Logger.info(
              "[ApiClient] Skipping token invalidation for #{character_id} - tokens were refreshed concurrently"
            )
          end

        {:error, _} ->
          Logger.error("Failed to load character #{character_id} for token invalidation")
      end
    end

    :ok
  end
end
