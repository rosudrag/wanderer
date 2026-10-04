defmodule WandererAppWeb.ScoutComponents do
  @moduledoc """
  CHEWY PATCH: the presentation layer of `/scout`.

  Every table on the scout log renders the same five things — a time, a
  system, a named subject, a status, a countdown — and before this module
  each of them was spelled out inline in `scout_intel_live.html.heex`,
  nine times over. That is why the page drifted: the "Last seen" table
  showed a truesec the "Live timers" table did not, two of the four
  structure tables showed the nearest celestial and two did not, and an
  empty table was a bare `<td>` in one place and a sentence in another.

  So the vocabulary lives here, once:

    * `panel/1` — the section container. A title, a row count, and an
      optional one-line hint, over a bordered body. Sections used to be
      a bare `<h2>` followed by a paragraph of prose followed by a
      full-bleed table, which is what made the page read as a wall.

    * `stat/1` — one number from the current filter, for the strip under
      the toolbar. The page answers "is anything happening right now"
      before it answers "what exactly"; counting the rows it already
      holds costs no query.

    * `sys/1`, `subject/1`, `status/1`, `countdown_cell/1`, `seen/1`,
      `empty/1` — the cells.

  The formatting helpers the template calls (`countdown/2`, `ago/2`,
  `isk/1`, …) live here too, with the components that use them, rather
  than in the LiveView: they are rendering, and the LiveView is reads.
  """

  use Phoenix.Component

  alias WandererApp.Scout.Status

  # A faction spawn seen within this long is probably still sitting in
  # that belt. Mirrored by `ScoutIntelLive`'s read, which is what makes
  # the fresh list a *list*; this copy is the one the copy renders from.
  @fresh_seconds 3 * 3_600

  # ---------------------------------------------------------------------
  # Containers
  # ---------------------------------------------------------------------

  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  # A string, not an integer, so a capped read can say "250+" here the
  # same way the summary card does.
  attr :count, :any, default: nil
  attr :tone, :atom, default: :neutral, values: [:neutral, :urgent, :warn, :good]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  @doc """
  A titled section. `count` renders as a chip beside the title — the
  number a reader wants before deciding whether to read the table, and
  the one thing a collapsed `<h2>` could never carry.
  """
  def panel(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "mb-5 rounded-lg border border-neutral-800 bg-neutral-900/30 overflow-hidden",
        @class
      ]}
    >
      <header class="flex items-center gap-2 px-3 py-2 border-b border-neutral-800 bg-neutral-900/50">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-gray-300 whitespace-nowrap">
          {@title}
        </h2>
        <span :if={@count} class={["badge badge-sm font-mono border-0", count_class(@tone)]}>
          {@count}
        </span>
        <span :if={@hint} class="text-xs text-gray-500 truncate hidden md:inline">{@hint}</span>
      </header>
      <div class="overflow-x-auto">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp count_class(:urgent), do: "bg-error/20 text-error"
  defp count_class(:warn), do: "bg-warning/20 text-warning"
  defp count_class(:good), do: "bg-success/20 text-success"
  defp count_class(_), do: "bg-neutral-800 text-gray-400"

  attr :rows, :list, required: true
  attr :systems, :map, required: true
  attr :now, :any, required: true
  attr :horizon_days, :integer, required: true

  @doc """
  The unanchored alert: a red bar above everything else, on both tabs.

  Renders nothing when there is nothing to report — this is the one
  element on the page allowed to shout, and it only earns that by being
  absent the rest of the time. Each system is a chip that filters the
  whole page, so "where" is one click rather than a scroll.
  """
  def unanchored_alert(assigns) do
    ~H"""
    <div
      :if={@rows != []}
      id="scout-unanchored-alert"
      class="mb-4 rounded-lg border border-error bg-error/15 px-3 py-2.5 flex flex-wrap items-center gap-x-3 gap-y-2"
      role="alert"
    >
      <span class="relative flex h-3 w-3 shrink-0">
        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-error opacity-75">
        </span>
        <span class="relative inline-flex rounded-full h-3 w-3 bg-error"></span>
      </span>

      <span class="font-semibold text-error uppercase tracking-wide text-sm">
        {plural(length(@rows), "structure", "structures")} unanchored
      </span>

      <span class="text-xs text-gray-300">
        Floating undeployed: no fitting, no services, no timer to wait out.
      </span>

      <div class="flex flex-wrap items-center gap-1.5 ml-auto">
        <button
          :for={row <- Enum.take(@rows, 6)}
          phx-click="filter_system"
          phx-value-id={row.solar_system_id}
          class="badge badge-sm border border-error/50 bg-error/10 text-gray-100 hover:bg-error/25 gap-1"
          title={"#{row.structure_name || row.structure_id} — seen #{ago(row.observed_at, @now)}"}
        >
          {system(row, @systems)}
          <span class="text-error/80 font-mono">{ago(row.observed_at, @now)}</span>
        </button>
        <span :if={length(@rows) > 6} class="text-xs text-gray-400">
          +{length(@rows) - 6} more
        </span>
      </div>

      <span class="text-[11px] text-gray-500 w-full">
        Reported within the last {@horizon_days} days — this bar ignores the window selector and
        the search box, and narrows only with the system and space filters.
      </span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil
  attr :tone, :atom, default: :neutral, values: [:neutral, :urgent, :warn, :good]
  attr :id, :string, default: nil

  @doc "One number in the strip under the toolbar."
  def stat(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-lg border px-3 py-2 bg-neutral-900/30",
        @tone == :neutral && "border-neutral-800",
        @tone == :urgent && "border-error/40 bg-error/5",
        @tone == :warn && "border-warning/40 bg-warning/5",
        @tone == :good && "border-success/40 bg-success/5"
      ]}
    >
      <div class="text-[10px] uppercase tracking-wider text-gray-500 truncate">{@label}</div>
      <div class={[
        "text-xl font-semibold tabular-nums leading-tight",
        @tone == :urgent && "text-error",
        @tone == :warn && "text-warning",
        @tone == :good && "text-success"
      ]}>
        {@value}
      </div>
      <div class="text-[11px] text-gray-500 truncate h-4">{@hint}</div>
    </div>
    """
  end

  @doc """
  The table every section uses: compact, hover-highlighted, with the
  header row reading as a label rather than as data.
  """
  attr :id, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def grid(assigns) do
    ~H"""
    <table id={@id} class={["table table-sm w-full scout-table", @class]}>
      {render_slot(@inner_block)}
    </table>
    """
  end

  attr :cols, :integer, required: true
  slot :inner_block, required: true

  @doc "The one empty state, so every table says nothing the same way."
  def empty(assigns) do
    ~H"""
    <tr>
      <td colspan={@cols} class="py-6 text-center text-sm text-gray-500">
        {render_slot(@inner_block)}
      </td>
    </tr>
    """
  end

  attr :key, :atom, required: true
  attr :label, :string, required: true
  attr :selected, :boolean, required: true

  @doc """
  One space-type chip. Selected chips carry EVE's own colour for that
  space so the filter reads as a legend; an unselected one recedes
  instead of being struck through, which previously made the toolbar
  look broken rather than filtered.
  """
  def space_chip(assigns) do
    ~H"""
    <button
      phx-click="toggle_space"
      phx-value-type={@key}
      id={"scout-space-#{@key}"}
      aria-pressed={to_string(@selected)}
      title={
        if @key == :other,
          do: "Abyssal, Zarzakh, and systems missing from the static map",
          else: "Show or hide #{@label} space everywhere on this page"
      }
      class={[
        "btn btn-sm join-item border",
        if(@selected,
          do: space_tone(@key),
          else: "bg-transparent border-neutral-800 text-gray-600 hover:text-gray-300"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  defp space_tone(:hs), do: "bg-sky-500/15 border-sky-500/40 text-sky-300"
  defp space_tone(:ls), do: "bg-amber-500/15 border-amber-500/40 text-amber-300"
  defp space_tone(:ns), do: "bg-rose-500/15 border-rose-500/40 text-rose-300"
  defp space_tone(:wh), do: "bg-violet-500/15 border-violet-500/40 text-violet-300"
  defp space_tone(:pochven), do: "bg-red-700/20 border-red-700/50 text-red-300"
  defp space_tone(_), do: "bg-neutral-700/40 border-neutral-600 text-gray-300"

  # ---------------------------------------------------------------------
  # Cells
  # ---------------------------------------------------------------------

  attr :row, :map, required: true
  attr :systems, :map, required: true
  attr :truesec, :boolean, default: true

  @doc """
  The system cell: click-to-filter name, then ONE qualifier.

  The qualifier is the class title in w-space and Pochven ("C5",
  "Pochven") and the security status everywhere else — never both.
  `map_solar_system_v2` titles nullsec "0.0" and lowsec "L", so showing
  the pair rendered "1DQ1-A 0.0 -0.4" and "J110145 C5 -1.0": one of the
  two is always noise, and which one depends on the space.
  """
  def sys(assigns) do
    assigns =
      assigns
      |> assign(:class_title, hole_class(assigns.row, assigns.systems))
      |> assign(:sec, sec_value(assigns.row, assigns.systems))

    ~H"""
    <div class="flex items-center gap-1.5 whitespace-nowrap">
      <button
        phx-click="filter_system"
        phx-value-id={@row.solar_system_id}
        class="link link-hover decoration-dotted underline-offset-2"
        title="Filter the whole page to this system"
      >
        {system(@row, @systems)}
      </button>
      <span
        :if={@class_title}
        class="badge badge-xs border-0 bg-violet-500/15 text-violet-300 font-mono"
      >
        {@class_title}
      </span>
      <span
        :if={is_nil(@class_title) and @truesec and security(@sec)}
        class={["font-mono text-[11px]", security_class(@sec)]}
        title="Security status"
      >
        {security(@sec)}
      </span>
    </div>
    """
  end

  # The k-space titles carry nothing the security status does not.
  @kspace_titles ~w(H L 0.0 HS LS NS High Low Null)

  defp hole_class(row, systems) do
    case system_class(row, systems) do
      nil -> nil
      title -> if title in @kspace_titles, do: nil, else: title
    end
  end

  # The client only logs a truesec when it has one; the static map
  # always has it, and the column reading "Jita" with no security at
  # all was worse than either.
  defp sec_value(row, systems) do
    case Map.get(row, :system_truesec) do
      value when is_float(value) ->
        value

      _ ->
        case Map.get(systems, row.solar_system_id) do
          %{security: security} when is_binary(security) ->
            case Float.parse(security) do
              {value, _rest} -> value
              :error -> nil
            end

          _ ->
            nil
        end
    end
  end

  attr :name, :string, required: true
  attr :badge, :string, default: nil
  attr :meta, :string, default: nil
  attr :click, :string, required: true
  attr :rest, :global

  @doc "A clickable subject (structure or spawn) with its type chip and a muted second line."
  def subject(assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="flex items-center gap-1.5 min-w-0">
        <button
          phx-click={@click}
          {@rest}
          class="link link-hover text-left font-medium truncate decoration-dotted underline-offset-2"
          title="Show every report of this"
        >
          {@name}
        </button>
        <span
          :if={@badge}
          class="badge badge-xs border-0 bg-neutral-800 text-gray-400 whitespace-nowrap"
        >
          {@badge}
        </span>
      </div>
      <div :if={@meta} class="text-[11px] text-gray-500 truncate">{@meta}</div>
    </div>
    """
  end

  attr :status, :string, default: nil
  attr :vulnerable, :boolean, default: false

  @doc """
  The status badge. Coloured by family (`WandererApp.Scout.Status`), and
  deliberately quiet for the steady tier: when every row shouts, the
  reinforced one stops standing out.
  """
  def status(assigns) do
    ~H"""
    <div class="flex items-center gap-1 whitespace-nowrap">
      <span class={["badge badge-sm border", status_badge_class(@status)]}>
        {@status || "—"}
      </span>
      <span
        :if={@vulnerable}
        class="badge badge-sm border-0 bg-error/20 text-error"
        title="Shootable right now"
      >
        vuln
      </span>
    </div>
    """
  end

  attr :expires_at, :any, default: nil
  attr :now, :any, required: true
  attr :absolute, :boolean, default: true

  @doc "A reinforcement countdown: how long, then when."
  def countdown_cell(assigns) do
    ~H"""
    <div :if={is_nil(@expires_at)} class="text-gray-600">—</div>
    <div :if={@expires_at} class="whitespace-nowrap">
      <span class={["font-mono font-medium tabular-nums", urgency(@expires_at, @now)]}>
        {countdown(@expires_at, @now)}
      </span>
      <div :if={@absolute} class="text-[11px] text-gray-500 font-mono">{at(@expires_at)}</div>
    </div>
    """
  end

  attr :at, :any, default: nil
  attr :now, :any, required: true
  attr :tone, :boolean, default: false

  @doc """
  An observation time. The age is what a reader acts on, the timestamp is
  what they quote in fleet chat, so both — age first.
  """
  def seen(assigns) do
    ~H"""
    <div class="whitespace-nowrap">
      <span class={[
        "font-mono tabular-nums",
        @tone && freshness(@at, @now),
        !@tone && "text-gray-300"
      ]}>
        {ago(@at, @now)}
      </span>
      <div class="text-[11px] text-gray-500 font-mono">{at(@at)}</div>
    </div>
    """
  end

  # ---------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------

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
  # The fresh list's analogue of urgency/2: how much to trust that a
  # spawn seen this long ago is still sitting where it was reported.
  def freshness(nil, _now), do: "text-gray-500"

  def freshness(observed_at, now) do
    case DateTime.diff(now, observed_at, :second) do
      seconds when seconds < 1_800 -> "text-success font-semibold"
      seconds when seconds < 5_400 -> "text-warning"
      _ -> "text-gray-300"
    end
  end

  @doc false
  # Section copy derives from @fresh_seconds so the two never drift.
  def fresh_window_label, do: "#{div(@fresh_seconds, 3600)}h"

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
  # Millions, because most values in this log are one: "412.5M". Past a
  # billion the millions reading stops being a reading -- "1240.0M" is
  # counted, not seen -- so it rolls over to "1.24B".
  def isk(nil), do: "—"

  def isk(value) do
    millions = value |> Decimal.div(1_000_000) |> Decimal.round(1) |> Decimal.to_float()

    if millions >= 1_000 do
      "#{Float.round(millions / 1_000, 2)}B"
    else
      "#{millions}M"
    end
  end

  @doc false
  # "1 report", "3 reports" -- the modal subtitle counts whatever it just
  # opened, and "1 reports" reads like a bug in the data.
  def plural(1, singular, _plural), do: "1 #{singular}"
  def plural(count, _singular, plural), do: "#{count} #{plural}"

  @doc false
  # The closest static-map body to the STRUCTURE (not the observer),
  # rendered as a dim second line under the structure name. `distance_m`
  # is the observer's range and goes stale the moment the session ends;
  # this is permanent, which is the point of showing it at all. Accepts
  # any struct/map carrying the two fields -- `List.first/1` on an empty
  # history list hands back `nil`, and an unrelated row (a spawn, a
  # hotspot) simply has neither key.
  def nearest_celestial_label(row) do
    row = row || %{}

    case Map.get(row, :nearest_celestial) do
      nil -> nil
      "" -> nil
      name -> format_celestial(name, Map.get(row, :nearest_celestial_m))
    end
  end

  defp format_celestial(name, meters) when is_integer(meters) and meters >= 1000,
    do: "#{name} — #{Float.round(meters / 1000, 1)} km"

  defp format_celestial(name, meters) when is_integer(meters), do: "#{name} — #{meters} m"
  defp format_celestial(name, _meters), do: name

  @doc false
  # One badge, coloured by status family (`WandererApp.Scout.Status`)
  # rather than by the raw string, so every status in the same tier
  # reads the same at a glance. The ONE place this mapping lives --
  # every table on this page calls through here instead of re-deriving
  # it inline.
  #
  #   * Abandoned / NoFuel -- the opportunity tier: asset safety is off
  #     or nobody is paying the fuel bill.
  #   * ArmorReinforced / HullReinforced / ShieldReinforced -- the
  #     timer tier: a clock is running.
  #   * ArmorVulnerable / HullVulnerable -- the live-fight tier:
  #     shootable right now.
  #   * the ANCHORING family -- the free-kill tier: no fitting, no
  #     services, a live vulnerability window.
  #   * Unanchored -- the top tier, and the only badge on this page that
  #     is solid rather than tinted: it is what the red banner above the
  #     toolbar is about.
  #   * Unanchoring -- its own tier: a one-shot deadline.
  #   * STEADY -- muted: nothing to do here, and nothing that should
  #     draw an eye away from the rows above.
  def status_badge_class(nil), do: "bg-transparent border-neutral-700 text-gray-500"

  def status_badge_class(status) do
    cond do
      status in Status.unanchored_family() -> "bg-error border-error text-white font-semibold"
      status in Status.dead_family() -> "bg-error/15 border-error/40 text-error"
      status in Status.vulnerable_family() -> "bg-error/15 border-error/40 text-error"
      status in Status.unanchoring_family() -> "bg-error/15 border-error/40 text-error"
      status in Status.reinforced_family() -> "bg-warning/15 border-warning/40 text-warning"
      status in Status.anchoring_family() -> "bg-warning/15 border-warning/40 text-warning"
      status in Status.steady_family() -> "bg-transparent border-neutral-700 text-gray-400"
      true -> "bg-transparent border-neutral-700 text-gray-400"
    end
  end

  @doc false
  # "72% / 54% / 100%": shield, armor, hull, in that order. "—" for
  # whichever the client has not reported (a POCO carries no hull_pct).
  def hp_label(row) do
    [row.shield_pct, row.armor_pct, row.hull_pct]
    |> Enum.map(&pct_label/1)
    |> Enum.join(" / ")
  end

  defp pct_label(nil), do: "—"
  defp pct_label(value), do: "#{value}%"

  @doc false
  # The resolved nearest celestial if the client has one, else the raw
  # observer-relative distance -- one fallback a caller can render
  # without checking both fields itself.
  def distance_or_celestial(row) do
    case nearest_celestial_label(row) do
      nil -> format_distance(Map.get(row, :distance_m))
      label -> label
    end
  end

  defp format_distance(nil), do: "—"

  defp format_distance(meters) when is_integer(meters) and meters >= 1000,
    do: "#{Float.round(meters / 1000, 1)} km"

  defp format_distance(meters) when is_integer(meters), do: "#{meters} m"
  defp format_distance(_meters), do: "—"

  @doc false
  # The client logs the raw system ID as the name when it has not
  # resolved the real one yet; `systems` is this page's own resolution,
  # and the stored string is the fallback.
  def system(row, systems) do
    case Map.get(systems, row.solar_system_id) do
      %{solar_system_name: name} when is_binary(name) and name != "" -> name
      _ -> Map.get(row, :solar_system_name) || to_string(row.solar_system_id)
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
  # Truesec as EVE shows it: one decimal, which is how the client logs
  # it and how every in-game UI prints it.
  def security(nil), do: nil
  def security(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  def security(_), do: nil

  @doc false
  # EVE's own security colouring, compressed to three bands: a reader
  # scanning the system column is deciding "can I undock a bomber here",
  # not reading two decimals.
  def security_class(value) when is_float(value) do
    cond do
      value >= 0.45 -> "text-sky-400"
      value > 0.0 -> "text-amber-400"
      true -> "text-rose-400"
    end
  end

  def security_class(_), do: "text-gray-500"
end
