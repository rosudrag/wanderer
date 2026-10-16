defmodule WandererAppWeb.ScoutDiscordTest do
  @moduledoc """
  The paste box's format, which has exactly two ways to be wrong in a way
  nobody notices until a fleet misses a timer:

    * **over 2000 characters** — Discord rejects the whole message rather
      than cutting it, so a part that crosses the limit cannot be posted
      at all; and
    * **a missing row** — a reader cannot tell "nothing else is
      happening" from "the rest did not fit", so nothing is dropped: a
      busy board becomes several parts, each inside the budget.

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

  # Every part, as the reader sees them pasted in order.
  defp text(%{parts: parts}), do: Enum.join(parts, "\n")

  test "a timer goes out as Discord's own live markup, in both styles" do
    unix = DateTime.to_unix(@expires)

    text = text(ScoutDiscord.message(:timers, [structure()], opts()))

    assert text =~ "<t:#{unix}:R>"
    assert text =~ "<t:#{unix}:f>"
    # Our own rendering of the same instant would freeze at paste time.
    refute text =~ "2h 30m"
  end

  test "the system is the page's resolved name, not the id the client logged" do
    text = text(ScoutDiscord.message(:timers, [structure()], opts()))

    assert text =~ "Jita"
    refute text =~ "30000142"
  end

  # Asked for 2026-10-16: the paste goes into a channel this private
  # deployment's readers cannot all log into, so it carries rows and
  # nothing else.
  test "no link back to this deployment, whatever the caller passes" do
    text =
      text(
        ScoutDiscord.message(
          :timers,
          [structure()],
          Keyword.put(opts(), :url, "https://evea.chewytech.com/scout")
        )
      )

    refute text =~ "http"
    refute text =~ "chewytech"
  end

  test "an unanchoring row carries the derived 7-day bound, marked as a bound" do
    row =
      structure(%{
        status: "Unanchoring",
        timer_expires_at: nil,
        unanchoring_since: ~U[2026-10-03 18:00:00Z]
      })

    text = text(ScoutDiscord.message(:unanchoring, [row], opts()))

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

    text = text(ScoutDiscord.message(:unanchoring, [row], opts()))

    assert text =~ "no estimate"
    refute text =~ "≤"
  end

  test "markdown in an EVE name is escaped, not rendered" do
    text =
      text(
        ScoutDiscord.message(:timers, [structure(%{structure_name: "*** |LOOT| ***"})], opts())
      )

    assert text =~ "\\*\\*\\* \\|LOOT\\| \\*\\*\\*"
  end

  test "a newline in a name cannot split one finding into two bullets" do
    text =
      text(ScoutDiscord.message(:timers, [structure(%{structure_name: "Line\nBreak"})], opts()))

    assert text =~ "Line Break"
    assert length(String.split(text, "•")) == 2
  end

  # Asked for 2026-10-06: "the discord copy paste doesnt need the 'last
  # seen'". These boards only ever carry structures the feed is still
  # confirming, so the stamp read "a few minutes ago" on every row and
  # spent budget saying nothing.
  test "the standing-opportunity boards carry no last-seen stamp" do
    seen_unix = DateTime.to_unix(~U[2026-10-05 17:43:00Z])

    for board <- [:unanchored, :abandoned, :no_fuel] do
      text = text(ScoutDiscord.message(board, [structure()], opts()))

      assert text =~ "Sosala Fortizar"
      refute text =~ "seen "
      refute text =~ "<t:#{seen_unix}:R>"
    end
  end

  # Abandoned (asset safety off) and NoFuel (low power) are two errands,
  # so they are two boards with two headings rather than one labelled
  # "Abandoned / no fuel".
  test "abandoned and no-fuel are separate boards with their own headings" do
    abandoned =
      text(ScoutDiscord.message(:abandoned, [structure(%{status: "Abandoned"})], opts()))

    no_fuel = text(ScoutDiscord.message(:no_fuel, [structure(%{status: "NoFuel"})], opts()))

    assert abandoned =~ "Abandoned · 1"
    refute abandoned =~ "No fuel"
    assert no_fuel =~ "No fuel · 1"
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

    test "a board too big for one message is split, and keeps every row", %{rows: rows} do
      %{parts: parts, total: total} = message = ScoutDiscord.message(:timers, rows, opts())

      assert total == 400
      assert length(parts) > 1
      assert Enum.all?(parts, &(String.length(&1) <= ScoutDiscord.limit()))

      # Every row, not a fitted prefix — and no claim that rows were cut.
      text = text(message)
      assert length(String.split(text, "•")) == 401
      assert text =~ "**Structure 1**"
      assert text =~ "**Structure 400**"
      refute text =~ "not shown"
    end

    test "a part that opens mid-board still says which board it is", %{rows: rows} do
      %{parts: [_first | [second | _rest]]} = ScoutDiscord.message(:timers, rows, opts())

      assert String.starts_with?(second, "**⏳ Timers running · 400** _(cont.)_")
    end

    test "the digest splits too, keeping urgency order and every board", %{rows: rows} do
      %{parts: parts, total: total} =
        message =
        ScoutDiscord.message(
          :digest,
          [{:unanchored, Enum.take(rows, 50)}, {:timers, rows}, {:abandoned, rows}],
          opts()
        )

      assert total == 850
      assert Enum.all?(parts, &(String.length(&1) <= ScoutDiscord.limit()))

      text = text(message)
      # The rarest finding leads, and nothing falls off the end.
      assert :binary.match(text, "Unanchored") < :binary.match(text, "Timers running")
      assert :binary.match(text, "Timers running") < :binary.match(text, "Abandoned")
      assert length(String.split(text, "•")) == 851
    end

    test "an empty board is a sentence, not a bare heading" do
      %{parts: [only], total: 0} = ScoutDiscord.message(:timers, [], opts())

      assert only =~ "Timers running · 0"
      assert only =~ "Nothing on this board."
    end
  end

  describe "parse_board/1" do
    test "accepts the boards the page renders" do
      for board <- ~w(unanchored timers anchoring unanchoring abandoned no_fuel spawns digest) do
        assert {:ok, _atom} = ScoutDiscord.parse_board(board)
      end
    end

    test "refuses anything else rather than creating an atom from user input" do
      assert :error = ScoutDiscord.parse_board("not_a_board")
      assert :error = ScoutDiscord.parse_board(nil)
    end
  end
end
