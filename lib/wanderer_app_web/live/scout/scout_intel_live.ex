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

    * **Structures** defaults to live reinforcement timers, sorted by the
      one that runs out first — the only part of this log that is
      time-critical. Below it, the most recent observation *per
      structure*, folded here rather than in SQL: the table is
      append-only and small enough that a window function would be
      premature.

    * **Spawns** is a flat reverse-chronological log. Faction spawns
      repeat in the same belts, so the history is the value.
  """

  use WandererAppWeb, :live_view

  alias WandererApp.Api.{ScoutSpawnSighting, ScoutStructureSighting}
  alias WandererApp.Identity.ScoutAccess

  @windows [{"24 hours", 1}, {"7 days", 7}, {"30 days", 30}, {"90 days", 90}]
  @default_days 7

  # A flat log read has to be bounded by something; the window is the
  # primary bound and this is the backstop for a busy window.
  @max_rows 500

  @impl true
  def mount(_params, _session, socket) do
    # WANDERER_SCOUT_INTEL is enforced by the scope's pipeline
    # (WandererAppWeb.Plugs.CheckScoutIntelDisabled -> 404), so the only
    # thing left to decide here is the permission. Uncached on purpose:
    # the nav icon may be drawn from a cached answer, reading the log may
    # not be.
    if ScoutAccess.can_view?(socket.assigns.current_user.id) do
      {:ok,
       socket
       |> assign(
         active_tab: :scout,
         page_title: "Scout Log",
         tab: :structures,
         days: @default_days,
         windows: @windows,
         can_manage_access?: ScoutAccess.superadmin?(socket.assigns.current_user.id)
       )
       |> load()}
    else
      {:ok, socket |> push_navigate(to: ~p"/maps")}
    end
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in ~w(spawns structures) do
    {:noreply, socket |> assign(tab: String.to_existing_atom(tab)) |> load()}
  end

  def handle_event("select_window", %{"days" => days}, socket) do
    case Integer.parse(days) do
      {days, ""} -> {:noreply, socket |> assign(days: days) |> load()}
      _ -> {:noreply, socket}
    end
  end

  defp load(socket) do
    since = DateTime.utc_now() |> DateTime.add(-socket.assigns.days, :day)

    socket
    |> assign(
      now: DateTime.utc_now(),
      spawns: spawns(socket.assigns.tab, since),
      active_timers: active_timers(socket.assigns.tab),
      structures: structures(socket.assigns.tab, since)
    )
  end

  # Only query the table the visible tab actually renders.
  defp spawns(:spawns, since) do
    case ScoutSpawnSighting.recent(since, authorize?: false) do
      {:ok, rows} -> Enum.take(rows, @max_rows)
      _ -> []
    end
  end

  defp spawns(_tab, _since), do: []

  defp active_timers(:structures) do
    case ScoutStructureSighting.active_timers(DateTime.utc_now(), authorize?: false) do
      {:ok, rows} -> Enum.take(rows, @max_rows)
      _ -> []
    end
  end

  defp active_timers(_tab), do: []

  defp structures(:structures, since) do
    case ScoutStructureSighting.recent(since, authorize?: false) do
      {:ok, rows} -> rows |> latest_per_structure() |> Enum.take(@max_rows)
      _ -> []
    end
  end

  defp structures(_tab, _since), do: []

  # `:recent` already sorts observed_at desc, so the first row seen for a
  # structure is its newest.
  defp latest_per_structure(rows) do
    rows
    |> Enum.reduce({[], MapSet.new()}, fn row, {kept, seen} ->
      if MapSet.member?(seen, row.structure_id) do
        {kept, seen}
      else
        {[row | kept], MapSet.put(seen, row.structure_id)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc false
  # "2d 4h", "3h 12m", "45s" -- a reinforcement timer is read at a glance
  # or not at all, so never more than two units.
  def countdown(nil, _now), do: "—"

  def countdown(expires_at, now) do
    case DateTime.diff(expires_at, now, :second) do
      seconds when seconds <= 0 -> "expired"
      seconds -> format_countdown(seconds)
    end
  end

  defp format_countdown(seconds) do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3600)
    minutes = seconds |> rem(3600) |> div(60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  @doc false
  def at(nil), do: "—"
  def at(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  @doc false
  def isk(nil), do: "—"

  def isk(value) do
    millions = value |> Decimal.div(1_000_000) |> Decimal.round(1) |> Decimal.to_float()
    "#{millions}M"
  end

  @doc false
  # The client logs the raw system ID as the name when it has not
  # resolved the real one yet; either way there is exactly one sensible
  # thing to print.
  def system(%{solar_system_name: nil, solar_system_id: id}), do: to_string(id)
  def system(%{solar_system_name: name}), do: name
end
