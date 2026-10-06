defmodule WandererAppWeb.ScoutPlannerLive do
  @moduledoc """
  CHEWY PATCH (scout shell): the Planner category of `/scout` -- design doc
  `docs/design/wanderer-scout-planner.md` section 8, "the human surface:
  a list, not a canvas".

  Phase 1 of that feature shipped the write path: `scout_system_coverage_v1`
  rows land here from eveknob's `obj_ScoutSync.iss`, and until this page
  nothing ever read them back. This page is that read, in two modes:

    * **Rank** -- an origin, a coverage kind, a scope, and a table of
      systems sorted by `WandererApp.Scout.Planner.rank_plan/1`'s score,
      with every weighted term visible, because section 8's whole gate is
      that a human can read why a system ranked where it did.
    * **Sweep** -- a whole-region route (`WandererApp.Scout.Sweep`),
      start-point suggestions, region heat and a k-way split
      (`WandererApp.Scout.Split`).

  ## A nested LiveView, not a route

  `ScoutIntelLive` is the only thing `live_session :scout` routes to now
  (`router.ex`); this module is rendered INTO it with `live_render/3`,
  kept mounted and hidden (`container: {:div, class: "hidden"}`) once a
  reader has visited the Planner tab, so switching categories never tears
  it down and a computed rank/sweep survives the trip. That is also why
  `mount/3` cannot `push_navigate/2` or `push_patch/2` on a gate failure
  the way the routed page used to -- a child LiveView does not own the
  URL, and both of those raise from one. A failed gate renders a one-line
  `note/1` instead of the planner body (`mount_authorized/1`).

  Because this LiveView sits outside `live_session :scout`, the
  `live_session`'s own `on_mount` chain ([UserAuth, Nav]) never runs for
  it -- `socket.assigns.current_user` would simply not exist. `mount/3`
  calls `WandererAppWeb.UserAuth.on_mount(:ensure_authenticated, ...)`
  directly instead of duplicating its `User.by_id!/1 |> Ash.load!/2`
  lookup, so this socket's `current_user` is resolved exactly the way
  every routed page's is.

  Gated twice, same as before, but now BOTH checks happen in THIS child,
  uncached, never delegated to the parent:

    * `WandererApp.Identity.ScoutAccess.can_view?/1` -- a nested LiveView
      must not trust `ScoutIntelLive` to have already gated the reader;
      the nav icon may read a cached answer, this socket never does.
    * `WandererApp.Env.scout_planner_enabled?/0` -- this page's own
      flag, separate from `WANDERER_SCOUT_INTEL`, because a deployment
      may want the intel log without handing out a ranking nobody has
      tuned yet (design section 8's closing line).

  ## Everything expensive runs in a task

  A rank is a BFS ball plus a metadata read plus a coverage read plus a
  route walk; a sweep is a distance matrix plus a greedy tour plus 2-opt;
  a split spends up to two seconds rebalancing. All three used to run
  inside `handle_event/3`, which blocks that LiveView process: every
  other click queued behind the one in flight, and a mistyped `max_jumps`
  cost a full recompute before the next keystroke was even read. They
  are `start_async/3` now, each carrying a monotonic token so a result
  that arrives after its controls changed is dropped rather than
  rendered, and the previous answer stays on screen (dimmed, with a
  spinner) instead of the page blanking -- which matters more now that
  this child stays mounted across category switches: a stale `start_async`
  token from before the reader left the tab must still be dropped on
  return, not rendered over whatever is current.

  Markup is the `WandererAppWeb.ScoutComponents` vocabulary throughout
  (`panel/1`, `stat/1`, `grid/1`, `field/1`, `note/1`, `busy/1`,
  `scout_toolbar/1`, `scout_pane/1`, `region_picker/1`, …) -- this
  LiveView is reads, same as `ScoutIntelLive`.

  ## Non-goals (design doc, "Non-goals" section)

  No ReactFlow/canvas, no SSE, no live ticking -- the table is re-queried
  on an explicit control change or the Refresh button, never on a timer.
  Chain/wormhole stops may be ranked and shown (`leg != :gate`) but the
  "copy route" box below drops them: the bot only ever waypoints `:gate`
  legs (design section 6, mode A), and showing a hole in a comma-joined
  id list would hand the bot a route it cannot fly.
  """

  use WandererAppWeb, :live_view

  require Logger

  import WandererAppWeb.ScoutComponents

  alias WandererApp.Api.{MapSolarSystem, ScoutSystemCoverage}
  alias WandererApp.Identity.ScoutAccess
  alias WandererApp.Scout.{Assignments, PlanWaypoints, Planner, Regions, Space, Split, Sweep}

  @kinds ~w(visit anoms sigs grid)
  @default_kind :sigs

  @limits [10, 25, 50, 100]
  @default_limit 25

  # Mirrors the planner's own default/cap (contract, design section 5) --
  # a control that accepted more than the planner would honour would
  # just be a lie about what "40" does.
  @default_max_jumps 25
  @max_jumps_cap 40

  @security_keys [:hs, :ls, :ns, :wh, :pochven]
  @default_security [:hs, :ls, :ns]

  # Section 9's cross-region note: a scope beyond this is the same
  # algorithm over a bigger candidate set but nobody has measured or
  # asked for it -- see `ScoutPlanAPIController`'s own copy of this
  # cap, which enforces the same limit on the wire.
  @max_sweep_regions 3
  @max_split_k 6

  @impl true
  def mount(params, session, socket) do
    # `live_session :scout`'s own `on_mount` chain ([UserAuth, Nav]) never
    # runs for this socket -- this LiveView is rendered as a CHILD
    # (`live_render/3` in `scout_intel_live.html.heex`), and child
    # LiveViews do not go through the router's `on_mount` pipeline at
    # all. Calling `UserAuth.on_mount/4` directly, rather than
    # re-deriving `current_user` with a second `User.by_id!/1`, is the
    # "reuse" the moduledoc promises: one lookup, one place it can go
    # stale.
    case WandererAppWeb.UserAuth.on_mount(:ensure_authenticated, params, session, socket) do
      {:cont, authed_socket} ->
        mount_authorized(authed_socket)

      {:halt, _redirected_socket} ->
        # `on_mount/4` would `redirect/2` to `/welcome` here, but this
        # socket is a CHILD -- it does not own the URL, and redirecting
        # out from under `ScoutIntelLive` is not this LiveView's call to
        # make. Render the gate failure in place instead; the original,
        # un-redirected `socket` is what carries it.
        {:ok, assign(socket, access?: false, denial: "Not signed in.")}
    end
  end

  # Re-checked HERE, uncached, independent of whatever `ScoutIntelLive`
  # already decided: see the moduledoc's "gated twice" section -- a
  # nested LiveView that trusted its parent's gate would be one `assign`
  # away from showing the planner to someone `ScoutAccess.can_view?/1`
  # refuses.
  defp mount_authorized(socket) do
    current_user = socket.assigns.current_user

    cond do
      not ScoutAccess.can_view?(current_user.id) ->
        {:ok,
         assign(socket,
           access?: false,
           denial: "You do not have access to the scout planner."
         )}

      not WandererApp.Env.scout_planner_enabled?() ->
        {:ok,
         assign(socket,
           access?: false,
           denial: "The scout planner is not enabled on this deployment."
         )}

      true ->
        # The pilots this user could push a route onto. A route is set
        # through ESI with ONE character's token (a multi-stop route
        # cannot be set from the game client at all), so the page has to
        # name which pilot, and the choice is sticky like every other
        # control here.
        #
        # Sorted by name, case-insensitively, once here rather than in
        # each of the three selects that render it (rank's pilot, the
        # sweep's pilot, and one per split part): the account's own
        # character order is an insertion order nobody can predict, and
        # a list you have to scan is the one place on this page where
        # picking the wrong row writes a route to the wrong pilot.
        characters =
          (current_user.characters || [])
          |> Enum.sort_by(&String.downcase(to_string(&1.name)))

        {:ok,
         socket
         |> assign(
           access?: true,
           origin_q: "",
           origin_matches: [],
           origin_id: nil,
           origin_name: nil,
           kind: @default_kind,
           limit: @default_limit,
           max_jumps: @default_max_jumps,
           regions: [],
           region_q: "",
           region_matches: [],
           security: @default_security,
           security_types: Enum.reject(Space.types(), fn {key, _label} -> key == :other end),
           characters: characters,
           character_eve_id: characters |> List.first() |> character_eve_id(),
           # What the last `Set route` did, kept on the page until the
           # next one (`ScoutComponents.route_outcome/1`). The push's
           # result is invisible from here -- it is in a game client --
           # so a toast that fades was the entire feedback.
           route_status: nil,
           now: DateTime.utc_now(),
           result: nil,
           stops: [],
           candidates: 0,
           generated_at: nil,
           plan_error: nil,
           plan_stops: [],
           route_ids: "",
           rank_loading?: false,
           rank_token: 0,
           # Sweep mode (design doc "whole-region sweeps") -- a second
           # mode on this SAME page, not a second route: `mode` only
           # picks which filter bar and result panel render below.
           mode: :rank,
           sweep_regions: [],
           sweep_region_q: "",
           sweep_region_matches: [],
           sweep_kind: @default_kind,
           sweep_security: @default_security,
           sweep_compress: true,
           # CHEWY PATCH (stable sweeps): on by default. A plan a scout
           # repeats every evening is worth more than a plan that skips
           # what was looked at this morning -- and the drifting version
           # is one click away.
           sweep_stable: true,
           sweep_start: nil,
           sweep_k: 1,
           sweep_result: nil,
           sweep_error: nil,
           sweep_parts: [],
           sweep_pilots: %{},
           sweep_loading?: false,
           sweep_token: 0,
           split_loading?: false,
           split_token: 0,
           region_heat: nil,
           region_heat_kind: nil,
           region_heat_security: nil,
           heat_loading?: false,
           heat_token: 0
         )
         |> load()}
    end
  end

  defp character_eve_id(nil), do: nil
  defp character_eve_id(%{eve_id: eve_id}), do: eve_id

  # -------------------------------------------------------------------
  # Origin search -- `MapSolarSystem.find_by_name/1`, the same
  # code-interface call `map_core_event_handler.ex` / `map_systems_
  # event_handler.ex` already use for the canvas's own system search.
  # -------------------------------------------------------------------

  @impl true
  def handle_event("search_origin", %{"q" => q}, socket) do
    matches =
      case String.trim(q) do
        "" ->
          []

        trimmed ->
          MapSolarSystem.find_by_name!(%{name: trimmed})
          |> Enum.sort_by(& &1.solar_system_name)
          |> Enum.take(10)
      end

    {:noreply, assign(socket, origin_q: q, origin_matches: matches)}
  end

  def handle_event("close_origin_search", _params, socket) do
    {:noreply, assign(socket, origin_matches: [])}
  end

  def handle_event("select_origin", %{"id" => id} = params, socket) do
    case Integer.parse(to_string(id)) do
      {origin_id, ""} ->
        {:noreply,
         socket
         |> assign(
           origin_id: origin_id,
           origin_name: Map.get(params, "name"),
           origin_q: "",
           origin_matches: []
         )
         |> load()
         |> persist_filters()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_origin", _params, socket) do
    {:noreply,
     socket
     |> assign(origin_id: nil, origin_name: nil, origin_q: "", origin_matches: [])
     |> load()
     |> persist_filters()}
  end

  # -------------------------------------------------------------------
  # Scope controls
  # -------------------------------------------------------------------

  def handle_event("select_kind", %{"kind" => kind}, socket) when kind in @kinds do
    {:noreply,
     socket |> assign(kind: String.to_existing_atom(kind)) |> load() |> persist_filters()}
  end

  def handle_event("select_kind", _params, socket), do: {:noreply, socket}

  def handle_event("select_limit", %{"limit" => limit}, socket) do
    case Integer.parse(limit) do
      {value, ""} ->
        if value in @limits do
          {:noreply, socket |> assign(limit: value) |> load() |> persist_filters()}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("update_max_jumps", %{"max_jumps" => value}, socket) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n <= @max_jumps_cap ->
        {:noreply, socket |> assign(max_jumps: n) |> load() |> persist_filters()}

      _ ->
        {:noreply, socket}
    end
  end

  # -------------------------------------------------------------------
  # Region scope -- a searchable vocabulary (`WandererApp.Scout.Regions`),
  # not the `ids, comma-separated` text box both modes used to carry.
  # One set of handlers for both, told apart by `scope`.
  # -------------------------------------------------------------------

  def handle_event("search_regions", %{"scope" => scope, "q" => q}, socket) do
    matches = Regions.search(q)

    case scope do
      "sweep" -> {:noreply, assign(socket, sweep_region_q: q, sweep_region_matches: matches)}
      _rank -> {:noreply, assign(socket, region_q: q, region_matches: matches)}
    end
  end

  def handle_event("close_region_search", %{"scope" => "sweep"}, socket),
    do: {:noreply, assign(socket, sweep_region_matches: [])}

  def handle_event("close_region_search", _params, socket),
    do: {:noreply, assign(socket, region_matches: [])}

  def handle_event("add_region", %{"scope" => scope, "id" => id}, socket) do
    with {region_id, ""} <- Integer.parse(to_string(id)),
         region when not is_nil(region) <- Regions.get(region_id) do
      add_region(socket, scope, region)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove_region", %{"scope" => "sweep", "id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {region_id, ""} ->
        regions = Enum.reject(socket.assigns.sweep_regions, &(&1.region_id == region_id))

        {:noreply,
         socket
         |> assign(sweep_regions: regions)
         |> load_sweep()
         |> persist_filters()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_region", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {region_id, ""} ->
        regions = Enum.reject(socket.assigns.regions, &(&1.region_id == region_id))

        {:noreply, socket |> assign(regions: regions) |> load() |> persist_filters()}

      _ ->
        {:noreply, socket}
    end
  end

  # Reuses `space_chip/1`'s wiring (`phx-click="toggle_space"`,
  # `phx-value-type`) -- the same event name `ScoutIntelLive` uses for
  # its own, unrelated, `@space` filter. Separate LiveView, separate
  # handler, no collision; see `WandererApp.Scout.Space` for why
  # `:other` is excluded from this page's chip set (the planner's
  # `security` option is a closed five-key vocabulary, not Space's six).
  def handle_event("toggle_space", %{"type" => type}, socket) do
    case parse_security_key(type) do
      nil ->
        {:noreply, socket}

      key ->
        security = toggle_security(socket.assigns.security, key)
        {:noreply, socket |> assign(security: security) |> load() |> persist_filters()}
    end
  end

  def handle_event("reset_space", _params, socket) do
    {:noreply, socket |> assign(security: @security_keys) |> load() |> persist_filters()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     case socket.assigns.mode do
       :sweep -> socket |> load_sweep() |> maybe_load_region_heat(force: true)
       _rank -> load(socket)
     end}
  end

  def handle_event("select_character", %{"character_eve_id" => eve_id}, socket) do
    # Validated against the user's OWN characters, not trusted from the
    # form: this id decides whose autopilot gets rewritten.
    if Enum.any?(socket.assigns.characters, &(&1.eve_id == eve_id)) do
      {:noreply, assign(socket, character_eve_id: eve_id)}
    else
      {:noreply, socket}
    end
  end

  # The second write this page has, and the loud one: it replaces what a
  # pilot's client shows. A multi-stop route cannot be set from the game
  # client at all -- only ESI writes an ordered waypoint list -- so this
  # goes out with that character's own token
  # (`WandererApp.Scout.PlanWaypoints`, design section 6 mode A).
  #
  # The outcome is reported, never assumed. Three things could make a
  # route not arrive and the page said "Route set" for all of them: ESI
  # refusing a stop, the character's access token having expired (the
  # POST path has no refresh retry, so every stop 403s), and the pilot
  # not being logged in -- EVE applies waypoints to a RUNNING client
  # only. `PlanWaypoints.push/2` now answers all three, and
  # `route_outcome/1` keeps the answer on the page beside the button
  # instead of in a toast that fades.
  def handle_event("set_route", _params, socket) do
    %{plan_stops: plan_stops, character_eve_id: character_eve_id} = socket.assigns

    push_route(socket, :rank, plan_stops, character_eve_id, "This plan")
  end

  # The page's other write, and the quiet one: destroys the stored coverage row for
  # this system + the SELECTED kind, the reader's "re-scout this now"
  # override (design doc section 9, "operator wants a system re-done
  # now"). Not a soft archive like the intel log's structure board --
  # there is nothing to undo here, the row is just gone until eveknob
  # reports this system again.
  def handle_event("mark_stale", %{"id" => id}, socket) do
    with {system_id, ""} <- Integer.parse(to_string(id)),
         {:ok, row} <-
           ScoutSystemCoverage.by_system_and_kind(system_id, socket.assigns.kind) do
      case ScoutSystemCoverage.destroy(row) do
        :ok -> {:noreply, load(socket)}
        {:ok, _destroyed} -> {:noreply, load(socket)}
        _ -> {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # -------------------------------------------------------------------
  # Sweep mode (design doc "whole-region sweeps") -- a second mode on
  # this same page: scope is a MEMBERSHIP (regions), not a ball, and a
  # sweep drives its own route, start-point suggestions, region heat
  # table and k-way split instead of `rank/1`'s single ranked list.
  # -------------------------------------------------------------------

  def handle_event("switch_mode", %{"mode" => mode}, socket) when mode in ~w(rank sweep) do
    {:noreply,
     socket
     |> assign(mode: String.to_existing_atom(mode))
     |> maybe_load_region_heat()
     |> persist_filters()}
  end

  def handle_event("switch_mode", _params, socket), do: {:noreply, socket}

  def handle_event("select_sweep_kind", %{"kind" => kind}, socket) when kind in @kinds do
    {:noreply,
     socket
     |> assign(sweep_kind: String.to_existing_atom(kind))
     |> load_sweep()
     |> maybe_load_region_heat(force: true)
     |> persist_filters()}
  end

  def handle_event("select_sweep_kind", _params, socket), do: {:noreply, socket}

  # The region heat table counts the SAME bands the sweep will visit
  # (`Sweep.region_heat/2`), so a band change invalidates it exactly
  # like a kind change does -- `maybe_load_region_heat/1` compares both.
  def handle_event("toggle_sweep_space", %{"type" => type}, socket) do
    case parse_security_key(type) do
      nil ->
        {:noreply, socket}

      key ->
        security = toggle_security(socket.assigns.sweep_security, key)

        {:noreply,
         socket
         |> assign(sweep_security: security)
         |> load_sweep()
         |> maybe_load_region_heat()
         |> persist_filters()}
    end
  end

  def handle_event("reset_sweep_space", _params, socket) do
    {:noreply,
     socket
     |> assign(sweep_security: @security_keys)
     |> load_sweep()
     |> maybe_load_region_heat()
     |> persist_filters()}
  end

  def handle_event("toggle_sweep_compress", _params, socket) do
    {:noreply,
     socket
     |> assign(sweep_compress: !socket.assigns.sweep_compress)
     |> load_sweep()
     |> persist_filters()}
  end

  # CHEWY PATCH (stable sweeps): see `sweep_opts/1` and `load_split/1`.
  # Both halves of the drift are turned off together on purpose -- a
  # membership that still moved would make a deterministic split
  # pointless, and a deterministic membership whose split still stopped
  # at a wall clock would still hand back different parts under load.
  def handle_event("toggle_sweep_stable", _params, socket) do
    {:noreply,
     socket
     |> assign(sweep_stable: !socket.assigns.sweep_stable)
     |> load_sweep()
     |> persist_filters()}
  end

  def handle_event("select_sweep_start", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {value, ""} ->
        {:noreply, socket |> assign(sweep_start: value) |> load_sweep() |> persist_filters()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_sweep_start", _params, socket) do
    {:noreply, socket |> assign(sweep_start: nil) |> load_sweep() |> persist_filters()}
  end

  def handle_event("update_sweep_k", %{"k" => k}, socket) do
    case Integer.parse(k) do
      {value, ""} when value >= 1 and value <= @max_split_k ->
        {:noreply, socket |> assign(sweep_k: value) |> load_split() |> persist_filters()}

      _ ->
        {:noreply, socket}
    end
  end

  # A heat row is the cheapest way into a sweep: picking the scope stops
  # being guesswork (design doc "which region to sweep at all" section),
  # so clicking one sets the scope AND switches into sweep mode in one
  # step.
  def handle_event("select_region_heat", %{"id" => id}, socket) do
    with {region_id, ""} <- Integer.parse(to_string(id)),
         region when not is_nil(region) <- Regions.get(region_id) do
      {:noreply,
       socket
       |> assign(mode: :sweep, sweep_regions: [region], sweep_region_q: "")
       |> load_sweep()
       |> persist_filters()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "select_part_character",
        %{"part" => idx, "character_eve_id" => eve_id},
        socket
      ) do
    with {index, ""} <- Integer.parse(idx),
         true <- Enum.any?(socket.assigns.characters, &(&1.eve_id == eve_id)) do
      {:noreply,
       assign(socket, sweep_pilots: Map.put(socket.assigns.sweep_pilots, index, eve_id))}
    else
      _ -> {:noreply, socket}
    end
  end

  # Pushes ONE split part's route -- `Split.split/3`'s `order` field,
  # already a route over that part's own systems, not the whole sweep.
  # Every stop in a sweep route is gate-reachable k-space
  # (`Sweep.distances/1`'s contract: the full k-space graph, no chain
  # overlay), so every stop is pushable the way `PlanWaypoints` already
  # filters rank's stops -- `leg: :gate` on each one.
  def handle_event("set_part_route", %{"part" => idx}, socket) do
    with {index, ""} <- Integer.parse(idx),
         part when not is_nil(part) <-
           Enum.find(socket.assigns.sweep_parts, &(&1.index == index)),
         eve_id when not is_nil(eve_id) <- Map.get(socket.assigns.sweep_pilots, index) do
      stops = Enum.map(part.order, &%{solar_system_id: &1, leg: :gate})

      push_route(socket, {:part, index}, stops, eve_id, "Part #{index + 1}")
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "Pick a pilot for this part before setting its route.")}
    end
  end

  # The whole-sweep push -- `result.waypoints` is already the compressed
  # (or full) ordered id list, so unlike rank mode's `set_route/2` there
  # is no second pass to keep in sync with: this button and the sweep
  # table above it read the same field.
  def handle_event("set_sweep_route", _params, socket) do
    %{sweep_result: result, character_eve_id: character_eve_id} = socket.assigns

    if is_nil(result) do
      {:noreply, socket}
    else
      stops = Enum.map(result.waypoints, &%{solar_system_id: &1, leg: :gate})

      push_route(socket, :sweep, stops, character_eve_id, "This sweep")
    end
  end

  # The one call that makes a split STOP competing with itself: every
  # part's systems land in `scout_assignments_v1` under one
  # `assignment_id` in a single call, rather than each part's own
  # `Set route` silently leaving every other part's systems unclaimed
  # for anyone else who runs a sweep over the same scope.
  def handle_event("assign_all_parts", _params, socket) do
    %{sweep_parts: parts, sweep_pilots: pilots, sweep_kind: kind} = socket.assigns

    assignments =
      parts
      |> Enum.map(fn part ->
        case Map.get(pilots, part.index) do
          nil -> nil
          eve_id -> %{character_eve_id: eve_id, system_ids: part.system_ids}
        end
      end)
      |> Enum.reject(&is_nil/1)

    cond do
      parts == [] ->
        {:noreply, put_flash(socket, :error, "Nothing to assign -- run a sweep first.")}

      length(assignments) != length(parts) ->
        {:noreply, put_flash(socket, :error, "Pick a pilot for every part before assigning.")}

      true ->
        case Assignments.assign(assignments, kind: kind) do
          {:ok, %{rows: rows}} ->
            {:noreply,
             put_flash(
               socket,
               :info,
               "Assigned #{rows} #{plural(rows, "system", "systems")} across #{length(parts)} #{plural(length(parts), "part", "parts")}."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not assign: #{reason}.")}
        end
    end
  end

  # -------------------------------------------------------------------
  # Sticky filters -- same `LocalStorageSetting` idiom as `ScoutIntelLive`
  # (`lib/wanderer_app_web/live/scout/scout_intel_live.ex`), own key so
  # the two pages' saved state never collides, everything re-validated
  # on restore like a click: localStorage is user-writable, and
  # `String.to_existing_atom/1` on a stored string is how a page
  # crashes on mount.
  # -------------------------------------------------------------------

  @filter_store "scout_planner_filters"

  def handle_event("ls_restore_#{@filter_store}", %{"value" => value}, socket) do
    case restore_filters(socket, value) do
      {:ok, socket} -> {:noreply, socket |> load() |> load_sweep() |> maybe_load_region_heat()}
      :unchanged -> {:noreply, socket}
    end
  end

  defp persist_filters(socket) do
    state = %{
      "origin_id" => socket.assigns.origin_id,
      "origin_name" => socket.assigns.origin_name,
      "kind" => to_string(socket.assigns.kind),
      "limit" => socket.assigns.limit,
      "max_jumps" => socket.assigns.max_jumps,
      "regions" => region_ids(socket.assigns.regions),
      "security" => Enum.map(socket.assigns.security, &to_string/1),
      "mode" => to_string(socket.assigns.mode),
      "sweep_regions" => region_ids(socket.assigns.sweep_regions),
      "sweep_kind" => to_string(socket.assigns.sweep_kind),
      "sweep_security" => Enum.map(socket.assigns.sweep_security, &to_string/1),
      "sweep_compress" => socket.assigns.sweep_compress,
      "sweep_stable" => socket.assigns.sweep_stable,
      "sweep_start" => socket.assigns.sweep_start,
      "sweep_k" => socket.assigns.sweep_k
    }

    push_event(socket, "ls_update_#{@filter_store}", %{value: Jason.encode!(state)})
  end

  defp restore_filters(socket, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = saved} ->
        {:ok,
         assign(socket,
           origin_id: restore_origin_id(saved),
           origin_name: restore_origin_name(saved),
           kind: restore_kind(saved, socket.assigns.kind),
           limit: restore_limit(saved, socket.assigns.limit),
           max_jumps: restore_max_jumps(saved, socket.assigns.max_jumps),
           regions: restore_regions(saved, "regions", nil),
           security: restore_security(saved),
           mode: restore_mode(saved, socket.assigns.mode),
           sweep_regions: restore_regions(saved, "sweep_regions", @max_sweep_regions),
           sweep_kind: restore_sweep_kind(saved, socket.assigns.sweep_kind),
           sweep_security: restore_sweep_security(saved),
           sweep_compress: restore_sweep_compress(saved, socket.assigns.sweep_compress),
           sweep_stable: restore_sweep_stable(saved, socket.assigns.sweep_stable),
           sweep_start: restore_sweep_start(saved),
           sweep_k: restore_sweep_k(saved, socket.assigns.sweep_k)
         )}

      _ ->
        :unchanged
    end
  end

  defp restore_filters(_socket, _value), do: :unchanged

  defp restore_origin_id(%{"origin_id" => id}) when is_integer(id) and id > 0, do: id
  defp restore_origin_id(_saved), do: nil

  defp restore_origin_name(%{"origin_name" => name}) when is_binary(name),
    do: String.slice(name, 0, 100)

  defp restore_origin_name(_saved), do: nil

  defp restore_kind(%{"kind" => kind}, _default) when kind in @kinds,
    do: String.to_existing_atom(kind)

  defp restore_kind(_saved, default), do: default

  defp restore_limit(%{"limit" => limit}, default) when is_integer(limit) do
    if limit in @limits, do: limit, else: default
  end

  defp restore_limit(_saved, default), do: default

  defp restore_max_jumps(%{"max_jumps" => n}, default) when is_integer(n) do
    if n > 0 and n <= @max_jumps_cap, do: n, else: default
  end

  defp restore_max_jumps(_saved, default), do: default

  # A stored region id is re-resolved against the live vocabulary, never
  # trusted: an id that no longer names a k-space region (an SDE change,
  # or a hand-edited localStorage entry) has to vanish, not render as a
  # blank chip scoping every query to nothing.
  defp restore_regions(saved, key, max) do
    regions =
      saved
      |> Map.get(key, [])
      |> List.wrap()
      |> Enum.filter(&is_integer/1)
      |> Regions.resolve()

    if max, do: Enum.take(regions, max), else: regions
  end

  defp restore_security(%{"security" => saved}) when is_list(saved) do
    keys =
      saved
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&parse_security_key/1)
      |> Enum.reject(&is_nil/1)

    if saved == [], do: [], else: if(keys == [], do: @default_security, else: keys)
  end

  defp restore_security(_saved), do: @default_security

  defp restore_mode(%{"mode" => mode}, _default) when mode in ~w(rank sweep),
    do: String.to_existing_atom(mode)

  defp restore_mode(_saved, default), do: default

  defp restore_sweep_kind(%{"sweep_kind" => kind}, _default) when kind in @kinds,
    do: String.to_existing_atom(kind)

  defp restore_sweep_kind(_saved, default), do: default

  defp restore_sweep_security(%{"sweep_security" => saved}) when is_list(saved) do
    keys =
      saved
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&parse_security_key/1)
      |> Enum.reject(&is_nil/1)

    if saved == [], do: [], else: if(keys == [], do: @default_security, else: keys)
  end

  defp restore_sweep_security(_saved), do: @default_security

  defp restore_sweep_compress(%{"sweep_compress" => value}, _default) when is_boolean(value),
    do: value

  defp restore_sweep_compress(_saved, default), do: default

  defp restore_sweep_stable(%{"sweep_stable" => value}, _default) when is_boolean(value),
    do: value

  defp restore_sweep_stable(_saved, default), do: default

  defp restore_sweep_start(%{"sweep_start" => id}) when is_integer(id) and id > 0, do: id
  defp restore_sweep_start(_saved), do: nil

  defp restore_sweep_k(%{"sweep_k" => k}, default) when is_integer(k) do
    if k >= 1 and k <= @max_split_k, do: k, else: default
  end

  defp restore_sweep_k(_saved, default), do: default

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp region_ids(regions), do: Enum.map(regions, & &1.region_id)

  defp add_region(socket, "sweep", region) do
    regions = socket.assigns.sweep_regions

    cond do
      Enum.any?(regions, &(&1.region_id == region.region_id)) ->
        {:noreply, assign(socket, sweep_region_q: "", sweep_region_matches: [])}

      length(regions) >= @max_sweep_regions ->
        {:noreply,
         socket
         |> assign(sweep_region_q: "", sweep_region_matches: [])
         |> put_flash(
           :error,
           "A sweep covers at most #{@max_sweep_regions} regions -- drop one first."
         )}

      true ->
        {:noreply,
         socket
         |> assign(
           sweep_regions: regions ++ [region],
           sweep_region_q: "",
           sweep_region_matches: []
         )
         |> load_sweep()
         |> persist_filters()}
    end
  end

  defp add_region(socket, _rank, region) do
    regions = socket.assigns.regions

    if Enum.any?(regions, &(&1.region_id == region.region_id)) do
      {:noreply, assign(socket, region_q: "", region_matches: [])}
    else
      {:noreply,
       socket
       |> assign(regions: regions ++ [region], region_q: "", region_matches: [])
       |> load()
       |> persist_filters()}
    end
  end

  defp character_name(characters, eve_id) do
    case Enum.find(characters, &(&1.eve_id == eve_id)) do
      nil -> "that character"
      character -> character.name
    end
  end

  # One place every `Set route` button reports through: the push, then
  # the SAME sentence in the toast and in `route_outcome/1` beside the
  # button, keyed to `scope` so a part's result cannot read as the whole
  # sweep's.
  defp push_route(socket, scope, stops, character_eve_id, label) do
    name = character_name(socket.assigns.characters, character_eve_id)

    status =
      stops
      |> PlanWaypoints.push(character_eve_id)
      |> push_status(name, label)
      |> Map.put(:scope, scope)

    {:noreply,
     socket
     |> assign(route_status: status)
     |> put_flash(if(status.level == :error, do: :error, else: :info), status.text)}
  end

  defp push_status({:error, :no_gate_stops}, _name, label),
    do: %{level: :error, text: "#{label} has no gate-reachable stops to fly."}

  defp push_status({:error, :unknown_character}, _name, _label),
    do: %{
      level: :error,
      text: "Pick a character this instance tracks before setting a route."
    }

  # The token case is the one a reader can fix, so it says how: this
  # instance refreshes an expired token on the preflight call, and the
  # only way that still fails is a revoked or never-granted grant.
  defp push_status({:error, {:token, reason}}, name, _label),
    do: %{
      level: :error,
      text:
        "EVE would not accept #{name}'s token (#{esi_reason(reason)}). " <>
          "Nothing was sent. Re-authorise that character on the Characters page, then try again."
    }

  defp push_status({:ok, %{pushed: [], total: total, error: error}}, name, _label)
       when not is_nil(error),
       do: %{
         level: :error,
         text:
           "ESI refused the first of #{total} stops (system #{error.solar_system_id}): " <>
             "#{esi_reason(error.reason)}. #{name}'s in-game route is unchanged."
       }

  # A partial push is a real route, just not this one: the stops that
  # landed are a valid prefix, which is why the push halts instead of
  # skipping the refused stop.
  defp push_status({:ok, %{pushed: pushed, total: total, error: error}}, name, _label)
       when not is_nil(error),
       do: %{
         level: :warn,
         text:
           "Stopped at stop #{error.index + 1} of #{total} (system #{error.solar_system_id}): " <>
             "#{esi_reason(error.reason)}. #{name} has the first " <>
             "#{length(pushed)} #{plural(length(pushed), "waypoint", "waypoints")} only."
       }

  # ESI accepts a waypoint for a character whose client is not running
  # and discards it. That is exactly the "I set it and nothing happened"
  # report this page could not explain, so it is a warning, not a tick.
  defp push_status({:ok, %{pushed: pushed, online?: false}}, name, _label),
    do: %{
      level: :warn,
      text:
        "EVE accepted #{length(pushed)} #{plural(length(pushed), "waypoint", "waypoints")}, " <>
          "but reports #{name} as not logged in — waypoints only reach a running client, " <>
          "so this route went nowhere. Log that character in and set it again."
    }

  defp push_status({:ok, %{pushed: pushed}}, name, _label),
    do: %{
      level: :ok,
      text:
        "Route set on #{name}: #{length(pushed)} " <>
          "#{plural(length(pushed), "waypoint", "waypoints")} at " <>
          "#{Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")}Z."
    }

  defp esi_reason(:forbidden), do: "ESI answered 403 Forbidden"
  defp esi_reason(:timeout), do: "ESI timed out"
  defp esi_reason(:pool_timeout), do: "no HTTP connection was available"
  defp esi_reason(:error_limited), do: "ESI rate-limited this instance"
  defp esi_reason(:no_token), do: "this instance holds no access token for it"
  defp esi_reason(reason) when is_binary(reason), do: reason
  defp esi_reason(reason) when is_atom(reason), do: to_string(reason)
  defp esi_reason(%{__exception__: true} = error), do: Exception.message(error)
  defp esi_reason(reason), do: inspect(reason)

  defp parse_security_key(type) when type in ~w(hs ls ns wh pochven),
    do: String.to_existing_atom(type)

  defp parse_security_key(_type), do: nil

  defp toggle_security(selected, key) do
    if key in selected do
      List.delete(selected, key)
    else
      Enum.filter(@security_keys, &(&1 in [key | selected]))
    end
  end

  defp count_reason(stops, reason), do: Enum.count(stops, &(&1.reason == reason))

  # "Copy route": the ordered id list the bot gets from `GET
  # /scout/plan`, which means `Planner.plan/1`'s nearest-neighbour walk,
  # NOT this page's score order -- a human who copies this and a bot that
  # fetches a plan must fly the same thing, or the button is a lie the
  # first time someone compares them.
  #
  # Gate legs only (design section 6, mode A): a chain/wormhole stop is
  # ranked and shown on this page but was never going to be a waypoint,
  # and `plan/1` already stops the list at the first non-`:gate` leg.
  defp route_ids(stops) do
    stops
    |> Enum.filter(&(&1.leg == :gate))
    |> Enum.map(& &1.solar_system_id)
    |> Enum.join(",")
  end

  # -------------------------------------------------------------------
  # Reads -- every one of them in a task. See moduledoc.
  #
  # The token is what makes a fast click safe: `start_async/3` does not
  # cancel an in-flight task, so without it a slow rank for the origin
  # you just left would land on top of the fast one for the origin you
  # just picked.
  # -------------------------------------------------------------------

  defp load(socket) do
    socket = assign(socket, now: DateTime.utc_now())

    if socket.assigns.origin_id && connected?(socket) do
      opts = plan_opts(socket)
      token = socket.assigns.rank_token + 1

      socket
      |> assign(rank_token: token, rank_loading?: true)
      |> start_async({:rank, token}, fn -> Planner.rank_plan(opts) end)
    else
      assign(socket,
        rank_loading?: false,
        rank_token: socket.assigns.rank_token + 1,
        result: nil,
        stops: [],
        candidates: 0,
        generated_at: nil,
        plan_stops: [],
        route_ids: "",
        plan_error: nil
      )
    end
  end

  defp plan_opts(socket) do
    [
      origin: socket.assigns.origin_id,
      kind: socket.assigns.kind,
      limit: socket.assigns.limit,
      max_jumps: socket.assigns.max_jumps,
      regions: region_ids(socket.assigns.regions),
      security: socket.assigns.security
    ]
  end

  @impl true
  def handle_async({:rank, token}, result, socket) do
    if token == socket.assigns.rank_token do
      {:noreply, apply_rank(socket, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:sweep, token}, result, socket) do
    if token == socket.assigns.sweep_token do
      {:noreply, apply_sweep(socket, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:split, token}, result, socket) do
    if token == socket.assigns.split_token do
      {:noreply, apply_split(socket, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:heat, token}, result, socket) do
    if token == socket.assigns.heat_token do
      {:noreply, apply_heat(socket, result)}
    else
      {:noreply, socket}
    end
  end

  defp apply_rank(socket, {:ok, {:ok, %{rank: rank, plan: plan}}}) do
    assign(socket,
      rank_loading?: false,
      now: DateTime.utc_now(),
      result: rank,
      stops: rank.stops,
      candidates: rank.candidates,
      generated_at: rank.generated_at,
      plan_stops: plan.stops,
      route_ids: route_ids(plan.stops),
      plan_error: nil
    )
  end

  defp apply_rank(socket, {:ok, {:error, reason}}), do: rank_failed(socket, reason)

  defp apply_rank(socket, {:exit, reason}) do
    Logger.error("[scout planner] rank task exited: #{inspect(reason)}")
    rank_failed(socket, :planner_crashed)
  end

  defp rank_failed(socket, reason) do
    assign(socket,
      rank_loading?: false,
      result: nil,
      stops: [],
      candidates: 0,
      generated_at: nil,
      plan_stops: [],
      route_ids: "",
      plan_error: reason
    )
  end

  # -------------------------------------------------------------------
  # Sweep reads
  # -------------------------------------------------------------------

  defp load_sweep(socket) do
    socket = assign(socket, now: DateTime.utc_now())

    if socket.assigns.sweep_regions == [] or not connected?(socket) do
      assign(socket,
        sweep_result: nil,
        sweep_error: nil,
        sweep_parts: [],
        sweep_pilots: %{},
        sweep_loading?: false,
        sweep_token: socket.assigns.sweep_token + 1
      )
    else
      build_opts = sweep_opts(socket)
      token = socket.assigns.sweep_token + 1

      socket
      |> assign(sweep_token: token, sweep_loading?: true)
      |> start_async({:sweep, token}, fn -> Sweep.sweep(build_opts.()) end)
    end
  end

  # Two things normally make a sweep's MEMBERSHIP time-dependent, and
  # together they are why the same region handed back different parts and
  # different start systems on different evenings:
  #
  #   * freshness -- anything inside `Planner.ttl_seconds(kind, class)` of
  #     its last coverage row is dropped, so a system scouted this morning
  #     silently leaves the route;
  #   * `exclude` -- the hard-zero half of `scout_assignments_v1` (design
  #     doc section 5): once "Assign all" claims a part's systems, the
  #     next sweep over the same scope must not re-offer them.
  #
  # Both are right for "what still needs doing right now" and wrong for
  # "the route I fly every evening", so `sweep_stable` turns both off and
  # takes the scope exactly as the region and the ticked bands define it.
  #
  # Returned as a thunk so the `Assignments` read runs inside the task
  # too -- it is a database round trip, and the point of the task is that
  # the LiveView process does none of them.
  defp sweep_opts(socket) do
    regions = region_ids(socket.assigns.sweep_regions)
    kind = socket.assigns.sweep_kind
    security = socket.assigns.sweep_security
    start = socket.assigns.sweep_start
    compress = socket.assigns.sweep_compress
    stable = socket.assigns.sweep_stable

    fn ->
      [
        scope: {:regions, regions},
        kind: kind,
        security: security,
        start: start,
        compress: compress,
        include_fresh: stable,
        exclude:
          if(stable, do: [], else: kind |> Assignments.active_system_ids() |> MapSet.to_list())
      ]
    end
  end

  defp apply_sweep(socket, {:ok, {:ok, result}}) do
    socket
    |> assign(
      sweep_loading?: false,
      now: DateTime.utc_now(),
      sweep_result: result,
      sweep_error: nil
    )
    |> load_split()
  end

  defp apply_sweep(socket, {:ok, {:error, reason}}), do: sweep_failed(socket, reason)

  defp apply_sweep(socket, {:exit, reason}) do
    Logger.error("[scout planner] sweep task exited: #{inspect(reason)}")
    sweep_failed(socket, :sweep_crashed)
  end

  defp sweep_failed(socket, reason) do
    assign(socket,
      sweep_loading?: false,
      split_loading?: false,
      sweep_result: nil,
      sweep_error: reason,
      sweep_parts: [],
      sweep_pilots: %{}
    )
  end

  # k=1 is just the sweep above with nowhere to split; `Split.split/3`
  # only runs once a second pilot is actually in the picture -- and it
  # rebalances for seconds, which is exactly why it is its own task
  # rather than a tail of the sweep's.
  #
  # `budget_ms: 0` under `sweep_stable`: the rebalance loop normally
  # stops at a 2s WALL CLOCK, which makes the partition depend on how
  # busy the box was, not only on the input. Measured on a 189-system
  # graph (2026-10-06): k=3 converges in 4.8s and k=4 in 2.5s, where the
  # budget never binds and the answer is already the exhaustive one; only
  # k=2 runs long (62s), because its parts are biggest and its boundary
  # longest. Stable mode buys determinism at that price; the default
  # (unstable) path keeps the clock.
  defp load_split(socket) do
    %{sweep_result: result, sweep_k: k, sweep_stable: stable} = socket.assigns

    if is_nil(result) or k <= 1 do
      assign(socket,
        sweep_parts: [],
        sweep_pilots: %{},
        split_loading?: false,
        split_token: socket.assigns.split_token + 1
      )
    else
      system_ids = Enum.map(result.stops, & &1.solar_system_id)
      token = socket.assigns.split_token + 1
      opts = if stable, do: [budget_ms: 0], else: []

      socket
      |> assign(split_token: token, split_loading?: true)
      |> start_async({:split, token}, fn -> Split.split(system_ids, k, opts) end)
    end
  end

  defp apply_split(socket, {:ok, {:ok, parts}}) do
    pilots = default_pilots(parts, socket.assigns.characters, socket.assigns.sweep_pilots)

    assign(socket, split_loading?: false, sweep_parts: parts, sweep_pilots: pilots)
  end

  defp apply_split(socket, {:ok, {:error, _reason}}),
    do: assign(socket, split_loading?: false, sweep_parts: [], sweep_pilots: %{})

  defp apply_split(socket, {:exit, reason}) do
    Logger.error("[scout planner] split task exited: #{inspect(reason)}")
    assign(socket, split_loading?: false, sweep_parts: [], sweep_pilots: %{})
  end

  # Keeps an operator's existing picks (changing `k` by one should not
  # scramble every other part's pilot) and otherwise round-robins the
  # user's own tracked characters so every part starts with a usable
  # pilot instead of a blank select.
  defp default_pilots(parts, characters, existing) do
    pool_size = max(length(characters), 1)

    Enum.into(parts, %{}, fn part ->
      eve_id =
        Map.get(existing, part.index) ||
          characters |> Enum.at(rem(part.index, pool_size)) |> character_eve_id()

      {part.index, eve_id}
    end)
  end

  # Loaded once per (kind, security band set), not on every keystroke: a
  # region's heat changes on a human timescale (coverage rows arriving),
  # so recompute only on entering sweep mode, changing `kind`, or
  # changing which space is counted -- not on every scope edit.
  # `force: true` is select_sweep_kind/3's escape hatch.
  defp maybe_load_region_heat(socket, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    %{
      mode: mode,
      sweep_kind: kind,
      sweep_security: security,
      region_heat: heat,
      region_heat_kind: heat_kind,
      region_heat_security: heat_security
    } = socket.assigns

    stale? = is_nil(heat) or heat_kind != kind or heat_security != Enum.sort(security)

    if connected?(socket) and mode == :sweep and (force or stale?) do
      token = socket.assigns.heat_token + 1

      socket
      |> assign(
        heat_token: token,
        heat_loading?: true,
        region_heat_kind: kind,
        region_heat_security: Enum.sort(security)
      )
      |> start_async({:heat, token}, fn -> Sweep.region_heat(kind, security) end)
    else
      socket
    end
  end

  defp apply_heat(socket, {:ok, rows}) when is_list(rows),
    do: assign(socket, heat_loading?: false, region_heat: sort_region_heat(rows))

  defp apply_heat(socket, {:exit, reason}) do
    Logger.error("[scout planner] region heat task exited: #{inspect(reason)}")
    assign(socket, heat_loading?: false, region_heat: [])
  end

  defp apply_heat(socket, _other), do: assign(socket, heat_loading?: false)

  # Worst-covered first: `unseen + stale` descending, then median age
  # descending (nil -- no coverage row has ever landed for this region
  # at all -- sorts as worse than any real age).
  defp sort_region_heat(rows) do
    Enum.sort_by(rows, fn row ->
      {-(row.stale + row.unseen), -(row.median_age_s || 999_999_999)}
    end)
  end

  # GUESS, labelled as one in the UI: 5 min/system (design doc "time,
  # which is the real constraint" section), jump time folded in as
  # negligible beside it, same as the design doc's own estimate.
  defp sweep_hours(systems) do
    :erlang.float_to_binary(systems * 5 / 60, decimals: 1) <> "h"
  end

  # The band set in words, for the two places that must say which space
  # a number counts: the sweep toolbar's inline note and the region heat
  # panel's hint. Reads the chip labels rather than a second spelling of
  # them, in chip order, so "Low" here is the chip the operator clicked.
  defp security_summary(security) do
    case Enum.filter(Space.types(), fn {key, _label} -> key in security end) do
      [] -> "no space at all"
      [{_key, label}] -> "#{label} only"
      labels -> labels |> Enum.map(&elem(&1, 1)) |> Enum.join(", ")
    end
  end

  defp start_name(start_id, stops) do
    case Enum.find(stops, &(&1.solar_system_id == start_id)) do
      nil -> to_string(start_id)
      stop -> stop.name
    end
  end
end
