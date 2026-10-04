defmodule WandererAppWeb.ScoutIntelLive do
  @moduledoc """
  The scout log: special NPC spawns and structure timers reported by
  eveknob clients through `WandererAppWeb.ScoutIntelAPIController`.

  Gated on `WANDERER_SCOUT_INTEL` and on
  `WandererApp.Identity.ScoutAccess.can_view?/1` — the `:scout_intel_view`
  permission, which only the bootstrap admin can grant
  (`WandererAppWeb.ScoutAccessLive`). A corp admin without the grant is
  redirected like anyone else.

  Two views over the same data, because they answer different questions:

    * **Structures** leads with live reinforcement timers, soonest first
      — the only part of this log that is time-critical. Below it, the
      most recent observation *per structure*, folded by Postgres
      (`DISTINCT ON`), and below that a per-structure history on demand:
      the table is append-only precisely so that two rows an hour apart
      mean something.

    * **Spawns** leads with a fresh list — the latest sighting per
      system + location + spawn seen within the last few hours,
      ticking and ageing out exactly like the structure timers below,
      because a faction spawn reported recently is probably still
      sitting in that belt. Below it, the hotspot aggregate (`GROUP BY`
      system + location + spawn) over the flat reverse-chronological
      log, and below that a per-spawn history on demand, keyed on
      system + location + spawn name rather than an id — there is no
      spawn id, the belt and the name ARE the identity, which is
      exactly the `:uniq_sighting` identity the resource upserts on.

  Four things this page does that a plain table does not:

    * **It ticks.** `now` is re-assigned every 30s and expired timers
      drop out of the live table, without a query. A countdown frozen at
      page-open is worse than no countdown.

    * **It is pushed to.** `WandererApp.Scout.Ingest` broadcasts on
      `"scout_intel"`, so a structure reinforced while the page is open
      appears without a reload.

    * **It never silently truncates.** Reads ask for one row more than
      they show; the extra row is the "more rows" banner, which is
      cheaper than a `count(*)` over the window and just as honest.

    * **It resolves system names itself.** The client logs the raw
      system ID whenever it has not cached the name yet, so half the
      rows would otherwise read "30002386".
  """

  use WandererAppWeb, :live_view

  require Ash.Query

  # The page's whole vocabulary -- `panel/1`, `stat/1`, the cells, and
  # the formatters they render with. The template calls them unqualified.
  import WandererAppWeb.ScoutComponents

  alias WandererApp.Api.{
    ScoutSpawnSighting,
    ScoutStructure,
    ScoutStructureEvent
  }

  alias WandererApp.CachedInfo
  alias WandererApp.Identity.ScoutAccess
  alias WandererApp.Scout.Alerts
  alias WandererApp.Scout.Space
  alias WandererApp.Scout.Stats

  @windows [{"24 hours", 1}, {"7 days", 7}, {"30 days", 30}, {"90 days", 90}]
  @default_days 7

  # One page of a flat log. The window is the primary bound; this is what
  # keeps a busy window off the heap, and "Load more" raises it.
  @page 250

  # Enough rows to see a structure's whole reinforcement cycle, which is
  # all the drill-down is for.
  @history_rows 200

  # Countdowns are read in minutes, so a 30s tick is already generous;
  # it costs no query.
  @tick :timer.seconds(30)

  # A faction spawn seen within the last three hours is probably still
  # sitting in that belt; older than that is history, which is what the
  # window-bounded log below the fresh list is for.
  @fresh_seconds 3 * 3_600

  @impl true
  def mount(_params, _session, socket) do
    # WANDERER_SCOUT_INTEL is enforced by the scope's pipeline
    # (WandererAppWeb.Plugs.CheckScoutIntelDisabled -> 404), so the only
    # thing left to decide here is the permission. Uncached on purpose:
    # the nav icon may be drawn from a cached answer, reading the log may
    # not be.
    if ScoutAccess.can_view?(socket.assigns.current_user.id) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(WandererApp.PubSub, "scout_intel")
        Process.send_after(self(), :tick, @tick)
      end

      {:ok,
       socket
       |> assign(
         active_tab: :scout,
         page_title: "Scout Log",
         tab: :structures,
         days: @default_days,
         windows: @windows,
         q: "",
         system_id: nil,
         space: Space.all(),
         space_types: Space.types(),
         limit: @page,
         detail: nil,
         spawn_detail: nil,
         systems: %{},
         can_manage_access?: ScoutAccess.superadmin?(socket.assigns.current_user.id)
       )
       |> load()}
    else
      {:ok, socket |> push_navigate(to: ~p"/maps")}
    end
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in ~w(spawns structures) do
    {:noreply,
     socket
     |> assign(tab: String.to_existing_atom(tab), limit: @page, detail: nil, spawn_detail: nil)
     |> load()
     |> persist_filters()}
  end

  def handle_event("select_window", %{"days" => days}, socket) do
    case Integer.parse(days) do
      {days, ""} ->
        {:noreply, socket |> assign(days: days, limit: @page) |> load() |> persist_filters()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: q, limit: @page) |> load() |> persist_filters()}
  end

  # Clicking a system is the filter nobody has to discover; the chip in
  # the toolbar is how it is undone.
  def handle_event("filter_system", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {system_id, ""} ->
        {:noreply,
         socket |> assign(system_id: system_id, limit: @page) |> load() |> persist_filters()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_system", _params, socket) do
    {:noreply, socket |> assign(system_id: nil, limit: @page) |> load() |> persist_filters()}
  end

  # The filter this page exists for: "everything except highsec" is one
  # click. Applies to every table, including the two that ignore the
  # window selector (live timers, still-out-there) — a reader who turned
  # highsec off meant it for those too.
  def handle_event("toggle_space", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(space: Space.toggle(socket.assigns.space, type), limit: @page)
     |> load()
     |> persist_filters()}
  end

  def handle_event("reset_space", _params, socket) do
    {:noreply, socket |> assign(space: Space.all(), limit: @page) |> load() |> persist_filters()}
  end

  # The browser hands back the filters this page was last left with --
  # `LocalStorageSetting` (assets/js/hooks/localStorageSetting.ts) pushes
  # this once on mount, with `nil` on a first visit. A scout who turned
  # highsec off and picked a 24-hour window meant it for the next visit
  # too, and re-picking four controls on every page load was the single
  # most grating thing about this page.
  def handle_event("ls_restore_scout_filters", %{"value" => value}, socket) do
    case restore_filters(socket, value) do
      {:ok, socket} -> {:noreply, load(socket)}
      :unchanged -> {:noreply, socket}
    end
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> assign(limit: socket.assigns.limit + @page) |> load()}
  end

  # The drill-down is the DERIVED event log, not the raw sighting tape.
  # `scout_structure_events_v1` holds one row per thing that actually
  # happened to this structure -- appeared, changed, cleared, missing,
  # gone -- so a hull that sat in armour reinforcement for 36 hours is
  # two lines here instead of several hundred identical ones. The header
  # reads current state (`ScoutStructure`) because an event row carries
  # only what moved, never the whole structure.
  def handle_event("show_structure", %{"id" => id}, socket) do
    with {structure_id, ""} <- Integer.parse(to_string(id)),
         {:ok, rows} <- ScoutStructureEvent.history(structure_id, authorize?: false) do
      rows = Enum.take(rows, @history_rows)
      structure = current_structure(structure_id)

      {:noreply,
       socket
       |> assign(detail: %{structure_id: structure_id, structure: structure, rows: rows})
       |> assign_systems([rows])}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_structure", _params, socket),
    do: {:noreply, assign(socket, detail: nil)}

  def handle_event(
        "show_spawn",
        %{"system" => sid, "location" => location, "spawn" => spawn},
        socket
      ) do
    with {system_id, ""} <- Integer.parse(to_string(sid)),
         {:ok, rows} <- ScoutSpawnSighting.history(system_id, location, spawn, authorize?: false) do
      rows = Enum.take(rows, @history_rows)

      {:noreply,
       socket
       |> assign(
         spawn_detail: %{
           solar_system_id: system_id,
           location_name: location,
           spawn_name: spawn,
           rows: rows
         }
       )
       |> assign_systems([rows])}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_spawn", _params, socket),
    do: {:noreply, assign(socket, spawn_detail: nil)}

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  # No query: advance the clock and drop the timers that ran out while
  # the page sat open. New rows arrive by broadcast, not by polling.
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    now = DateTime.utc_now()

    {:noreply,
     assign(socket,
       now: now,
       active_timers: Enum.filter(socket.assigns.active_timers, &running?(&1, now)),
       fresh_spawns: Enum.filter(socket.assigns.fresh_spawns, &fresh?(&1, now))
     )}
  end

  def handle_info({:scout_intel_ingested, kind}, socket) do
    if kind == socket.assigns.tab do
      {:noreply, load(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Sticky filters
  #
  # The four controls in the toolbar survive a reload, a new tab and a
  # restart, in the browser rather than on the server: a per-user server
  # cache would be lost on every deploy, which on this fork is often.
  # `LocalStorageSetting` is the upstream hook for exactly this -- it
  # pushes `ls_restore_<key>` once on mount and listens for
  # `ls_update_<key>` -- so this costs no JavaScript.
  #
  # `limit` is deliberately NOT persisted: "Load more" is about the page
  # you are on, not about how you like to read the log.
  # -------------------------------------------------------------------

  @filter_store "scout_filters"

  defp persist_filters(socket) do
    state = %{
      "tab" => to_string(socket.assigns.tab),
      "days" => socket.assigns.days,
      "q" => socket.assigns.q,
      "system_id" => socket.assigns.system_id,
      "space" => Enum.map(socket.assigns.space, &to_string/1)
    }

    push_event(socket, "ls_update_#{@filter_store}", %{value: Jason.encode!(state)})
  end

  # Every field is validated the same way the event handlers validate a
  # click: localStorage is user-writable, and an unknown window or a
  # `tab` that is not an existing atom must cost the default, not a
  # crash on mount.
  defp restore_filters(socket, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = saved} ->
        {:ok,
         assign(socket,
           tab: restore_tab(saved, socket.assigns.tab),
           days: restore_days(saved, socket.assigns.days),
           q: restore_q(saved),
           system_id: restore_system_id(saved),
           space: restore_space(saved),
           limit: @page
         )}

      _ ->
        :unchanged
    end
  end

  defp restore_filters(_socket, _value), do: :unchanged

  defp restore_tab(%{"tab" => tab}, _default) when tab in ~w(structures spawns),
    do: String.to_existing_atom(tab)

  defp restore_tab(_saved, default), do: default

  defp restore_days(%{"days" => days}, default) when is_integer(days) do
    if List.keymember?(@windows, days, 1), do: days, else: default
  end

  defp restore_days(_saved, default), do: default

  defp restore_q(%{"q" => q}) when is_binary(q), do: String.slice(q, 0, 200)
  defp restore_q(_saved), do: ""

  defp restore_system_id(%{"system_id" => id}) when is_integer(id) and id > 0, do: id
  defp restore_system_id(_saved), do: nil

  # An empty selection is a state a reader can actually save (every chip
  # unticked), so it is restored as-is -- but a non-empty saved list that
  # parses to nothing is corrupt storage, and the whole page coming back
  # blank is the worst possible answer to that.
  defp restore_space(%{"space" => saved}) when is_list(saved) do
    case Space.parse(saved) do
      [] -> if saved == [], do: [], else: Space.all()
      keys -> keys
    end
  end

  defp restore_space(_saved), do: Space.all()

  # -------------------------------------------------------------------
  # Reads
  # -------------------------------------------------------------------

  defp load(socket) do
    %{tab: tab, days: days, limit: limit} = socket.assigns

    now = DateTime.utc_now()
    since = DateTime.add(now, -days, :day)

    filters = %{
      system_id: socket.assigns.system_id,
      q: search_term(socket.assigns.q),
      space: socket.assigns.space
    }

    socket
    |> assign(now: now, since: since)
    |> load_unanchored(filters)
    |> load_tab(tab, since, now, filters, limit)
    |> assign_freshness()
  end

  # The alert, read on BOTH tabs: a structure sitting unanchored is the
  # highest-value thing this log ever reports, and a reader who happens
  # to be on the spawns tab must still see it. Its own horizon (7 days,
  # `Alerts.horizon_days/0`) rather than the window selector, and no
  # text search -- see `WandererApp.Scout.Alerts`.
  defp load_unanchored(socket, filters) do
    rows =
      Alerts.unanchored(system_id: filters.system_id, space: filters.space) |> by_recent()

    socket
    |> assign(unanchored_structures: rows)
    |> assign_systems([rows])
  end

  defp load_tab(socket, :structures, since, now, filters, limit) do
    # ONE ROW PER STRUCTURE, by construction. These boards read
    # `ScoutStructure` -- current state, `structure_id` is the identity --
    # so there is no fold at the call site any more, and that is a
    # correctness fix rather than a tidy-up.
    #
    # The old shape applied `Ash.Query.distinct([:structure_id])` AFTER
    # the status filter. DISTINCT ON then picked the newest row THAT
    # STILL MATCHED THE FILTER, not the newest row about that structure:
    # an Unanchoring sighting from Tuesday kept boarding even when a
    # FullPower sighting from Thursday existed, because the fresher row
    # was filtered out before the fold ever saw it. A table that stores
    # one row per structure cannot express that bug.
    #
    # Absence is handled by the same table: every board below additionally
    # filters `presence == :seen` inside its own action, so a structure
    # that was refuelled (`:cleared`), stopped showing up
    # (`:missing`) or is confirmed gone (`:gone`) leaves the opportunity
    # lists without anyone editing a row.
    # docs/design/wanderer-scout-presence.md
    {timers, _more} =
      read(ScoutStructure, :active_timers, Map.put(filters, :now, now), limit)

    {structures, more_structures?} =
      read(ScoutStructure, :search, Map.put(filters, :since, since), limit)

    # The cheapest kills in the game: no fitting, no services, a live
    # vulnerability window. `:anchoring` mirrors `:search`'s filters,
    # scoped server-side to the ANCHORING status family.
    {anchoring_structures, _more} =
      read(ScoutStructure, :anchoring, Map.put(filters, :since, since), limit)

    # Nothing to shoot and nothing to wait for: asset safety off, or
    # simply unfuelled. `:abandoned` mirrors `:search`'s filters, scoped
    # server-side to WandererApp.Scout.Status.dead_family/0.
    {abandoned_structures, _more} =
      read(ScoutStructure, :abandoned, Map.put(filters, :since, since), limit)

    # Being pulled out of the ground: a one-shot opportunity with a
    # hard deadline. `:unanchoring` mirrors `:search`'s filters, scoped
    # server-side to `status == "Unanchoring"`.
    {unanchoring_structures, _more} =
      read(ScoutStructure, :unanchoring, Map.put(filters, :since, since), limit)

    # Every board is sorted here rather than trusted to come out of the
    # read in storage order. Each table gets the sort its question
    # implies -- deadline first where there is a deadline, most recently
    # confirmed first everywhere else.
    socket
    |> assign(
      active_timers: timers |> Enum.filter(&running?(&1, now)) |> by_deadline(),
      structures: by_recent(structures),
      anchoring_structures: by_recent(anchoring_structures),
      abandoned_structures: by_recent(abandoned_structures),
      unanchoring_structures: by_deadline(unanchoring_structures),
      more?: more_structures?,
      spawns: [],
      hotspots: [],
      fresh_spawns: []
    )
    |> assign_systems([
      timers,
      structures,
      anchoring_structures,
      abandoned_structures,
      unanchoring_structures
    ])
  end

  defp load_tab(socket, :spawns, since, now, filters, limit) do
    {spawns, more?} =
      read(ScoutSpawnSighting, :search, Map.put(filters, :since, since), limit)

    hotspots =
      Stats.spawn_hotspots(since,
        system_id: filters.system_id,
        q: filters.q,
        space: filters.space
      )

    {fresh_spawns, _more} =
      read(
        ScoutSpawnSighting,
        :search,
        Map.put(filters, :since, DateTime.add(now, -@fresh_seconds, :second)),
        limit,
        fn query ->
          # DISTINCT ON (solar_system_id, location_name, spawn_name)
          # ORDER BY observed_at DESC: the latest row per spawn, folded
          # by Postgres instead of by loading the window and folding it
          # here -- same trick as the structures tab's fold.
          query
          |> Ash.Query.distinct([:solar_system_id, :location_name, :spawn_name])
          |> Ash.Query.distinct_sort(observed_at: :desc)
        end
      )

    fresh_spawns = fresh_spawns |> Enum.filter(&fresh?(&1, now)) |> by_recent()

    socket
    |> assign(
      spawns: by_recent(spawns),
      hotspots: hotspots,
      more?: more?,
      active_timers: [],
      structures: [],
      anchoring_structures: [],
      abandoned_structures: [],
      unanchoring_structures: [],
      fresh_spawns: fresh_spawns
    )
    |> assign_systems([spawns, hotspots, fresh_spawns])
  end

  # Asks for one row past the page so the UI can say "there are more"
  # without a second count query over the same window. `:space` is not
  # an argument of either read action -- it is a subquery against the
  # static map, applied to the query rather than carried by the action,
  # so the two resources and the CSV export share one implementation.
  defp read(resource, action, args, limit, shape \\ & &1) do
    {space, args} = Map.pop!(args, :space)

    query =
      resource
      |> Ash.Query.for_read(action, args)
      |> Space.filter(space)
      |> shape.()
      |> Ash.Query.limit(limit + 1)

    case Ash.read(query, authorize?: false) do
      {:ok, rows} -> {Enum.take(rows, limit), length(rows) > limit}
      {:error, _reason} -> {[], false}
    end
  end

  # Only asked for when a table came back empty, so that "nothing in this
  # window" and "nothing has ever been reported" can be told apart.
  defp assign_freshness(socket) do
    empty? =
      case socket.assigns.tab do
        :structures -> socket.assigns.structures == [] and socket.assigns.active_timers == []
        :spawns -> socket.assigns.spawns == []
      end

    assign(socket,
      last_observed: Stats.last_observed_at(),
      totals: if(empty?, do: Stats.totals(), else: nil)
    )
  end

  # The client logs the raw system ID until it has resolved a name, so
  # resolve it here instead — Cachex-backed, and shared with the rest of
  # the app.
  defp assign_systems(socket, row_lists) do
    known = socket.assigns.systems

    resolved =
      row_lists
      |> Enum.concat()
      |> Enum.map(& &1.solar_system_id)
      |> Enum.uniq()
      |> Enum.reject(&(is_nil(&1) or Map.has_key?(known, &1)))
      |> Map.new(&{&1, CachedInfo.get_system_static_info!(&1)})

    assign(socket, systems: Map.merge(known, resolved))
  end

  defp search_term(q) do
    case String.trim(to_string(q)) do
      "" -> nil
      term -> term
    end
  end

  defp running?(%{timer_expires_at: nil}, _now), do: false

  defp running?(%{timer_expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  # observed_at is allow_nil?: false on scout_spawn_sighting, so a
  # single clause covers every row that can actually reach here.
  defp fresh?(%{observed_at: at}, now), do: DateTime.diff(now, at, :second) < @fresh_seconds

  # -------------------------------------------------------------------
  # Sorting
  #
  # Applied in the BEAM, over a page of rows the socket already holds,
  # and never left to the query: every structure board runs through a
  # DISTINCT ON whose ORDER BY exists to choose the surviving row per
  # structure, not to order the result. Two orders, because the page
  # only ever asks two questions.
  # -------------------------------------------------------------------

  # Current state for the drill-down header. An event row carries only
  # what moved, so the name, position and presence have to come from the
  # structure itself.
  defp current_structure(structure_id) do
    case ScoutStructure.by_structure_id(structure_id, authorize?: false) do
      {:ok, row} -> row
      _ -> nil
    end
  end

  # Newest first: every board whose rows have no deadline. Spawn rows
  # carry `observed_at` (when it happened); structure current-state rows
  # carry `last_confirmed_at` (when we last proved it was still there).
  # Same question, different column, one sort.
  defp by_recent(rows), do: Enum.sort_by(rows, &recency/1, {:desc, DateTime})

  defp recency(row), do: Map.get(row, :observed_at) || Map.get(row, :last_confirmed_at)

  # Soonest deadline first, rows without one last and newest-first among
  # themselves -- a board sorted by deadline is read top-down until the
  # reader runs out of time to care.
  defp by_deadline(rows) do
    Enum.sort_by(rows, fn row ->
      case row.timer_expires_at do
        nil -> {1, 0}
        expires_at -> {0, DateTime.to_unix(expires_at)}
      end
    end)
  end

  # -------------------------------------------------------------------
  # Summary strip
  #
  # Counted from the rows the page already holds, never re-queried: the
  # strip answers "is anything happening right now" before the reader
  # starts scanning tables, and a count worth a second query would not
  # be worth that. Everything else that used to live below here --
  # countdowns, badges, system names -- moved to
  # `WandererAppWeb.ScoutComponents`, with the cells that render it.
  # -------------------------------------------------------------------

  @doc false
  # The alert's own horizon, so the banner's copy and the read that
  # fills it can never disagree.
  def unanchored_horizon_days, do: Alerts.horizon_days()

  @doc false
  # Under an hour is a fleet forming now -- the one number on this page
  # worth colouring a card for.
  def urgent_timers(timers, now) do
    Enum.count(timers, fn row ->
      case row.timer_expires_at do
        nil -> false
        expires_at -> DateTime.diff(expires_at, now, :second) in 1..3_599
      end
    end)
  end

  @doc false
  def timer_hint([], _now), do: "nothing running"

  def timer_hint(timers, now) do
    case urgent_timers(timers, now) do
      0 -> "none inside the hour"
      count -> "#{count} inside the hour"
    end
  end

  @doc false
  # "250+" when the read came back full: the strip never claims the
  # window held exactly one page of rows.
  def count_label(rows, true), do: "#{length(rows)}+"
  def count_label(rows, _more?), do: to_string(length(rows))

  @doc false
  # The window as the selector spells it, so the cards and the toolbar
  # never disagree about what "in the window" means.
  def window_label(days, windows) do
    case List.keyfind(windows, days, 1) do
      {label, _days} -> label
      nil -> "#{days} days"
    end
  end

  @doc false
  # The richest sighting in the window. `nil` renders as "—" through
  # `isk/1`, which is also what an empty window gives.
  def richest([]), do: nil

  def richest(spawns) do
    spawns
    |> Enum.map(& &1.isk_value)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> Enum.max_by(values, &Decimal.to_float/1)
    end
  end

  @doc false
  def export_path(assigns) do
    params =
      %{
        "tab" => to_string(assigns.tab),
        "days" => to_string(assigns.days)
      }
      |> maybe_put("q", search_term(assigns.q))
      |> maybe_put("system_id", assigns.system_id && to_string(assigns.system_id))
      |> maybe_put("space", Space.to_param(assigns.space))

    "/scout/export.csv?" <> URI.encode_query(params)
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
