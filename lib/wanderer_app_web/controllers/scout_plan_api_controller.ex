defmodule WandererAppWeb.ScoutPlanAPIController do
  @moduledoc """
  CHEWY PATCH: `GET /api/maps/:map_identifier/scout/plan` -- a
  nearest-neighbour route over `WandererApp.Scout.Planner.plan/1`'s
  ranking. See `docs/design/wanderer-scout-planner.md` sections 6-7.

  ## Why this lives under `/api/maps/:map_identifier`

  The `:map_identifier` in the path is AUTHENTICATION, not scope -- the
  same credential eveknob already holds for signature sync and the
  coverage ingest it feeds (design doc section 7). `origin` and `scope`
  decide which systems are ranked; the authenticating map additionally
  supplies `map_id` to `Planner.plan/1`, which is what lets the
  frontier term see that map's chain at all (it is 0 with no map_id).
  `&chain=1` additionally unions that map's connections into the BFS
  graph itself (mode B advisory stops, design section 6) -- a separate
  knob from the frontier term, which is always live once `map_id` is
  known.

  Gated by `WANDERER_SCOUT_PLANNER`; with the flag off the route answers
  404 like any nonexistent path.

  ## Three formats

  `format=json` (default) is a plain JSON envelope with the full `stop`
  maps -- for the LiveView and any other JSON-capable client.
  `format=text` is design section 7's `text/plain` wire format exactly.
  `format=flat` is this module's one addition: the SAME records as
  `text`, but `;`-joined onto a single line with no newlines anywhere --
  what the bot actually consumes, because isxbob has no JSON parser
  (`Bridge.cpp:8-9`) and LavishScript has no proven newline-splitting
  idiom, only `${str.Token[n,"|"]}` on one line
  (`obj_BookmarkFiler.iss:1483`).
  """

  use WandererAppWeb, :controller

  alias WandererApp.Scout.Planner
  alias WandererApp.Scout.PlanWaypoints
  alias WandererApp.Scout.Sweep

  @kinds ~w(visit anoms sigs grid)
  @formats ~w(json text flat)
  @modes ~w(rank sweep)

  @default_limit 10
  @max_limit 100

  @default_max_jumps 25
  @max_max_jumps 40

  # Section 9's cross-region note: a scope beyond this is the same
  # algorithm over a bigger candidate set (~450 systems at 3 regions)
  # but nobody has measured or asked for it, so the HTTP surface
  # enforces the cap `WandererApp.Scout.Sweep.sweep/1` itself documents
  # as a caller responsibility.
  @max_sweep_regions 3

  # `mode=rank` (absent = rank) keeps answering `#plan 1`, 7 columns,
  # byte-for-byte what it always has -- `obj_ScoutPlanner.iss` already
  # parses that shape and must keep working unmodified. `mode=sweep` is
  # a different question (design doc "whole-region sweeps" section 3)
  # and answers `#plan 2`: the bot refusing an unknown version is
  # correct there, not a bug to route around.
  def plan(conn, params) do
    case fetch_mode(params) do
      {:ok, :sweep} -> sweep_plan(conn, params)
      {:ok, :rank} -> rank_plan(conn, params)
      {:error, message} -> error(conn, message)
    end
  end

  defp rank_plan(conn, params) do
    with {:ok, origin} <- fetch_origin(params),
         {:ok, kind} <- fetch_kind(params),
         {:ok, format} <- fetch_format(params) do
      opts = [
        origin: origin,
        kind: kind,
        limit: fetch_limit(params),
        max_jumps: fetch_max_jumps(params),
        regions: fetch_regions(params),
        map_id: conn.assigns[:map_id],
        chain: truthy?(Map.get(params, "chain"))
      ]

      case Planner.plan(opts) do
        {:ok, result} -> render_result(conn, result, format)
        {:error, reason} -> error(conn, to_string(reason))
      end
    else
      {:error, message} -> error(conn, message)
    end
  end

  # `mode=sweep` -- a MEMBERSHIP over one to three regions (design doc
  # "whole-region sweeps" section 3), not a ball: `origin`, `limit` and
  # `max_jumps` are ball concepts from `rank_plan/2` above and are
  # simply ignored here. `scope` (required) and `start` (optional, a
  # forced start system) take their place.
  defp sweep_plan(conn, params) do
    with {:ok, scope} <- fetch_sweep_scope(params),
         {:ok, kind} <- fetch_kind(params),
         {:ok, format} <- fetch_format(params),
         {:ok, start} <- fetch_sweep_start(params) do
      opts =
        [scope: scope, kind: kind, start: start, compress: fetch_compress(params)]
        |> maybe_put_opt(:security, fetch_security(params))

      case Sweep.sweep(opts) do
        {:ok, result} -> render_sweep_result(conn, result, format)
        {:error, reason} -> error(conn, to_string(reason))
      end
    else
      {:error, message} -> error(conn, message)
    end
  end

  # POST .../scout/plan/waypoints -- the same plan, then PUSHED onto a
  # character's autopilot through ESI. Separate verb and action on
  # purpose: `plan/2` is a pure read anybody holding the map key may do,
  # this one changes what a pilot's client shows, and the route only
  # exists in-game as an ordered waypoint list ESI alone can write
  # (see WandererApp.Scout.PlanWaypoints).
  #
  # The response is the plan in the requested format regardless of how
  # far the push got, with the pushed count on the header line, because
  # the bot logs what it was told to fly and a partial push is still a
  # valid route prefix.
  def waypoints(conn, params) do
    with {:ok, origin} <- fetch_origin(params),
         {:ok, kind} <- fetch_kind(params),
         {:ok, format} <- fetch_format(params),
         {:ok, character_eve_id} <- fetch_character_eve_id(params) do
      opts = [
        origin: origin,
        kind: kind,
        limit: fetch_limit(params),
        max_jumps: fetch_max_jumps(params),
        regions: fetch_regions(params),
        map_id: conn.assigns[:map_id],
        chain: truthy?(Map.get(params, "chain"))
      ]

      with {:ok, result} <- Planner.plan(opts),
           {:ok, pushed} <- PlanWaypoints.push(result.stops, character_eve_id) do
        render_result(conn, Map.put(result, :pushed, pushed), format)
      else
        {:error, reason} -> error(conn, to_string(reason))
      end
    else
      {:error, message} -> error(conn, message)
    end
  end

  # ---------------------------------------------------------------------
  # Param coercion -- explicit errors, not silent fallback, for
  # anything the caller stated and got wrong. Absent params fall back
  # to Planner.plan/1's own defaults (kind, limit, max_jumps) or an
  # empty scope (regions).
  # ---------------------------------------------------------------------

  defp fetch_origin(%{"origin" => origin}) when is_binary(origin) do
    case Integer.parse(origin) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, "origin must be a positive integer"}
    end
  end

  defp fetch_origin(_params), do: {:error, "origin is required"}

  defp fetch_kind(%{"kind" => kind}) when kind in @kinds, do: {:ok, String.to_existing_atom(kind)}

  defp fetch_kind(%{"kind" => _other}),
    do: {:error, "unknown kind, expected one of #{Enum.join(@kinds, ", ")}"}

  defp fetch_kind(_params), do: {:ok, :sigs}

  defp fetch_format(%{"format" => format}) when format in @formats, do: {:ok, format}

  defp fetch_format(%{"format" => _other}),
    do: {:error, "unknown format, expected one of #{Enum.join(@formats, ", ")}"}

  defp fetch_format(_params), do: {:ok, "json"}

  # Required by `waypoints/2` only: a route is pushed onto exactly one
  # pilot, and guessing which one from the map key is not something a
  # write this visible should do -- eveknob sends its own
  # `${ISXBob.Me.CharID}`.
  defp fetch_character_eve_id(%{"character_eve_id" => id}) when is_binary(id) and id != "" do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, to_string(value)}
      _ -> {:error, "character_eve_id must be a positive integer"}
    end
  end

  defp fetch_character_eve_id(_params), do: {:error, "character_eve_id is required"}

  # Capped, not rejected -- a hand-edited URL asking for too much gets
  # the cap, not a 422, same tradeoff `ScoutExportController` makes.
  defp fetch_limit(params) do
    params |> Map.get("limit") |> parse_pos_int(@default_limit) |> min(@max_limit)
  end

  defp fetch_max_jumps(params) do
    params |> Map.get("max_jumps") |> parse_pos_int(@default_max_jumps) |> min(@max_max_jumps)
  end

  defp parse_pos_int(nil, default), do: default

  defp parse_pos_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_pos_int(_value, default), do: default

  # `scope=region:10000002` or `scope=region:10000002,10000003`; absent
  # or any other shape = no region narrowing, exactly like an absent
  # `scope` -- a malformed scope is not a 422, it is "rank everything".
  defp fetch_regions(%{"scope" => "region:" <> rest}) do
    rest
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn s ->
      case s |> String.trim() |> Integer.parse() do
        {n, ""} -> [n]
        _ -> []
      end
    end)
  end

  defp fetch_regions(_params), do: []

  defp truthy?(value) when value in ["1", "true", "yes"], do: true
  defp truthy?(_value), do: false

  defp fetch_mode(%{"mode" => mode}) when mode in @modes, do: {:ok, String.to_existing_atom(mode)}

  defp fetch_mode(%{"mode" => _other}),
    do: {:error, "unknown mode, expected one of #{Enum.join(@modes, ", ")}"}

  defp fetch_mode(_params), do: {:ok, :rank}

  # `scope=region:10000002` or `scope=region:10000002,10000003` -- unlike
  # `fetch_regions/1` above (rank's optional narrowing of a ball), a
  # sweep's scope IS the candidate set, so it is required, and more than
  # `@max_sweep_regions` ids is a 422, not a silent cap: a sweep that
  # quietly dropped half its ask would report a route shorter than the
  # operator thinks they asked for.
  defp fetch_sweep_scope(%{"scope" => "region:" <> rest}) do
    ids =
      rest
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn s ->
        case s |> String.trim() |> Integer.parse() do
          {n, ""} -> [n]
          _ -> []
        end
      end)

    cond do
      ids == [] ->
        {:error, "scope is required, e.g. scope=region:10000002"}

      length(ids) > @max_sweep_regions ->
        {:error, "scope may name at most #{@max_sweep_regions} regions"}

      true ->
        {:ok, {:regions, ids}}
    end
  end

  defp fetch_sweep_scope(_params),
    do: {:error, "scope is required, e.g. scope=region:10000002"}

  defp fetch_sweep_start(%{"start" => start}) when is_binary(start) and start != "" do
    case Integer.parse(start) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, "start must be a positive integer"}
    end
  end

  defp fetch_sweep_start(_params), do: {:ok, nil}

  # Default true (contract: `Sweep.sweep/1`'s own default) -- only an
  # explicit `0`/`false` turns it off.
  defp fetch_compress(params) do
    case Map.get(params, "compress") do
      value when value in ["0", "false"] -> false
      _ -> true
    end
  end

  # Absent => `nil`, so `maybe_put_opt/3` leaves `Sweep.sweep/1` to use
  # its own default (Planner's `[:hs, :ls, :ns]`) rather than this
  # controller re-stating it and the two drifting.
  defp fetch_security(%{"security" => value}) when is_binary(value) and value != "" do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&security_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_security(_params), do: nil

  defp security_key(key) when key in ~w(hs ls ns wh pochven), do: String.to_existing_atom(key)
  defp security_key(_key), do: nil

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # ---------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------

  defp render_result(conn, result, "json"), do: json(conn, %{data: result})

  defp render_result(conn, result, "text") do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, text_body(result))
  end

  defp render_result(conn, result, "flat") do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, flat_body(result))
  end

  defp text_body(result) do
    [header_line(result) | Enum.map(result.stops, &row_line/1)]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp flat_body(result) do
    header_line(result) <> ";" <> Enum.map_join(result.stops, ";", &row_line/1)
  end

  # `pushed=` is present only on the waypoints action, and is the count
  # ESI actually accepted -- which can be a PREFIX of the stops below it
  # (`WandererApp.Scout.PlanWaypoints` halts rather than skipping a
  # stop). A client that flies the list without reading this number is
  # assuming a route it was not promised; version 1 clients that ignore
  # the key still parse the line, since every token after `#plan 1` is
  # `key=value` and order is not load-bearing.
  defp header_line(result) do
    base =
      "#plan 1 origin=#{result.origin} kind=#{result.kind} generated=#{DateTime.to_iso8601(result.generated_at)}"

    case Map.get(result, :pushed) do
      nil -> base
      pushed -> base <> " pushed=#{length(pushed)}"
    end
  end

  defp row_line(stop) do
    [
      stop.solar_system_id,
      sanitize_name(stop.name),
      format_score(stop.score),
      stop.reason,
      stop.age_s,
      stop.jumps,
      stop.leg
    ]
    |> Enum.join("|")
  end

  # Belt-and-braces (design section 7) -- EVE system names contain
  # neither `;` nor `|`, but the flat format's whole safety rests on it.
  defp sanitize_name(name) when is_binary(name), do: String.replace(name, ~r/[;|]/, " ")
  defp sanitize_name(_name), do: ""

  defp format_score(score), do: :erlang.float_to_binary(score / 1, decimals: 2)

  # ---------------------------------------------------------------------
  # Rendering -- `mode=sweep` ("#plan 2"). A different wire version, not
  # an extension of `#plan 1`: `obj_ScoutPlanner.iss` refuses a header
  # version it does not know, which is the correct behaviour for a
  # sweep it cannot parse (design doc "only crossroads become
  # waypoints" section) -- so this never reuses `header_line/1` or
  # `row_line/1` above, even though the shapes rhyme.
  # ---------------------------------------------------------------------

  defp render_sweep_result(conn, result, "json"), do: json(conn, %{data: result})

  defp render_sweep_result(conn, result, "text") do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, sweep_text_body(result))
  end

  defp render_sweep_result(conn, result, "flat") do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, sweep_flat_body(result))
  end

  defp sweep_text_body(result) do
    [sweep_header_line(result) | Enum.map(result.stops, &sweep_row_line/1)]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp sweep_flat_body(result) do
    sweep_header_line(result) <> ";" <> Enum.map_join(result.stops, ";", &sweep_row_line/1)
  end

  defp sweep_header_line(result) do
    "#plan 2 scope=#{scope_token(result.scope)} kind=#{result.kind} start=#{result.start} " <>
      "systems=#{result.systems} jumps=#{result.jumps} compressed=#{bool_flag(result.compressed?)} " <>
      "generated=#{DateTime.to_iso8601(result.generated_at)}"
  end

  defp scope_token({:regions, ids}), do: "region:" <> Enum.join(ids, ",")
  defp scope_token({:systems, ids}), do: "systems:" <> Enum.join(ids, ",")
  defp scope_token(other), do: inspect(other)

  defp bool_flag(true), do: "1"
  defp bool_flag(_value), do: "0"

  # `sysid|name|score_or_blank|reason|age_s|jumps|leg|wp` -- one column
  # longer than `#plan 1`'s row, and the eighth column is the whole
  # reason this is a new version: a reader (or the bot) must be able to
  # tell a pushed WAYPOINT from a system the route only flies through
  # (design doc "only crossroads become waypoints" section). `score` is
  # blank -- a sweep orders by route cost, not by `Planner`'s need/
  # frontier/value score, so there is none to print. `leg` is always
  # `gate`: `Sweep.sweep/1`'s graph is the full k-space adjacency with
  # no chain overlay (contract, `WandererApp.Scout.Sweep.distances/1`),
  # so a sweep never produces an `:advisory` wormhole leg the way a
  # chain-aware rank plan can.
  defp sweep_row_line(stop) do
    [
      stop.solar_system_id,
      sanitize_name(stop.name),
      "",
      stop.reason,
      stop.age_s,
      stop.jumps_from_prev,
      "gate",
      bool_flag(stop.waypoint?)
    ]
    |> Enum.join("|")
  end

  defp error(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})
end
