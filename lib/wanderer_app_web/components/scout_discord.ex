defmodule WandererAppWeb.ScoutDiscord do
  @moduledoc """
  CHEWY PATCH: `/scout`'s boards as a message a reader pastes into
  Discord.

  The page already answers "what is worth flying to"; the answer then
  gets retyped into a fleet channel by hand, badly — a countdown copied
  as text is wrong by the time anyone reads it, and "22:41" is wrong for
  everyone not on UTC.

  Discord's own timestamp markup solves exactly that: `<t:1760000000:R>`
  renders as a LIVE relative countdown ("in 3 hours") and `<t:…:f>` as an
  absolute instant, both in each reader's own timezone, re-rendered on
  every view rather than frozen at paste time. So a timer board pasted
  once keeps counting down for everyone in the channel.

  Three constraints shape everything here:

    * **2000 characters per message** (`@limit`). Non-negotiable: Discord
      rejects the paste outright, it does not truncate. So the budget
      decides how MANY messages a reader pastes, never how much is left
      out: `message/3` returns a LIST of parts, each inside the limit,
      and the UI renders one text box per part. Dropping rows was the
      old behaviour and it was wrong — a finding nobody can see is a
      finding nobody flies to, and "nothing else is happening" and "the
      rest did not fit" read identically in a channel.

    * **Timestamps do not render inside a code block.** ``` ` ``-fenced
      text is literal, which kills the one feature this exists for, so
      the message is plain markdown with bold and `·` separators rather
      than an aligned table. That is also why every field that comes from
      the wire is escaped (`escape/1`): an EVE structure name may contain
      `*`, `_` or `|`, and unescaped it would italicise half a line or
      spoiler-tag the rest of it.

    * **Nothing but the rows.** No link back to this deployment: it is a
      private tool, the channel it is pasted into is not, and a URL in
      every paste is an invitation to a login page nobody reading it can
      use. A board that spans a split repeats its header marked
      `_(cont.)_`, which is the only chrome here beyond the headers.

  Sorting is NOT done here. The LiveView already sorted every board for
  the screen (`by_deadline/1`, `by_recent/1`, `by_predicted_out/1`), and
  the paste must match what the reader is looking at.
  """

  import WandererAppWeb.ScoutComponents, only: [system: 2, isk: 1]

  alias WandererApp.Scout.Unanchor

  # Discord's hard per-message cap. A paste over it is rejected, not cut.
  @limit 2000

  # Boards, in the order the digest packs them: the rarest and most
  # valuable finding first, then the things with a clock, then the
  # standing opportunities. Same order as the page.
  @digest_boards [
    # CHEWY PATCH: first, because it is the only finding on the page with
    # a known instant attached -- EVE said this hull came out of the
    # ground at this timestamp, rather than a sweep saying it saw one.
    :asset_safety,
    :unanchored,
    # CHEWY PATCH: the errand, not the finding -- "go put one item in
    # each of these or we will never hear when they pop".
    :unarmed,
    :timers,
    :anchoring,
    :unanchoring,
    :abandoned,
    :no_fuel,
    :spawns
  ]

  # CHEWY PATCH: copyable, but deliberately NOT in the digest. The
  # digest is the errand list for the next hour; a run that already
  # ended is a post-mortem, and spending the shared 2000-character
  # budget on it would push a live timer out of the message.
  @boards @digest_boards ++ [:sorted]

  @doc "The boards `message/3` understands, as strings for `phx-value-board`."
  @spec boards() :: [String.t()]
  def boards, do: Enum.map(@boards ++ [:digest], &to_string/1)

  @doc """
  Parses a `phx-value-board` string. Returns `:error` rather than calling
  `String.to_existing_atom/1` on user input.
  """
  @spec parse_board(String.t()) :: {:ok, atom()} | :error
  def parse_board(value) when is_binary(value) do
    case Enum.find(@boards ++ [:digest], &(to_string(&1) == value)) do
      nil -> :error
      board -> {:ok, board}
    end
  end

  def parse_board(_value), do: :error

  @doc "Discord's per-message character limit, so the UI can show the budget."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  One board, or the whole tab (`:digest`, whose `rows` is a keyword list
  of `{board, rows}`), as pastable messages.

  Options: `:systems` (the page's id -> system resolution) and `:now`.

  Returns `:parts` — every row, split across as many Discord-sized
  messages as it takes, in order. Never fewer rows than it was given.
  """
  @spec message(atom(), list(), keyword()) :: %{
          title: String.t(),
          parts: [String.t()],
          total: non_neg_integer()
        }
  def message(board, rows, opts \\ [])

  def message(:digest, sections, opts) do
    head = "**Scout report** · " <> stamp(Keyword.get(opts, :now) || DateTime.utc_now(), "f")

    sections = Enum.reject(sections, fn {_board, rows} -> rows == [] end)

    groups =
      Enum.map(sections, fn {board, rows} ->
        {header(board, length(rows)), Enum.map(rows, &line(board, &1, opts))}
      end)

    total = Enum.reduce(sections, 0, fn {_board, rows}, sum -> sum + length(rows) end)

    %{title: "Scout report", parts: pack(groups, head), total: total}
  end

  def message(board, rows, opts) when board in @boards do
    lines =
      case rows do
        [] -> [empty(board)]
        rows -> Enum.map(rows, &line(board, &1, opts))
      end

    %{
      title: label(board),
      parts: pack([{header(board, length(rows)), lines}], ""),
      total: length(rows)
    }
  end

  # ---------------------------------------------------------------------
  # Packing
  # ---------------------------------------------------------------------

  # `{header, lines}` groups into as many <= @limit messages as it takes,
  # in order, dropping nothing. The digest keeps its urgency order, so a
  # reader who pastes only the first box still gets the boards that
  # matter most — which is the property the old fair-share budget split
  # was protecting, now had for free.
  defp pack(groups, head) do
    {parts, current} =
      Enum.reduce(groups, {[], head}, fn {header, lines}, acc ->
        acc = append(acc, header, "\n\n", header)
        Enum.reduce(lines, acc, &append(&2, &1, "\n", header <> " _(cont.)_"))
      end)

    [current | parts] |> Enum.reverse() |> Enum.reject(&(&1 == ""))
  end

  # One line onto the current message, or onto a fresh one when it would
  # cross the limit. `restart` opens the fresh message — the board's own
  # header again, so a box that begins mid-board still says what it is —
  # except when the text IS that header.
  defp append({parts, ""}, text, _sep, _restart), do: {parts, text}

  defp append({parts, current}, text, sep, restart) do
    candidate = current <> sep <> text

    cond do
      len(candidate) <= @limit -> {parts, candidate}
      restart == text -> {[current | parts], text}
      true -> {[current | parts], restart <> "\n" <> text}
    end
  end

  # ---------------------------------------------------------------------
  # Rows
  # ---------------------------------------------------------------------

  # Deadline first on every board that has one: it is what the reader
  # acts on, and it is what the board was sorted by.
  defp line(:timers, row, opts) do
    "• " <>
      deadline(row.timer_expires_at) <>
      " · " <> subject(row) <> " · " <> place(row, opts) <> owner(row) <> status(row)
  end

  defp line(:anchoring, row, opts) do
    "• " <>
      deadline(row.timer_expires_at) <>
      " · " <> subject(row) <> " · " <> place(row, opts) <> owner(row) <> status(row)
  end

  # "≤" and nothing else: a decommission reports no countdown, so this is
  # the 7-day bound `WandererApp.Scout.Unanchor` derives, never a timer.
  defp line(:unanchoring, row, opts) do
    bound =
      case Unanchor.predicted_max_at(row) do
        nil -> "no estimate"
        at -> "≤ " <> deadline(at)
      end

    "• " <> bound <> " · " <> subject(row) <> " · " <> place(row, opts) <> owner(row)
  end

  # Same bound as `:unanchoring` — this IS that board, minus the hulls
  # somebody has already dropped an item into.
  defp line(:unarmed, row, opts), do: line(:unanchoring, row, opts)

  # CHEWY PATCH: an ending, so the stamp IS the news — when it stopped
  # being ours to take, and which of the four endings it was. A stored
  # `unanchor_ended_at` is an observation; an expired run has none, so
  # the bound it passed is stamped instead, which is what the page
  # shows too.
  defp line(:sorted, row, opts) do
    ended =
      case row.unanchor_ended_at || Unanchor.predicted_max_at(row) do
        nil -> "—"
        at -> stamp(at, "R")
      end

    outcome = Unanchor.outcome(row, Keyword.get(opts, :now) || DateTime.utc_now())

    "• " <>
      ended <>
      " · " <>
      subject(row) <>
      " · " <> place(row, opts) <> owner(row) <> " · " <> escape(Unanchor.outcome_label(outcome))
  end

  # CHEWY PATCH: the one board whose timestamp is an EVENT, not an
  # observation — EVE's own "asset safety fired" instant. Relative only:
  # what a reader does with it is "20 minutes ago, go now" / "two days
  # ago, forget it", and the absolute form costs budget to say the same.
  defp line(:asset_safety, row, opts) do
    "• " <>
      stamp(row.notified_at, "R") <>
      " · " <> subject(row) <> " · " <> place(row, opts) <> owner(row) <> reporter(row)
  end

  # No "seen N ago" on either of these: the boards only ever carry
  # structures the feed is still confirming (`presence == :seen`), so the
  # stamp said "a few minutes ago" on every row and cost a line's worth
  # of the 2000-character budget to say nothing.
  defp line(:unanchored, row, opts) do
    "• " <> subject(row) <> " · " <> place(row, opts) <> owner(row)
  end

  defp line(:abandoned, row, opts) do
    "• " <> subject(row) <> " · " <> place(row, opts) <> owner(row) <> status(row)
  end

  defp line(:no_fuel, row, opts) do
    "• " <> subject(row) <> " · " <> place(row, opts) <> owner(row) <> status(row)
  end

  defp line(:spawns, row, opts) do
    "• " <>
      "**" <>
      escape(row.spawn_name) <>
      "** · " <>
      system_name(row, opts) <>
      location(row) <> value(row) <> " · " <> stamp(row.observed_at, "R")
  end

  # Relative AND absolute: the countdown is what a reader acts on, the
  # instant is what a fleet is formed on, and both are rendered in the
  # reader's own timezone by Discord rather than in UTC by us.
  defp deadline(nil), do: "—"
  defp deadline(at), do: stamp(at, "R") <> " (" <> stamp(at, "f") <> ")"

  defp subject(row) do
    name = row.structure_name || to_string(row.structure_id)

    case row.group_name do
      group when is_binary(group) and group != "" -> "**#{escape(name)}** _#{escape(group)}_"
      _ -> "**#{escape(name)}**"
    end
  end

  # The system, then the nearest celestial when there is one: "it is on
  # moon 3" is the difference between warping to a structure and
  # scanning for it.
  defp place(row, opts) do
    case row.nearest_celestial do
      body when is_binary(body) and body != "" ->
        system_name(row, opts) <> " (" <> escape(body) <> ")"

      _ ->
        system_name(row, opts)
    end
  end

  defp owner(%{owner_name: name}) when is_binary(name) and name != "", do: " · " <> escape(name)
  defp owner(_row), do: ""

  defp status(%{status: status}) when is_binary(status) and status != "",
    do: " · " <> escape(status)

  defp status(_row), do: ""

  defp location(%{location_name: name}) when is_binary(name) and name != "",
    do: " · " <> escape(name)

  defp location(_row), do: ""

  # Who got the notification: the pilot who seeded the structure, and so
  # the one person in the channel who knows what was in it.
  defp reporter(%{character_name: name}) when is_binary(name) and name != "",
    do: " · via " <> escape(name)

  defp reporter(_row), do: ""

  defp value(%{isk_value: nil}), do: ""
  defp value(%{isk_value: value}), do: " · " <> isk(value)
  defp value(_row), do: ""

  defp system_name(row, opts), do: escape(system(row, Keyword.get(opts, :systems) || %{}))

  # ---------------------------------------------------------------------
  # Chrome
  # ---------------------------------------------------------------------

  defp header(board, count), do: "**#{label(board)} · #{count}**"

  defp label(:asset_safety), do: "💣 Asset safety fired"
  defp label(:unarmed), do: "📥 Unanchoring, nothing seeded"
  defp label(:unanchored), do: "🚨 Unanchored"
  defp label(:timers), do: "⏳ Timers running"
  defp label(:anchoring), do: "🔧 Anchoring"
  defp label(:unanchoring), do: "📦 Unanchoring"
  defp label(:sorted), do: "🪦 Unanchoring runs that ended"
  defp label(:abandoned), do: "💀 Abandoned"
  defp label(:no_fuel), do: "⛽ No fuel"
  defp label(:spawns), do: "⭐ Spawns, last 24h"

  defp empty(:spawns), do: "_Nothing in the last 24 hours._"
  defp empty(_board), do: "_Nothing on this board._"

  @doc false
  # `<t:UNIX:STYLE>` — Discord renders it in the reader's own timezone
  # and keeps a relative one ticking. Styles used here: `R` relative,
  # `f` absolute short date-time.
  def stamp(nil, _style), do: "—"
  def stamp(%DateTime{} = at, style), do: "<t:#{DateTime.to_unix(at)}:#{style}>"

  @doc false
  # EVE lets a structure be called `*** |LOOT PINATA| ***`, and pasted
  # raw that italicises the line and spoiler-tags the rest of it. A
  # newline would be worse: it would split one finding into two bullets.
  def escape(nil), do: ""

  def escape(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace(~r/([\\*_~`|>])/, "\\\\\\1")
  end

  defp len(string), do: String.length(string)
end
