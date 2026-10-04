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

  @kinds ~w(visit anoms sigs grid)
  @formats ~w(json text flat)

  @default_limit 10
  @max_limit 100

  @default_max_jumps 25
  @max_max_jumps 40

  def plan(conn, params) do
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

  defp error(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})
end
