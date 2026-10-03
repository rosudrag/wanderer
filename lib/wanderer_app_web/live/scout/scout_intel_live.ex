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

    * **Spawns** leads with hotspots (`GROUP BY` system + location +
      spawn) over the flat reverse-chronological log. Faction spawns
      repeat in the same belts, so the aggregate is the intel and the
      log is the evidence.

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

  alias WandererApp.Api.{ScoutSpawnSighting, ScoutStructureSighting}
  alias WandererApp.CachedInfo
  alias WandererApp.Identity.ScoutAccess
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
         limit: @page,
         detail: nil,
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
     |> assign(tab: String.to_existing_atom(tab), limit: @page, detail: nil)
     |> load()}
  end

  def handle_event("select_window", %{"days" => days}, socket) do
    case Integer.parse(days) do
      {days, ""} -> {:noreply, socket |> assign(days: days, limit: @page) |> load()}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: q, limit: @page) |> load()}
  end

  # Clicking a system is the filter nobody has to discover; the chip in
  # the toolbar is how it is undone.
  def handle_event("filter_system", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {system_id, ""} -> {:noreply, socket |> assign(system_id: system_id, limit: @page) |> load()}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_system", _params, socket) do
    {:noreply, socket |> assign(system_id: nil, limit: @page) |> load()}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> assign(limit: socket.assigns.limit + @page) |> load()}
  end

  def handle_event("show_structure", %{"id" => id}, socket) do
    with {structure_id, ""} <- Integer.parse(to_string(id)),
         {:ok, rows} <- ScoutStructureSighting.history(structure_id, authorize?: false) do
      rows = Enum.take(rows, @history_rows)

      {:noreply,
       socket
       |> assign(detail: %{structure_id: structure_id, rows: rows})
       |> assign_systems([rows])}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_structure", _params, socket), do: {:noreply, assign(socket, detail: nil)}

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
       active_timers: Enum.filter(socket.assigns.active_timers, &running?(&1, now))
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
  # Reads
  # -------------------------------------------------------------------

  defp load(socket) do
    %{tab: tab, days: days, limit: limit} = socket.assigns

    now = DateTime.utc_now()
    since = DateTime.add(now, -days, :day)
    filters = %{system_id: socket.assigns.system_id, q: search_term(socket.assigns.q)}

    socket
    |> assign(now: now, since: since)
    |> load_tab(tab, since, now, filters, limit)
    |> assign_freshness()
  end

  defp load_tab(socket, :structures, since, now, filters, limit) do
    {timers, _more} =
      read(ScoutStructureSighting, :active_timers, Map.put(filters, :now, now), limit)

    {structures, more_structures?} =
      read(ScoutStructureSighting, :search, Map.put(filters, :since, since), limit, fn query ->
        # DISTINCT ON (structure_id) ORDER BY observed_at DESC: the
        # latest row per structure, folded by Postgres rather than by
        # loading the window and folding it here.
        query
        |> Ash.Query.distinct([:structure_id])
        |> Ash.Query.distinct_sort(observed_at: :desc)
      end)

    socket
    |> assign(
      active_timers: Enum.filter(timers, &running?(&1, now)),
      structures: structures,
      more?: more_structures?,
      spawns: [],
      hotspots: []
    )
    |> assign_systems([timers, structures])
  end

  defp load_tab(socket, :spawns, since, _now, filters, limit) do
    {spawns, more?} =
      read(ScoutSpawnSighting, :search, Map.put(filters, :since, since), limit)

    hotspots =
      Stats.spawn_hotspots(since, system_id: filters.system_id, q: filters.q)

    socket
    |> assign(
      spawns: spawns,
      hotspots: hotspots,
      more?: more?,
      active_timers: [],
      structures: []
    )
    |> assign_systems([spawns, hotspots])
  end

  # Asks for one row past the page so the UI can say "there are more"
  # without a second count query over the same window.
  defp read(resource, action, args, limit, shape \\ & &1) do
    query =
      resource
      |> Ash.Query.for_read(action, args)
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

  # -------------------------------------------------------------------
  # Rendering helpers
  # -------------------------------------------------------------------

  @doc false
  # "2d 4h", "3h 12m", "45s" -- a reinforcement timer is read at a glance
  # or not at all, so never more than two units.
  def countdown(nil, _now), do: "—"

  def countdown(expires_at, now) do
    case DateTime.diff(expires_at, now, :second) do
      seconds when seconds <= 0 -> "out"
      seconds -> format_countdown(seconds)
    end
  end

  defp format_countdown(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "#{seconds}s"
    end
  end

  @doc false
  # Urgency is the whole point of the timer table: under an hour is a
  # fleet forming now, under six is one forming today.
  def urgency(nil, _now), do: "text-gray-500"

  def urgency(expires_at, now) do
    case DateTime.diff(expires_at, now, :second) do
      seconds when seconds <= 0 -> "text-gray-500 line-through"
      seconds when seconds < 3_600 -> "text-error font-semibold"
      seconds when seconds < 21_600 -> "text-warning"
      _ -> "text-gray-200"
    end
  end

  @doc false
  def at(nil), do: "—"
  def at(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  @doc false
  # "4m ago" answers "is the bot alive"; an absolute timestamp does not.
  def ago(nil, _now), do: "never"

  def ago(datetime, now) do
    case DateTime.diff(now, datetime, :second) do
      seconds when seconds < 60 -> "just now"
      seconds -> format_countdown(seconds) <> " ago"
    end
  end

  @doc false
  # Millions, because every value in this log is one: "412.5M".
  def isk(nil), do: "—"

  def isk(value) do
    millions = value |> Decimal.div(1_000_000) |> Decimal.round(1) |> Decimal.to_float()
    "#{millions}M"
  end

  @doc false
  # The client logs the raw system ID as the name when it has not
  # resolved the real one yet; `systems` is this page's own resolution,
  # and the stored string is the fallback.
  def system(row, systems) do
    case Map.get(systems, row.solar_system_id) do
      %{solar_system_name: name} when is_binary(name) and name != "" -> name
      _ -> row.solar_system_name || to_string(row.solar_system_id)
    end
  end

  @doc false
  def system_class(row, systems) do
    case Map.get(systems, row.solar_system_id) do
      %{class_title: title} when is_binary(title) and title != "" -> title
      _ -> nil
    end
  end

  @doc false
  # Truesec as EVE shows it: two decimals, rounded toward zero so a
  # 0.049 system reads 0.0 rather than 0.1.
  def security(nil), do: nil
  def security(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  def security(_), do: nil

  @doc false
  def export_path(assigns) do
    params =
      %{
        "tab" => to_string(assigns.tab),
        "days" => to_string(assigns.days)
      }
      |> maybe_put("q", search_term(assigns.q))
      |> maybe_put("system_id", assigns.system_id && to_string(assigns.system_id))

    "/scout/export.csv?" <> URI.encode_query(params)
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
