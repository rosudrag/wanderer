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

  alias WandererApp.Scout.{Status, Unanchor}

  # A faction spawn seen within this long is worth flying to. Mirrored by
  # `ScoutIntelLive`'s read, which is what makes the list a *list*; this
  # copy is the one the copy renders from.
  @fresh_seconds 24 * 3_600

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

  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :count, :any, default: nil
  slot :inner_block, required: true

  @doc """
  The raw feed at the bottom of a tab: everything that was ingested, in
  the order it arrived.

  Deliberately NOT a `panel/1`. The boards above it are findings — a
  running timer, an unanchored Fortizar, an abandoned Azbel — and the
  flat log is the tape they were derived from; rendering it with the
  same weight as a board made the page end on its least actionable
  table. Dashed border, monospace label, muted body: it reads as the
  ingest it is, and a reader who wants it still has every row.
  """
  def log_panel(assigns) do
    ~H"""
    <section
      id={@id}
      class="mt-8 mb-5 rounded-lg border border-dashed border-neutral-800 bg-neutral-950/40 overflow-hidden"
    >
      <header class="flex items-center gap-2 px-3 py-1.5 border-b border-dashed border-neutral-800">
        <span class="w-1.5 h-1.5 rounded-full bg-neutral-600 shrink-0"></span>
        <h2 class="text-[11px] font-mono uppercase tracking-wider text-gray-500 whitespace-nowrap">
          {@title}
        </h2>
        <span :if={@count} class="text-[11px] font-mono text-gray-600">{@count}</span>
        <span :if={@hint} class="text-[11px] text-gray-600 truncate hidden md:inline">{@hint}</span>
      </header>
      <div class="overflow-x-auto opacity-80 hover:opacity-100 transition-opacity">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

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

      <div class="flex flex-wrap items-center gap-1.5 ml-auto">
        <button
          :for={row <- Enum.take(@rows, 8)}
          phx-click="filter_system"
          phx-value-id={row.solar_system_id}
          class="badge badge-sm border border-error/50 bg-error/10 text-gray-100 hover:bg-error/25 gap-1"
          title={"#{row.structure_name || row.structure_id} — #{@horizon_days}-day horizon, not the window selector"}
        >
          {system(row, @systems)}
          <span class="text-error/80 font-mono">{ago(row.last_confirmed_at, @now)}</span>
        </button>
        <span :if={length(@rows) > 8} class="text-xs text-gray-400">
          +{length(@rows) - 8}
        </span>
      </div>
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
  # CHEWY PATCH (scout planner security focus): a page may render more
  # than one of these rows -- the planner renders one per MODE, rank and
  # sweep, over two separate assigns -- so the event name and the DOM id
  # are per-instance. They default to the intel page's originals, which
  # is every other call site. Hardcoding them cost a shipped bug: the
  # sweep row fired `toggle_space`, which mutated the RANK filter, so
  # "sweep Metropolis lowsec only" was unreachable from the UI and
  # `toggle_sweep_space` was dead code.
  attr :event, :string, default: "toggle_space"
  attr :id, :string, default: nil
  attr :title, :string, default: nil

  @doc """
  One space-type chip. Selected chips carry EVE's own colour for that
  space so the filter reads as a legend; an unselected one recedes
  instead of being struck through, which previously made the toolbar
  look broken rather than filtered.
  """
  def space_chip(assigns) do
    ~H"""
    <button
      phx-click={@event}
      phx-value-type={@key}
      id={@id || "scout-space-#{@key}"}
      aria-pressed={to_string(@selected)}
      title={@title || default_chip_title(@key, @label)}
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

  defp default_chip_title(:other, _label),
    do: "Abyssal, Zarzakh, and systems missing from the static map"

  defp default_chip_title(_key, label), do: "Show or hide #{label} space everywhere on this page"

  defp space_tone(:hs), do: "bg-sky-500/15 border-sky-500/40 text-sky-300"
  defp space_tone(:ls), do: "bg-amber-500/15 border-amber-500/40 text-amber-300"
  defp space_tone(:ns), do: "bg-rose-500/15 border-rose-500/40 text-rose-300"
  defp space_tone(:wh), do: "bg-violet-500/15 border-violet-500/40 text-violet-300"
  defp space_tone(:pochven), do: "bg-red-700/20 border-red-700/50 text-red-300"
  defp space_tone(_), do: "bg-neutral-700/40 border-neutral-600 text-gray-300"

  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  @doc """
  One labelled control in a toolbar.

  `min-w-0` is the load-bearing class: the toolbars are grids now, and a
  grid child defaults to `min-width: auto`, so one `w-48` input inside
  one unconstrained cell stops the whole bar from ever wrapping and the
  page grows a horizontal scrollbar at every width below a desktop's.
  """
  def field(assigns) do
    ~H"""
    <div class={["min-w-0", @class]}>
      <label class="block text-[10px] uppercase tracking-wider text-gray-500 mb-0.5 truncate">
        {@label}
      </label>
      {render_slot(@inner_block)}
      <p :if={@hint} class="mt-0.5 text-[10px] text-gray-500 truncate">{@hint}</p>
    </div>
    """
  end

  attr :id, :string, default: nil
  slot :inner_block, required: true

  @doc """
  The empty state for something that is NOT a table.

  `empty/1` renders a `<tr>`; dropped into a `<div>` — which the sweep
  mode did, twice — the browser discards it, so the one sentence telling
  a reader to pick a scope never appeared at all.
  """
  def note(assigns) do
    ~H"""
    <p
      id={@id}
      class="mb-5 rounded-lg border border-dashed border-neutral-800 bg-neutral-950/40 px-3 py-5 text-center text-sm text-gray-500"
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  attr :busy, :boolean, required: true
  attr :label, :string, default: "computing"

  @doc """
  The page is recomputing, and the numbers below are the previous
  answer.

  `/scout/planner` computes a BFS ball, a coverage read and a route per
  control change — a second or more on a real region. Blanking the
  tables for that second made every click feel like a page load; keeping
  them and saying so does not.
  """
  def busy(assigns) do
    ~H"""
    <span
      :if={@busy}
      class="flex items-center gap-1.5 text-[11px] text-orange-300 whitespace-nowrap"
      role="status"
    >
      <span class="loading loading-spinner loading-xs"></span>
      {@label}…
    </span>
    """
  end

  attr :status, :map, default: nil
  attr :scope, :any, required: true

  @doc """
  CHEWY PATCH (scout planner): what the last `Set route` on THIS button
  did, inline beside it.

  Pushing a route is the one control on `/scout` whose result is not on
  the page at all — it is in another process, in the game client — so a
  toast that fades is the whole feedback, and "I set a route and it
  never arrived" is indistinguishable from "ESI refused stop 1". This
  renders the outcome, with its reason, until the next push: how many
  waypoints of how many landed, whether the pilot's client was even
  running, and what ESI said when it stopped.

  `scope` keys it to one button (`:rank`, `:sweep`, `{:part, i}`) so a
  part's result cannot read as the whole sweep's.
  """
  def route_outcome(assigns) do
    ~H"""
    <p
      :if={@status && @status.scope == @scope}
      class={[
        "text-[11px] leading-snug max-w-[26rem]",
        @status.level == :ok && "text-emerald-300",
        @status.level == :warn && "text-amber-300",
        @status.level == :error && "text-rose-300"
      ]}
      role="status"
    >
      {@status.text}
    </p>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :scope, :string, required: true
  attr :query, :string, required: true
  attr :matches, :list, required: true
  attr :selected, :list, required: true
  attr :max, :integer, default: nil
  attr :placeholder, :string, default: "Search regions…"
  attr :title, :string, default: nil

  @doc """
  Region scope: type a NAME, click to add, click a chip to drop it.

  Both scope controls used to be a text box taking `ids, comma-separated`,
  which is only usable by someone who has already memorised that Domain
  is `10000043` — nothing in this app ever showed that mapping. The
  vocabulary comes from `WandererApp.Scout.Regions`, cached, so typing
  costs no query.
  """
  def region_picker(assigns) do
    ~H"""
    <div class="min-w-0">
      <label class="block text-[10px] uppercase tracking-wider text-gray-500 mb-0.5 truncate">
        {@label}
      </label>
      <div class="relative" phx-click-away="close_region_search" phx-value-scope={@scope}>
        <form phx-change="search_regions" phx-submit="search_regions">
          <input type="hidden" name="scope" value={@scope} />
          <input
            type="text"
            name="q"
            id={@id}
            value={@query}
            phx-debounce="200"
            autocomplete="off"
            placeholder={@placeholder}
            title={@title}
            class="input input-sm input-bordered bg-neutral-950/60 w-full"
          />
        </form>
        <div
          :if={@matches != []}
          id={"#{@id}-options"}
          class="absolute z-20 mt-1 w-full min-w-[14rem] rounded-lg border border-neutral-700 bg-neutral-900 shadow-lg max-h-64 overflow-auto"
        >
          <button
            :for={region <- @matches}
            type="button"
            phx-click="add_region"
            phx-value-scope={@scope}
            phx-value-id={region.region_id}
            id={"#{@id}-option-#{region.region_id}"}
            class="flex w-full items-baseline justify-between gap-2 px-3 py-1.5 text-left text-sm hover:bg-neutral-800"
          >
            <span class="truncate">{region.region_name}</span>
            <span class="font-mono text-[10px] text-gray-500">{region.region_id}</span>
          </button>
        </div>
      </div>
      <div :if={@selected != []} class="flex flex-wrap gap-1 mt-1">
        <button
          :for={region <- @selected}
          type="button"
          phx-click="remove_region"
          phx-value-scope={@scope}
          phx-value-id={region.region_id}
          id={"#{@id}-chip-#{region.region_id}"}
          title="Drop this region from the scope"
          class="badge badge-sm gap-1 border-0 bg-neutral-800 text-gray-200 hover:bg-neutral-700"
        >
          {region.region_name} ✕
        </button>
      </div>
      <p class="mt-0.5 text-[10px] text-gray-500 truncate">
        <%= cond do %>
          <% @selected == [] and @max -> %>
            none yet — pick up to {@max}
          <% @selected == [] -> %>
            every region
          <% @max && length(@selected) >= @max -> %>
            {length(@selected)} of {@max} — drop one to add another
          <% @max -> %>
            {length(@selected)} of {@max}
          <% true -> %>
            {length(@selected)} selected
        <% end %>
      </p>
    </div>
    """
  end

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

  attr :presence, :atom, required: true

  @doc """
  CHEWY PATCH: the presence badge -- `WandererApp.Api.ScoutStructure`'s
  current-state signal, orthogonal to `status`. `:seen` renders plain
  (nothing to flag, the structure is an active target); `:cleared` /
  `:missing` / `:gone` render muted, the same "nothing to do here" tone
  `status_badge_class/1` uses for the steady tier -- these are exactly
  the presences every opportunity board already filters out, so seeing
  one here only ever happens on `:search`, which shows every presence.
  """
  def presence_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm border-0", presence_badge_class(@presence)]}>
      {@presence}
    </span>
    """
  end

  defp presence_badge_class(:seen), do: "bg-success/15 text-success"
  defp presence_badge_class(_other), do: "bg-neutral-800 text-gray-500"

  attr :row, :map, required: true

  @doc """
  CHEWY PATCH: the archive button every structure board carries in its
  last column — the one control on this page that writes.

  Archiving is how a reader says "I flew there, it is not there": the row
  leaves every opportunity board, the red banner and the sidebar badge,
  and lands on the Archived board, which is where it is undone. The
  suppression is NOT permanent and NOT a delete — see the `:archived`
  calculation on `WandererApp.Api.ScoutStructure`.

  Rendered from `row.archived`, the loaded calculation, so the button and
  the SQL that hid the row can never disagree about what archived means.
  """
  def archive_cell(assigns) do
    ~H"""
    <button
      :if={!archived?(@row)}
      phx-click="archive_structure"
      phx-value-id={@row.structure_id}
      class="btn btn-ghost btn-xs text-gray-600 hover:text-error"
      title="Archive — take this off the boards until its state changes"
    >
      ✕
    </button>
    <button
      :if={archived?(@row)}
      phx-click="restore_structure"
      phx-value-id={@row.structure_id}
      class="btn btn-ghost btn-xs text-gray-500 hover:text-warning"
      title="Restore — put this back on the boards"
    >
      ↺
    </button>
    """
  end

  # Exact match on `true`: an unloaded Ash calculation is an
  # `%Ash.NotLoaded{}` struct, which is truthy, and would otherwise draw
  # the restore button on every live row.
  defp archived?(%{archived: true}), do: true
  defp archived?(_row), do: false

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

  attr :row, :map, required: true
  attr :now, :any, required: true

  @doc """
  CHEWY PATCH: the Unanchoring board's deadline. A decommission carries
  no wire timer — `timer_expires_at` is nil on every row of that board,
  which is why the "Comes out" countdown it used to render was a column
  of em dashes — so this renders the one bound the mechanic gives:
  first sighting of the run plus the fixed 7-day window, i.e. the
  LATEST the hull can still be there. `≤` is load-bearing: the real
  completion is at or before it. See `WandererApp.Scout.Unanchor`.
  """
  def predicted_out_cell(assigns) do
    assigns = assign(assigns, :predicted_at, Unanchor.predicted_max_at(assigns.row))

    ~H"""
    <div
      :if={is_nil(@predicted_at)}
      class="text-gray-600"
      title={
        if Unanchor.orbital?(@row),
          do: "Orbital: unanchors in minutes, not the 7-day Upwell decommission",
          else: "No sighting of the start of this unanchor yet"
      }
    >
      —
    </div>
    <div
      :if={@predicted_at}
      class="whitespace-nowrap"
      title="Latest it can still be in space: first sighting of this unanchor + the fixed 7-day decommission"
    >
      <span class={["font-mono font-medium tabular-nums", urgency(@predicted_at, @now)]}>
        ≤ {countdown(@predicted_at, @now)}
      </span>
      <div class="text-[11px] text-gray-500 font-mono">{at(@predicted_at)}</div>
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

  attr :stop, :map, required: true

  @doc """
  CHEWY PATCH (scout refresh): the class/security cell for a ranked
  stop from `WandererApp.Scout.Planner.rank/1`. Mirrors `sys/1`'s rule
  -- a w-space/Pochven class title OR a k-space security status, never
  both -- but reads straight off the stop map the planner already
  enriched, rather than a `systems` resolution map: there is no second
  lookup to keep in sync here.
  """
  def stop_class(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 whitespace-nowrap">
      <span
        :if={@stop.class_title}
        class="badge badge-xs border-0 bg-violet-500/15 text-violet-300 font-mono"
      >
        {@stop.class_title}
      </span>
      <span
        :if={is_nil(@stop.class_title) and security(@stop.security)}
        class={["font-mono text-[11px]", security_class(@stop.security)]}
        title="Security status"
      >
        {security(@stop.security)}
      </span>
      <span :if={is_nil(@stop.class_title) and is_nil(security(@stop.security))} class="text-gray-600">
        —
      </span>
    </div>
    """
  end

  attr :stop, :map, required: true

  @doc """
  CHEWY PATCH (scout sweep): the class/security cell for a
  `WandererApp.Scout.Sweep.sweep_stop`. Unlike `stop_class/1` above
  (`Planner.rank/1`'s stops, which carry a resolved `class_title`), a
  sweep stop's contract has no `class_title` -- only `system_class` and
  `security` -- so this renders the security status alone; the space
  badge already beside the system name (`space_badge/1`) is what tells
  wormhole/Pochven space apart on a sweep row, so there is nothing a
  class title would add here that is not already shown once.
  """
  def sweep_class_cell(assigns) do
    ~H"""
    <span
      :if={security(@stop.security)}
      class={["font-mono text-[11px]", security_class(@stop.security)]}
      title="Security status"
    >
      {security(@stop.security)}
    </span>
    <span :if={is_nil(security(@stop.security))} class="text-gray-600">—</span>
    """
  end

  attr :space, :atom, required: true

  @doc "A static space-type badge -- `space_chip/1`'s tone, without the click."
  def space_badge(assigns) do
    ~H"""
    <span class={["badge badge-xs border font-mono", space_tone(@space)]}>
      {@space}
    </span>
    """
  end

  attr :reason, :atom, required: true

  @doc """
  Why a stop ranked where it did, reduced to one word (design doc
  section 5): `:unseen` is the loudest tier -- a system that has never
  produced a coverage row of the requested kind -- down to `:fresh`,
  which recedes the same way `status_badge_class/1` mutes the steady
  tier on the intel log.
  """
  def reason_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm border-0", reason_class(@reason)]}>
      {@reason}
    </span>
    """
  end

  defp reason_class(:unseen), do: "bg-error/20 text-error"
  defp reason_class(:frontier), do: "bg-violet-500/20 text-violet-300"
  defp reason_class(:stale), do: "bg-warning/20 text-warning"
  defp reason_class(:fresh), do: "bg-success/15 text-success"
  defp reason_class(_), do: "bg-neutral-800 text-gray-400"

  attr :coverage, :map, required: true
  attr :kind, :atom, required: true
  attr :now, :any, required: true

  @coverage_kinds [:visit, :anoms, :sigs, :grid]

  @doc """
  The coverage ladder itself (design doc section 2): one age per kind,
  on one row, with the kind the operator asked for picked out. A stop
  ranked on `sigs` staleness may still be `grid`-fresh from yesterday's
  tour, and that is worth seeing without re-querying four tables.
  """
  def coverage_ladder(assigns) do
    assigns = assign(assigns, :kinds, @coverage_kinds)

    ~H"""
    <div class="flex items-center gap-2 whitespace-nowrap font-mono text-[11px]">
      <span
        :for={k <- @kinds}
        class={if k == @kind, do: "text-gray-100 font-semibold", else: "text-gray-500"}
        title={"#{k}: #{at(Map.get(@coverage, k))}"}
      >
        {k}:{ago(Map.get(@coverage, k), @now)}
      </span>
    </div>
    """
  end

  attr :stop, :map, required: true

  @doc """
  CHEWY PATCH (scout coverage ledger): the clean-tour verdict a `grid`
  coverage row now carries alongside its own age in `coverage_ladder/1`
  -- `spawns_found` (count of scanned locations with at least one
  special spawn since arrival) and `legs_total` (that pass's leg
  count), both from `WandererApp.Api.ScoutSystemCoverage`. Renders an
  em dash whenever `stop.spawns_found` is `nil`: either this stop's
  selected kind is not `:grid`, or no `grid` row exists yet for this
  system -- both cases the operator has no verdict to read, not a zero.
  One muted column: the server derives CLEAN vs partial, the client
  never sends a boolean, and this is not an alert the way the
  unanchored badge is.
  """
  def grid_verdict(assigns) do
    ~H"""
    <span class="text-[11px] text-gray-400 whitespace-nowrap" title={verdict_title(@stop)}>
      {verdict_text(@stop)}
    </span>
    """
  end

  defp verdict_text(%{spawns_found: nil}), do: "—"

  defp verdict_text(%{spawns_found: found}) when found > 0,
    do: "#{found} spawn#{if found == 1, do: "", else: "s"}"

  defp verdict_text(%{spawns_found: 0} = stop) do
    if grid_tour_complete?(stop), do: "clean", else: partial_text(stop)
  end

  defp partial_text(%{legs_scanned: scanned, legs_total: total}),
    do: "partial (#{scanned || 0}/#{total})"

  defp verdict_title(%{spawns_found: nil}), do: "No grid-tour verdict for this kind/system yet"

  defp verdict_title(%{spawns_found: found, legs_scanned: scanned, legs_total: total}) do
    "spawns_found=#{found}, legs_scanned=#{scanned || "?"}/#{total || "?"}"
  end

  defp grid_tour_complete?(%{legs_total: nil}), do: true
  defp grid_tour_complete?(%{legs_scanned: scanned, legs_total: total}), do: scanned == total

  attr :terms, :map, required: true

  @doc """
  The score breakdown (design doc section 5): `score = need*W_need +
  frontier*W_frontier + value*W_value - jumps*W_distance -
  claimed*W_claimed`. Section 8's whole gate for the refresh page is
  that a human can read why a system ranked where it did, so every
  weighted term renders, not just the final number.
  """
  def terms_hint(assigns) do
    ~H"""
    <span
      class="font-mono text-[11px] text-gray-500 whitespace-nowrap"
      title="need + frontier + value - distance - claimed = score"
    >
      need {score_fmt(@terms.need)} · frontier {score_fmt(@terms.frontier)} · value {score_fmt(
        @terms.value
      )} · distance {score_fmt(@terms.distance)} · claimed {score_fmt(@terms.claimed)}
    </span>
    """
  end

  attr :stop, :map, required: true

  @doc """
  "Mark stale" (design doc sections 8-9): destroys the stored coverage
  row for this system + the selected kind outright, the reader's
  "re-scout this now" override. Rendered only when there IS a row to
  destroy -- `age_s < 0` means the planner already read this system as
  unseen for this kind, and the button would destroy nothing.
  """
  def stale_cell(assigns) do
    ~H"""
    <button
      :if={@stop.age_s >= 0}
      phx-click="mark_stale"
      phx-value-id={@stop.solar_system_id}
      class="btn btn-ghost btn-xs text-gray-600 hover:text-error"
      title="Clear this system's coverage row for the selected kind"
    >
      mark stale
    </button>
    <span :if={@stop.age_s < 0} class="text-gray-700">—</span>
    """
  end

  attr :waypoint?, :boolean, required: true

  @doc """
  CHEWY PATCH (scout sweep): marks a `WandererApp.Scout.Sweep.sweep_stop`
  as a pushed WAYPOINT versus a pass-through EVE flies through on the
  way without any input (design doc "only crossroads become waypoints"
  section). The distinction is the whole point of compression -- a
  reader staring at the sweep table must be able to tell which stops
  are actually sent to ESI.
  """
  def waypoint_badge(assigns) do
    ~H"""
    <span
      :if={@waypoint?}
      class="badge badge-xs border-0 bg-primary/20 text-primary font-mono"
      title="Pushed as a waypoint"
    >
      WP
    </span>
    <span
      :if={!@waypoint?}
      class="text-gray-700 font-mono text-[11px]"
      title="Flown through on the way, never pushed on its own"
    >
      ·
    </span>
    """
  end

  attr :covered, :integer, required: true
  attr :stale, :integer, required: true
  attr :unseen, :integer, required: true
  attr :systems, :integer, required: true

  @doc """
  CHEWY PATCH (scout sweep): the region heat table's bar -- fresh /
  stale / unseen as one proportional strip, because "94 of 189 fresh"
  is a division a reader would otherwise do in their head on every row
  of `WandererApp.Scout.Sweep.region_heat/1` (design doc "which region
  to sweep at all" section).
  """
  def heat_bar(assigns) do
    fresh = max(assigns.systems - assigns.stale - assigns.unseen, 0)
    assigns = assign(assigns, :fresh, fresh)

    ~H"""
    <div class="flex items-center gap-1.5 w-32">
      <div class="flex h-2 w-20 rounded-full overflow-hidden bg-neutral-800">
        <div class="bg-success/70" style={"width: #{heat_pct(@fresh, @systems)}%"}></div>
        <div class="bg-warning/70" style={"width: #{heat_pct(@stale, @systems)}%"}></div>
        <div class="bg-error/70" style={"width: #{heat_pct(@unseen, @systems)}%"}></div>
      </div>
      <span class="text-[11px] text-gray-500 font-mono tabular-nums">{@covered}/{@systems}</span>
    </div>
    """
  end

  defp heat_pct(_n, 0), do: 0
  defp heat_pct(n, total), do: Float.round(n / total * 100, 1)

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
  # The closest static-map body to the STRUCTURE, by NAME only.
  #
  # Every metre this page used to print was noise. `distance_m` was the
  # range from the character that happened to be in the system when the
  # sweep ran -- it describes where a scout was parked, not where the
  # structure is, and is meaningless the moment that session ends.
  # `nearest_celestial_m` is real but unactionable: a reader wants "it
  # is on moon 3", never "it is 12.4 km off moon 3". So the celestial
  # renders as a bare name and both distances are gone from the UI
  # (`nearest_celestial_m` is still stored, merged and exported).
  #
  # Accepts any struct/map carrying the field -- `List.first/1` on an
  # empty history list hands back `nil`, and an unrelated row (a spawn,
  # a hotspot) simply has no such key.
  def nearest_celestial_label(row) do
    case Map.get(row || %{}, :nearest_celestial) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

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
  # The "Where" column: the nearest celestial's name, or nothing. There
  # is deliberately no distance fallback any more -- the old one printed
  # `distance_m`, the observing character's own range, which told a
  # reader where a scout was sitting rather than anything about the
  # target.
  def where(row), do: nearest_celestial_label(row) || "—"

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

  @doc false
  # The ranked-stop score, to two decimals -- `terms_hint/1`'s per-term
  # formatter and the refresh table's Score column share this rather
  # than each rolling their own float_to_binary call.
  def score_fmt(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  def score_fmt(_value), do: "0.00"

  @doc false
  # CHEWY PATCH (scout sweep): `WandererApp.Scout.Sweep.region_heat/1`'s
  # `median_age_s` is a plain integer, not a `DateTime` -- `countdown/2`
  # above needs an expiry to diff against `now`, which this has no use
  # for, so it gets its own one-line formatter rather than a fake
  # "expires at" datetime manufactured just to satisfy `countdown/2`.
  def age_fmt(nil), do: "—"
  def age_fmt(seconds) when is_integer(seconds), do: format_countdown(seconds)

  @doc false
  # `WandererApp.Scout.Planner.rank/1`'s `{:error, reason}` branch, read
  # by a human rather than logged -- the refresh page's whole empty
  # state when the planner cannot answer.
  def plan_error_message(reason) when is_atom(reason) do
    "Could not build a plan: " <> (reason |> to_string() |> String.replace("_", " ")) <> "."
  end

  def plan_error_message(_reason), do: "Could not build a plan."
end
