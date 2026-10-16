defmodule WandererAppWeb.ScoutLayoutTest do
  @moduledoc """
  Where a `/scout` panel sits, and the three ways that can go wrong
  without anybody noticing:

    * **a move that leaves the stack** — the mechanism is CSS `order:` on
      one flex column, so a panel that "moved" into another container
      would report success and render exactly where it was;
    * **a stored order that outlives the board it names** — localStorage
      is user-writable and a deploy adds and removes boards, so a blob is
      a preference, never the schema; and
    * **a board added by a deploy** — it has to land where the template
      puts it, not at the bottom of every existing reader's saved stack,
      which is the one place nobody looks.
  """

  use ExUnit.Case, async: true

  alias WandererAppWeb.ScoutLayout

  @stacks %{
    "structures" => ~w(now unanchored timers log),
    "spawns" => ~w(fresh spawn_log)
  }

  defp layout, do: ScoutLayout.new("scout_layout", @stacks)

  defp order(layout, stack), do: layout.order[stack]

  describe "defaults" do
    test "renders the template's own order" do
      assert order(layout(), "structures") == ~w(now unanchored timers log)
      assert ScoutLayout.index(layout(), "timers") == 2
      assert ScoutLayout.style(layout(), "timers") == "order:2"
    end

    test "a panel this page does not own has no order at all" do
      assert ScoutLayout.index(layout(), "region_heat") == nil
      assert ScoutLayout.style(layout(), "region_heat") == nil
      refute ScoutLayout.movable?(layout(), "region_heat")
    end

    test "nothing is collapsed and nothing is customised" do
      refute ScoutLayout.collapsed?(layout(), "now")
      refute ScoutLayout.customised?(layout())
    end
  end

  describe "move/3" do
    test "swaps with the neighbour inside its own stack" do
      moved = ScoutLayout.move(layout(), "timers", "up")

      assert order(moved, "structures") == ~w(now timers unanchored log)
      assert order(moved, "spawns") == ~w(fresh spawn_log)
    end

    test "the ends are hard stops, not wraps" do
      top = ScoutLayout.move(layout(), "now", "up")
      bottom = ScoutLayout.move(layout(), "log", "down")

      assert order(top, "structures") == ~w(now unanchored timers log)
      assert order(bottom, "structures") == ~w(now unanchored timers log)
      assert ScoutLayout.first?(layout(), "now")
      assert ScoutLayout.last?(layout(), "log")
    end

    test "a stack of one cannot be reordered, so it renders no arrows" do
      single = ScoutLayout.new("k", %{"only" => ~w(heat)})

      refute ScoutLayout.movable?(single, "heat")
      assert ScoutLayout.movable?(layout(), "now")
    end
  end

  describe "drop/4" do
    test "before and after place the panel on either side of the target" do
      before = ScoutLayout.drop(layout(), "log", "unanchored", "before")
      after_ = ScoutLayout.drop(layout(), "now", "timers", "after")

      assert order(before, "structures") == ~w(now log unanchored timers)
      assert order(after_, "structures") == ~w(unanchored timers now log)
    end

    test "a drop onto another stack is refused, because order cannot cross a container" do
      crossed = ScoutLayout.drop(layout(), "log", "fresh", "before")

      assert order(crossed, "structures") == ~w(now unanchored timers log)
      assert order(crossed, "spawns") == ~w(fresh spawn_log)
    end

    test "a drop onto itself changes nothing" do
      same = ScoutLayout.drop(layout(), "now", "now", "after")

      assert order(same, "structures") == ~w(now unanchored timers log)
    end
  end

  describe "collapse" do
    test "toggles one panel and reports it" do
      collapsed = ScoutLayout.toggle(layout(), "log")

      assert ScoutLayout.collapsed?(collapsed, "log")
      refute ScoutLayout.collapsed?(collapsed, "now")
      assert ScoutLayout.customised?(collapsed)
      refute ScoutLayout.collapsed?(ScoutLayout.toggle(collapsed, "log"), "log")
    end

    test "collapse all takes every stack, expand all takes none" do
      all = ScoutLayout.collapse_all(layout(), true)

      for key <- ~w(now unanchored timers log fresh spawn_log) do
        assert ScoutLayout.collapsed?(all, key)
      end

      refute ScoutLayout.collapsed?(ScoutLayout.collapse_all(all, false), "now")
    end

    test "reset puts the order back and opens everything" do
      messed =
        layout()
        |> ScoutLayout.move("log", "up")
        |> ScoutLayout.toggle("now")
        |> ScoutLayout.reset()

      assert order(messed, "structures") == ~w(now unanchored timers log)
      refute ScoutLayout.collapsed?(messed, "now")
      refute ScoutLayout.customised?(messed)
    end
  end

  describe "restore/2" do
    test "a round trip through localStorage is the same layout" do
      saved =
        layout()
        |> ScoutLayout.move("log", "up")
        |> ScoutLayout.toggle("timers")

      restored = ScoutLayout.restore(layout(), ScoutLayout.encode(saved))

      assert restored.order == saved.order
      assert restored.collapsed == saved.collapsed
    end

    test "a first visit, a corrupt blob and a blob of the wrong shape all keep the defaults" do
      for value <- [nil, "not json", "[]", ~s({"order": "structures"})] do
        assert ScoutLayout.restore(layout(), value).order == @stacks
      end
    end

    test "a board this build no longer renders is dropped" do
      stored =
        ~s({"order":{"structures":["log","hotspots","now","unanchored","timers"]},) <>
          ~s("collapsed":["hotspots","now"]})

      restored = ScoutLayout.restore(layout(), stored)

      assert order(restored, "structures") == ~w(log now unanchored timers)
      assert ScoutLayout.collapsed?(restored, "now")
      refute ScoutLayout.collapsed?(restored, "hotspots")
    end

    test "a board this build ADDED lands at its default position, not at the bottom" do
      # A reader whose stored order predates `unanchored` and `timers`
      # must still get them between `now` and `log`, where the template
      # puts them -- an alert appended under a 250-row log is an alert
      # nobody sees.
      stored = ~s({"order":{"structures":["now","log"]},"collapsed":[]})

      restored = ScoutLayout.restore(layout(), stored)

      assert order(restored, "structures") == ~w(now unanchored timers log)
    end

    test "a reordered stack still absorbs a new board after its default predecessor" do
      stored = ~s({"order":{"structures":["log","now"]},"collapsed":[]})

      restored = ScoutLayout.restore(layout(), stored)

      assert order(restored, "structures") == ~w(log now unanchored timers)
    end

    test "duplicates in a hand-edited blob collapse to one" do
      stored = ~s({"order":{"structures":["log","log","now"]},"collapsed":[]})

      restored = ScoutLayout.restore(layout(), stored)

      assert order(restored, "structures") == ~w(log now unanchored timers)
    end
  end
end
