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
      rejects the paste outright, it does not truncate. Every board is
      fitted to the budget and says how many rows it dropped — a silently
      short list is worse than no list, because a reader cannot tell the
      difference between "nothing else is happening" and "the rest did
      not fit".

    * **Timestamps do not render inside a code block.** ``` ` ``-fenced
      text is literal, which kills the one feature this exists for, so
      the message is plain markdown with bold and `·` separators rather
      than an aligned table. That is also why every field that comes from
      the wire is escaped (`escape/1`): an EVE structure name may contain
      `*`, `_` or `|`, and unescaped it would italicise half a line or
      spoiler-tag the rest of it.

    * **One message, not a thread.** The digest (`:digest`) packs the
      boards in urgency order into a single paste and stops when the
      budget runs out, rather than emitting several messages a reader has
      to paste in sequence and Discord then re-orders.

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
  @digest_boards [:unanchored, :timers, :anchoring, :unanchoring, :abandoned, :spawns]

  @boards @digest_boards

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
  of `{board, rows}`), as a pastable message.

  Options: `:systems` (the page's id -> system resolution), `:now`,
  `:url` (the deployment's `/scout` link, appended once).

  Returns the text plus what it had to leave out, because the UI shows
  that beside the box.
  """
  @spec message(atom(), list(), keyword()) :: %{
          title: String.t(),
          text: String.t(),
          shown: non_neg_integer(),
          total: non_neg_integer()
        }
  def message(board, rows, opts \\ [])

  def message(:digest, sections, opts) do
    footer = footer(opts)
    head = "**Scout report** · " <> stamp(Keyword.get(opts, :now) || DateTime.utc_now(), "f")

    sections = Enum.reject(sections, fn {_board, rows} -> rows == [] end)

    # Fair share with carry-forward, NOT greedy fill. Greedy meant a
    # fifty-row Unanchored board ate the whole budget and the digest
    # carried no timers at all -- the one board with a deadline on it.
    # Each board may take `remaining / boards left`; whatever it does not
    # use rolls into the next one, so a short board still donates.
    {blocks, shown, total, _left, _n} =
      Enum.reduce(
        sections,
        {[], 0, 0, @limit - len(head) - len(footer) - 2, length(sections)},
        fn {board, rows}, {blocks, shown, total, left, remaining} ->
          share = if remaining > 1, do: div(left, remaining), else: left

          case block(board, rows, opts, share - 1) do
            {nil, _kept} ->
              {blocks, shown, total + length(rows), left, remaining - 1}

            {text, kept} ->
              {[text | blocks], shown + kept, total + length(rows), left - len(text) - 1,
               remaining - 1}
          end
        end
      )

    text =
      [head | Enum.reverse(blocks)]
      |> Kernel.++([footer])
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{title: "Scout report", text: text, shown: shown, total: total}
  end

  def message(board, rows, opts) when board in @boards do
    footer = footer(opts)

    {text, kept} = block(board, rows, opts, @limit - len(footer) - 2)

    text =
      [text || header(board, length(rows)) <> "\n" <> empty(board), footer]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{title: label(board), text: text, shown: kept, total: length(rows)}
  end

  # ---------------------------------------------------------------------
  # Blocks
  # ---------------------------------------------------------------------

  # One board inside `budget` characters: its header, as many rows as
  # fit, and — when rows were dropped — a line saying how many. nil when
  # not even the header fits, which is how the digest skips a board
  # instead of emitting a heading with nothing under it.
  defp block(_board, [], _opts, _budget), do: {nil, 0}

  defp block(board, rows, opts, budget) do
    head = header(board, length(rows))

    if len(head) + 2 > budget do
      {nil, 0}
    else
      lines = Enum.map(rows, &line(board, &1, opts))
      {kept, dropped} = fit(lines, budget - len(head) - 1)

      cond do
        kept == [] -> {nil, 0}
        dropped == 0 -> {Enum.join([head | kept], "\n"), length(kept)}
        true -> {Enum.join([head | kept] ++ [more(dropped)], "\n"), length(kept)}
      end
    end
  end

  # Greedy fill, then shrink until the "+N more" line itself fits: the
  # note that rows were dropped must never be the thing that pushes the
  # message over the limit.
  defp fit(lines, budget) do
    total = length(lines)

    {kept, _used} =
      Enum.reduce_while(lines, {[], 0}, fn line, {kept, used} ->
        cost = len(line) + 1

        if used + cost > budget,
          do: {:halt, {kept, used}},
          else: {:cont, {[line | kept], used + cost}}
      end)

    kept = Enum.reverse(kept)

    if length(kept) == total do
      {kept, 0}
    else
      shrink(kept, total, budget)
    end
  end

  defp shrink([], total, _budget), do: {[], total}

  defp shrink(kept, total, budget) do
    dropped = total - length(kept)
    cost = Enum.reduce(kept, len(more(dropped)), &(&2 + len(&1) + 1))

    if cost <= budget do
      {kept, dropped}
    else
      kept |> Enum.drop(-1) |> shrink(total, budget)
    end
  end

  defp more(1), do: "_… 1 more not shown_"
  defp more(count), do: "_… #{count} more not shown_"

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

  defp line(:unanchored, row, opts) do
    "• " <>
      subject(row) <>
      " · " <> place(row, opts) <> owner(row) <> " · seen " <> stamp(row.last_confirmed_at, "R")
  end

  defp line(:abandoned, row, opts) do
    "• " <>
      subject(row) <>
      " · " <>
      place(row, opts) <>
      owner(row) <> status(row) <> " · seen " <> stamp(row.last_confirmed_at, "R")
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

  defp value(%{isk_value: nil}), do: ""
  defp value(%{isk_value: value}), do: " · " <> isk(value)
  defp value(_row), do: ""

  defp system_name(row, opts), do: escape(system(row, Keyword.get(opts, :systems) || %{}))

  # ---------------------------------------------------------------------
  # Chrome
  # ---------------------------------------------------------------------

  defp header(board, count), do: "**#{label(board)} · #{count}**"

  defp label(:unanchored), do: "🚨 Unanchored"
  defp label(:timers), do: "⏳ Timers running"
  defp label(:anchoring), do: "🔧 Anchoring"
  defp label(:unanchoring), do: "📦 Unanchoring"
  defp label(:abandoned), do: "💀 Abandoned / no fuel"
  defp label(:spawns), do: "⭐ Spawns, last 24h"

  defp empty(:spawns), do: "_Nothing in the last 24 hours._"
  defp empty(_board), do: "_Nothing on this board._"

  # Angle brackets suppress Discord's link preview: this is a reference,
  # not the point of the message.
  defp footer(opts) do
    case Keyword.get(opts, :url) do
      url when is_binary(url) and url != "" -> "<#{url}>"
      _ -> ""
    end
  end

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
