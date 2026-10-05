defmodule WandererAppWeb.ScoutDiscordTest do
  @moduledoc """
  The paste box's format, which has exactly two ways to be wrong in a way
  nobody notices until a fleet misses a timer:

    * **over 2000 characters** — Discord rejects the whole message rather
      than cutting it, so a busy board would silently produce a paste
      that cannot be posted at all; and
    * **a silently short list** — a reader cannot tell "nothing else is
      happening" from "the rest did not fit", so a truncated message must
      say so, and the note saying so must itself be inside the budget.

  Plus the thing the feature exists for: a timer goes out as Discord's
  own `<t:unix:R>` markup, which keeps counting down in the channel, and
  never as our own frozen "2h 14m".
  """

  use ExUnit.Case, async: true

  alias WandererAppWeb.ScoutDiscord

  @now ~U[2026-10-05 18:00:00Z]
  @expires ~U[2026-10-05 20:30:00Z]

  defp structure(attrs \\ %{}) do
    Map.merge(
      %{
        structure_id: 1_040_000_001,
        structure_name: "Sosala Fortizar",
        group_name: "Citadel",
        owner_name: "Hard Knocks Inc.",
        status: "ArmorReinforced",
        solar_system_id: 30_000_142,
        solar_system_name: nil,
        nearest_celestial: "Jita IV - Moon 4",
        timer_expires_at: @expires,
        unanchoring_since: nil,
        last_confirmed_at: ~U[2026-10-05 17:43:00Z]
      },
      attrs
    )
  end

  defp opts, do: [systems: %{30_000_142 => %{solar_system_name: "Jita"}}, now: @now]

  test "a timer goes out as Discord's own live markup, in both styles" do
    unix = DateTime.to_unix(@expires)

    %{text: text} = ScoutDiscord.message(:timers, [structure()], opts())

    assert text =~ "<t:#{unix}:R>"
    assert text =~ "<t:#{unix}:f>"
    # Our own rendering of the same instant would freeze at paste time.
    refute text =~ "2h 30m"
  end

  test "the system is the page's resolved name, not the id the client logged" do
    %{text: text} = ScoutDiscord.message(:timers, [structure()], opts())

    assert text =~ "Jita"
    refute text =~ "30000142"
  end

  test "an unanchoring row carries the derived 7-day bound, marked as a bound" do
    row =
      structure(%{
        status: "Unanchoring",
        timer_expires_at: nil,
        unanchoring_since: ~U[2026-10-03 18:00:00Z]
      })

    %{text: text} = ScoutDiscord.message(:unanchoring, [row], opts())

    assert text =~ "≤ <t:#{DateTime.to_unix(~U[2026-10-10 18:00:00Z])}:R>"
  end

  test "an orbital, which has no honest bound, says so instead of predicting one" do
    row =
      structure(%{
        structure_name: "Jita IV - Moon 4 Customs Office",
        group_name: "Orbital Infrastructure",
        status: "Unanchoring",
        timer_expires_at: nil,
        unanchoring_since: ~U[2026-10-03 18:00:00Z]
      })

    %{text: text} = ScoutDiscord.message(:unanchoring, [row], opts())

    assert text =~ "no estimate"
    refute text =~ "≤"
  end

  test "markdown in an EVE name is escaped, not rendered" do
    %{text: text} =
      ScoutDiscord.message(:timers, [structure(%{structure_name: "*** |LOOT| ***"})], opts())

    assert text =~ "\\*\\*\\* \\|LOOT\\| \\*\\*\\*"
  end

  test "a newline in a name cannot split one finding into two bullets" do
    %{text: text} =
      ScoutDiscord.message(:timers, [structure(%{structure_name: "Line\nBreak"})], opts())

    assert text =~ "Line Break"
    assert length(String.split(text, "•")) == 2
  end

  describe "the 2000-character budget" do
    setup do
      rows =
        Enum.map(1..400, fn i ->
          structure(%{
            structure_id: 1_040_000_000 + i,
            structure_name: "Structure #{i}",
            timer_expires_at: DateTime.add(@expires, i * 60, :second)
          })
        end)

      %{rows: rows}
    end

    test "a board that cannot fit is cut to the limit and says how many it dropped", %{rows: rows} do
      %{text: text, shown: shown, total: total} = ScoutDiscord.message(:timers, rows, opts())

      assert String.length(text) <= ScoutDiscord.limit()
      assert shown < total
      assert total == 400
      assert text =~ "#{total - shown} more not shown"
    end

    test "the digest packs several boards and still fits", %{rows: rows} do
      %{text: text, shown: shown} =
        ScoutDiscord.message(
          :digest,
          [{:unanchored, Enum.take(rows, 50)}, {:timers, rows}, {:abandoned, rows}],
          opts()
        )

      assert String.length(text) <= ScoutDiscord.limit()
      assert shown > 0
      # Urgency order is kept: the rarest finding leads.
      assert :binary.match(text, "Unanchored") < :binary.match(text, "Timers running")
    end

    test "an empty board is a sentence, not a bare heading" do
      %{text: text, shown: 0, total: 0} = ScoutDiscord.message(:timers, [], opts())

      assert text =~ "Timers running · 0"
      assert text =~ "Nothing on this board."
    end
  end

  describe "parse_board/1" do
    test "accepts the boards the page renders" do
      for board <- ~w(unanchored timers anchoring unanchoring abandoned spawns digest) do
        assert {:ok, _atom} = ScoutDiscord.parse_board(board)
      end
    end

    test "refuses anything else rather than creating an atom from user input" do
      assert :error = ScoutDiscord.parse_board("not_a_board")
      assert :error = ScoutDiscord.parse_board(nil)
    end
  end
end
