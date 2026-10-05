defmodule WandererAppWeb.ScoutRefreshLive do
  @moduledoc """
  CHEWY PATCH: the "Refresh queue" tab on `/scout` -- design doc
  `docs/design/wanderer-scout-planner.md` section 8, "the human surface:
  a list, not a canvas".

  Phase 1 of that feature shipped the write path: `scout_system_coverage_v1`
  rows land here from eveknob's `obj_ScoutSync.iss`, and until this page
  nothing ever read them back. This page is that read: an operator picks
  an origin, a coverage kind, a scope, and gets a table of systems sorted
  by `WandererApp.Scout.Planner.rank/1`'s score -- the same ranking the
  bot's `GET /scout/plan` endpoint drives its route from, rendered with
  every weighted term visible, because section 8's whole gate is that a
  human can read why a system ranked where it did.

  Gated twice, the same way `ScoutIntelLive` is gated once:

    * `WandererApp.Identity.ScoutAccess.can_view?/1`, uncached, exactly
      like `ScoutIntelLive` -- the nav icon may read a cached answer,
      the page itself never does.
    * `WandererApp.Env.scout_planner_enabled?/0` -- this page's own
      flag, separate from `WANDERER_SCOUT_INTEL`, because a deployment
      may want the intel log without handing out a ranking nobody has
      tuned yet (design section 8's closing line). The route stays
      registered; a disabled flag redirects to `/scout` with a flash
      instead of 404ing, since the flag is a product decision, not a
      missing feature.

  Markup is the `WandererAppWeb.ScoutComponents` vocabulary throughout
  (`panel/1`, `stat/1`, `grid/1`, `empty/1`, `space_chip/1`, plus the
  refresh-specific cells added alongside this module) -- this LiveView
  is reads, same as `ScoutIntelLive`.

  ## Non-goals (design doc, "Non-goals" section)

  No ReactFlow/canvas, no SSE, no live ticking -- the table is re-queried
  on an explicit control change or the Refresh button, never on a timer.
  Chain/wormhole stops may be ranked and shown (`leg != :gate`) but the
  "copy route" box below drops them: the bot only ever waypoints `:gate`
  legs (design section 6, mode A), and showing a hole in a comma-joined
  id list would hand the bot a route it cannot fly.
  """

  use WandererAppWeb, :live_view

  import WandererAppWeb.ScoutComponents

  alias WandererApp.Api.{MapSolarSystem, ScoutSystemCoverage}
  alias WandererApp.Identity.ScoutAccess
  alias WandererApp.Scout.{Planner, PlanWaypoints, Space, Sweep, Split, Assignments}

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
  def mount(_params, _session, socket) do
    cond do
      not ScoutAccess.can_view?(socket.assigns.current_user.id) ->
        {:ok, push_navigate(socket, to: ~p"/maps")}

      not WandererApp.Env.scout_planner_enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, "The scout refresh planner is not enabled on this deployment.")
         |> push_navigate(to: ~p"/scout")}

      true ->
        # The pilots this user could push a route onto. A route is set
        # through ESI with ONE character's token (a multi-stop route
        # cannot be set from the game client at all), so the page has to
        # name which pilot -- there is no sensible default beyond "the
        # first one you own", and the choice is sticky like every other
        # control here.
        characters = socket.assigns.current_user.characters || []

        {:ok,
         socket
         |> assign(
           active_tab: :scout_refresh,
           page_title: "Scout Refresh Queue",
           origin_q: "",
           origin_matches: [],
           origin_id: nil,
           origin_name: nil,
           kind: @default_kind,
           limit: @default_limit,
           max_jumps: @default_max_jumps,
           regions_q: "",
           regions: [],
           security: @default_security,
           security_types: Enum.reject(Space.types(), fn {key, _label} -> key == :other end),
           characters: characters,
           character_eve_id: characters |> List.first() |> character_eve_id(),
           now: DateTime.utc_now(),
           result: nil,
           stops: [],
           candidates: 0,
           generated_at: nil,
           plan_error: nil,
           # Sweep mode (design doc "whole-region sweeps") -- a second
           # mode on this SAME page, not a second route: `mode` only
           # picks which filter bar and result panel render below.
           mode: :rank,
           sweep_regions_q: "",
           sweep_regions: [],
           sweep_kind: @default_kind,
           sweep_security: @default_security,
           sweep_compress: true,
           sweep_start: nil,
           sweep_k: 1,
           sweep_result: nil,
           sweep_error: nil,
           sweep_parts: [],
           sweep_pilots: %{},
           region_heat: nil,
           region_heat_kind: nil
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

  def handle_event("select_origin", %{"id" => id} = params, socket) do
    case Integer.parse(to_string(id)) do
      {origin_id, ""} ->
        {:noreply,
         socket
         |> assign(
           origin_id: origin_id,
           origin_name: Map.get(params, "name"),
           origin_q: "",
           origin_matches: [],
           limit: socket.assigns.limit
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

  def handle_event("update_regions", %{"regions" => text}, socket) do
    {:noreply,
     socket
     |> assign(regions_q: text, regions: parse_region_ids(text))
     |> load()
     |> persist_filters()}
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

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

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
  # The pushed count is reported, never assumed: the push halts on the
  # first ESI refusal rather than skipping a stop, so a short route is a
  # PREFIX of the plan and the flash has to say so.
  def handle_event("set_route", _params, socket) do
    %{plan_stops: plan_stops, character_eve_id: character_eve_id} = socket.assigns

    case PlanWaypoints.push(plan_stops, character_eve_id) do
      {:ok, pushed} ->
        gate_count = Enum.count(plan_stops, &(&1.leg == :gate))
        name = character_name(socket.assigns.characters, character_eve_id)

        {:noreply, put_flash(socket, :info, push_message(length(pushed), gate_count, name))}

      {:error, :no_gate_stops} ->
        {:noreply, put_flash(socket, :error, "This plan has no gate-reachable stops to fly.")}

      {:error, :unknown_character} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Pick a character this instance tracks before setting a route."
         )}
    end
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

  def handle_event("update_sweep_regions", %{"regions" => text}, socket) do
    ids = text |> parse_region_ids() |> Enum.take(@max_sweep_regions)

    {:noreply,
     socket
     |> assign(sweep_regions_q: text, sweep_regions: ids)
     |> load_sweep()
     |> persist_filters()}
  end

  def handle_event("select_sweep_kind", %{"kind" => kind}, socket) when kind in @kinds do
    {:noreply,
     socket
     |> assign(sweep_kind: String.to_existing_atom(kind))
     |> load_sweep()
     |> maybe_load_region_heat(force: true)
     |> persist_filters()}
  end

  def handle_event("select_sweep_kind", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_sweep_space", %{"type" => type}, socket) do
    case parse_security_key(type) do
      nil ->
        {:noreply, socket}

      key ->
        security = toggle_security(socket.assigns.sweep_security, key)

        {:noreply,
         socket |> assign(sweep_security: security) |> load_sweep() |> persist_filters()}
    end
  end

  def handle_event("reset_sweep_space", _params, socket) do
    {:noreply,
     socket |> assign(sweep_security: @security_keys) |> load_sweep() |> persist_filters()}
  end

  def handle_event("toggle_sweep_compress", _params, socket) do
    {:noreply,
     socket
     |> assign(sweep_compress: !socket.assigns.sweep_compress)
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
    case Integer.parse(to_string(id)) do
      {value, ""} ->
        {:noreply,
         socket
         |> assign(mode: :sweep, sweep_regions_q: to_string(value), sweep_regions: [value])
         |> load_sweep()
         |> persist_filters()}

      _ ->
        {:noreply, socket}
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

      case PlanWaypoints.push(stops, eve_id) do
        {:ok, pushed} ->
          name = character_name(socket.assigns.characters, eve_id)

          {:noreply,
           put_flash(
             socket,
             :info,
             push_message(length(pushed), length(stops), name) <> " (part #{index + 1})"
           )}

        {:error, :no_gate_stops} ->
          {:noreply,
           put_flash(socket, :error, "Part #{index + 1} has no gate-reachable stops to fly.")}

        {:error, :unknown_character} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Pick a character this instance tracks before setting part #{index + 1}'s route."
           )}
      end
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

      case PlanWaypoints.push(stops, character_eve_id) do
        {:ok, pushed} ->
          name = character_name(socket.assigns.characters, character_eve_id)

          {:noreply,
           put_flash(socket, :info, push_message(length(pushed), length(stops), name))}

        {:error, :no_gate_stops} ->
          {:noreply, put_flash(socket, :error, "This sweep has no gate-reachable stops to fly.")}

        {:error, :unknown_character} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Pick a character this instance tracks before setting a route."
           )}
      end
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

  @filter_store "scout_refresh_filters"

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
      "regions_q" => socket.assigns.regions_q,
      "security" => Enum.map(socket.assigns.security, &to_string/1),
      "mode" => to_string(socket.assigns.mode),
      "sweep_regions_q" => socket.assigns.sweep_regions_q,
      "sweep_kind" => to_string(socket.assigns.sweep_kind),
      "sweep_security" => Enum.map(socket.assigns.sweep_security, &to_string/1),
      "sweep_compress" => socket.assigns.sweep_compress,
      "sweep_start" => socket.assigns.sweep_start,
      "sweep_k" => socket.assigns.sweep_k
    }

    push_event(socket, "ls_update_#{@filter_store}", %{value: Jason.encode!(state)})
  end

  defp restore_filters(socket, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = saved} ->
        regions_q = restore_regions_q(saved)
        sweep_regions_q = restore_sweep_regions_q(saved)

        {:ok,
         assign(socket,
           origin_id: restore_origin_id(saved),
           origin_name: restore_origin_name(saved),
           kind: restore_kind(saved, socket.assigns.kind),
           limit: restore_limit(saved, socket.assigns.limit),
           max_jumps: restore_max_jumps(saved, socket.assigns.max_jumps),
           regions_q: regions_q,
           regions: parse_region_ids(regions_q),
           security: restore_security(saved),
           mode: restore_mode(saved, socket.assigns.mode),
           sweep_regions_q: sweep_regions_q,
           sweep_regions: sweep_regions_q |> parse_region_ids() |> Enum.take(@max_sweep_regions),
           sweep_kind: restore_sweep_kind(saved, socket.assigns.sweep_kind),
           sweep_security: restore_sweep_security(saved),
           sweep_compress: restore_sweep_compress(saved, socket.assigns.sweep_compress),
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

  defp restore_regions_q(%{"regions_q" => text}) when is_binary(text),
    do: String.slice(text, 0, 200)

  defp restore_regions_q(_saved), do: ""

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

  defp restore_sweep_regions_q(%{"sweep_regions_q" => text}) when is_binary(text),
    do: String.slice(text, 0, 100)

  defp restore_sweep_regions_q(_saved), do: ""

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

  defp restore_sweep_start(%{"sweep_start" => id}) when is_integer(id) and id > 0, do: id
  defp restore_sweep_start(_saved), do: nil

  defp restore_sweep_k(%{"sweep_k" => k}, default) when is_integer(k) do
    if k >= 1 and k <= @max_split_k, do: k, else: default
  end

  defp restore_sweep_k(_saved, default), do: default

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp character_name(characters, eve_id) do
    case Enum.find(characters, &(&1.eve_id == eve_id)) do
      nil -> "that character"
      character -> character.name
    end
  end

  defp push_message(pushed, pushed, name),
    do: "Route set on #{name}: #{pushed} #{plural(pushed, "waypoint", "waypoints")}."

  defp push_message(pushed, gate_count, name),
    do:
      "ESI accepted only #{pushed} of #{gate_count} stops -- #{name}'s route is the first part of this plan, not all of it."

  defp parse_region_ids(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn s ->
      case Integer.parse(s) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
  end

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
  # first time someone compares them. It costs a second Planner pass per
  # page load (the BFS adjacency index is cached, the per-candidate reads
  # are not); a page load is a human action a few times a minute, and the
  # alternative -- re-ordering `rank/1`'s stops here -- would be a second
  # implementation of the walk, drifting from the endpoint's.
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
  # Reads
  # -------------------------------------------------------------------

  defp load(socket) do
    socket = assign(socket, now: DateTime.utc_now())

    if socket.assigns.origin_id do
      opts = plan_opts(socket)

      case Planner.rank(opts) do
        {:ok, result} ->
          plan_stops = plan_stops(opts)

          assign(socket,
            result: result,
            stops: result.stops,
            candidates: result.candidates,
            generated_at: result.generated_at,
            plan_stops: plan_stops,
            route_ids: route_ids(plan_stops),
            plan_error: nil
          )

        {:error, reason} ->
          assign(socket,
            result: nil,
            stops: [],
            candidates: 0,
            generated_at: nil,
            plan_stops: [],
            route_ids: "",
            plan_error: reason
          )
      end
    else
      assign(socket,
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
      regions: socket.assigns.regions,
      security: socket.assigns.security
    ]
  end

  # The copy box and the "Set route" button both read this: whatever
  # `GET /scout/plan` would return for the same scope, so a human's
  # pasted list, the pushed route and the bot's own plan are the same
  # thing. A plan failure here is not a page failure -- the ranking table
  # above still rendered, and an empty box is the honest answer.
  defp plan_stops(opts) do
    case Planner.plan(opts) do
      {:ok, %{stops: stops}} -> stops
      {:error, _reason} -> []
    end
  end

  # -------------------------------------------------------------------
  # Sweep reads
  # -------------------------------------------------------------------

  defp load_sweep(socket) do
    socket = assign(socket, now: DateTime.utc_now())

    if socket.assigns.sweep_regions == [] do
      assign(socket, sweep_result: nil, sweep_error: nil, sweep_parts: [], sweep_pilots: %{})
    else
      case Sweep.sweep(sweep_opts(socket)) do
        {:ok, result} ->
          socket
          |> assign(sweep_result: result, sweep_error: nil)
          |> load_split()

        {:error, reason} ->
          assign(socket,
            sweep_result: nil,
            sweep_error: reason,
            sweep_parts: [],
            sweep_pilots: %{}
          )
      end
    end
  end

  # `exclude` is the hard-zero half of `scout_assignments_v1` (design doc
  # section 5, "the planner then treats assigned-to-someone-else exactly
  # as it treats avoided"): once "Assign all" claims a part's systems,
  # the NEXT sweep over the same scope must not re-offer them to a
  # different pilot, or two splits over the same region keep competing.
  defp sweep_opts(socket) do
    [
      scope: {:regions, socket.assigns.sweep_regions},
      kind: socket.assigns.sweep_kind,
      security: socket.assigns.sweep_security,
      start: socket.assigns.sweep_start,
      compress: socket.assigns.sweep_compress,
      exclude: socket.assigns.sweep_kind |> Assignments.active_system_ids() |> MapSet.to_list()
    ]
  end

  # k=1 is just the sweep above with nowhere to split; `Split.split/3`
  # only runs once a second pilot is actually in the picture.
  defp load_split(socket) do
    %{sweep_result: result, sweep_k: k} = socket.assigns

    cond do
      is_nil(result) or k <= 1 ->
        assign(socket, sweep_parts: [], sweep_pilots: %{})

      true ->
        system_ids = Enum.map(result.stops, & &1.solar_system_id)

        case Split.split(system_ids, k, []) do
          {:ok, parts} ->
            pilots =
              default_pilots(parts, socket.assigns.characters, socket.assigns.sweep_pilots)

            assign(socket, sweep_parts: parts, sweep_pilots: pilots)

          {:error, _reason} ->
            assign(socket, sweep_parts: [], sweep_pilots: %{})
        end
    end
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

  # Loaded once per kind, not on every keystroke: a region's heat
  # changes on a human timescale (coverage rows arriving), so recompute
  # only on entering sweep mode or changing `kind`, not on every scope
  # edit -- `force: true` is select_sweep_kind/3's escape hatch.
  defp maybe_load_region_heat(socket, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    %{mode: mode, sweep_kind: kind, region_heat: heat, region_heat_kind: heat_kind} =
      socket.assigns

    if mode == :sweep and (force or is_nil(heat) or heat_kind != kind) do
      rows = kind |> Sweep.region_heat() |> sort_region_heat()
      assign(socket, region_heat: rows, region_heat_kind: kind)
    else
      socket
    end
  end

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

  defp start_name(start_id, stops) do
    case Enum.find(stops, &(&1.solar_system_id == start_id)) do
      nil -> to_string(start_id)
      stop -> stop.name
    end
  end
end
