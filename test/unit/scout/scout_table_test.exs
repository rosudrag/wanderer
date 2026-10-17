defmodule WandererAppWeb.ScoutTableTest do
  @moduledoc """
  Per-column sort and filter on `/scout`.

  The things that can silently go wrong here, and are therefore what
  this file pins:

    * **a sort that promotes "unknown"** — every structure board has rows
      with no deadline and no last-seen, and a descending sort that puts
      them first claims the most urgent thing on the board is the row
      nobody has measured;
    * **a filter that means something different per column type** — a
      reader types `>10` in a number column and `<2h` in a time column,
      and the same code path has to answer both without the column
      declaring its type;
    * **a third sort click that strands the reader** — the page's own
      order (deadline first, newest first) is not reachable from a
      dropdown, so the cycle has to return to it; and
    * **a dropdown that forgets the value it is filtering on** — options
      are computed BEFORE the filter runs, or picking one empties the
      select that would let you pick another.
  """

  use ExUnit.Case, async: true

  alias WandererAppWeb.ScoutTable

  @now ~U[2026-10-17 12:00:00Z]

  defp ctx, do: %{now: @now}

  defp cols do
    [
      ScoutTable.col("name", "Structure", value: fn row, _ctx -> row.name end),
      ScoutTable.col("status", "Status", select?: true, value: fn row, _ctx -> row.status end),
      ScoutTable.col("value", "Value", value: fn row, _ctx -> row.value end),
      ScoutTable.col("seen", "Seen", value: fn row, _ctx -> row.seen end),
      ScoutTable.col("actions", "", class: "w-10")
    ]
  end

  defp rows do
    [
      %{name: "Astrahus Alpha", status: :seen, value: 10.0, seen: shift(-600)},
      %{name: "Fortizar Beta", status: :missing, value: 2.5, seen: shift(-7_200)},
      %{name: "astrahus gamma", status: :seen, value: nil, seen: nil},
      %{name: "Raitaru Delta", status: :gone, value: 100.0, seen: shift(-864_000)}
    ]
  end

  defp shift(seconds), do: DateTime.add(@now, seconds, :second)

  defp run(state, rows \\ nil) do
    {rows, meta} = ScoutTable.apply(rows || rows(), "t", cols(), state, ctx())
    {Enum.map(rows, & &1.name), meta}
  end

  describe "a column with no value" do
    test "offers neither control, which is what the action cells want" do
      col = ScoutTable.col("actions", "", class: "w-10")

      refute col.sort?
      refute col.filter?
    end
  end

  describe "sorting" do
    test "is the page's own order until a reader asks for one" do
      {names, _meta} = run(ScoutTable.new())

      assert names == ["Astrahus Alpha", "Fortizar Beta", "astrahus gamma", "Raitaru Delta"]
    end

    test "text sorts case-insensitively, because the data is user-entered" do
      state = ScoutTable.toggle_sort(ScoutTable.new(), "t", "name")
      {names, _meta} = run(state)

      assert names == ["Astrahus Alpha", "astrahus gamma", "Fortizar Beta", "Raitaru Delta"]
    end

    test "numbers sort as numbers, never as the strings they render to" do
      state = ScoutTable.toggle_sort(ScoutTable.new(), "t", "value")
      {names, _meta} = run(state)

      # 2.5 < 10.0 < 100.0 -- lexically it would be "10.0", "100.0", "2.5".
      assert names == ["Fortizar Beta", "Astrahus Alpha", "Raitaru Delta", "astrahus gamma"]
    end

    test "nils stay last in BOTH directions" do
      asc = ScoutTable.toggle_sort(ScoutTable.new(), "t", "value")
      desc = ScoutTable.toggle_sort(asc, "t", "value")

      {asc_names, _meta} = run(asc)
      {desc_names, _meta} = run(desc)

      assert List.last(asc_names) == "astrahus gamma"
      assert List.last(desc_names) == "astrahus gamma"
      assert desc_names == ["Raitaru Delta", "Astrahus Alpha", "Fortizar Beta", "astrahus gamma"]
    end

    test "timestamps sort chronologically" do
      state = ScoutTable.toggle_sort(ScoutTable.new(), "t", "seen")
      {names, _meta} = run(state)

      assert names == ["Raitaru Delta", "Fortizar Beta", "Astrahus Alpha", "astrahus gamma"]
    end

    test "a third click restores the page's own order" do
      state =
        ScoutTable.new()
        |> ScoutTable.toggle_sort("t", "name")
        |> ScoutTable.toggle_sort("t", "name")

      assert ScoutTable.sort_for(state, "t") == {"name", :desc}

      state = ScoutTable.toggle_sort(state, "t", "name")

      assert ScoutTable.sort_for(state, "t") == nil
      refute ScoutTable.touched?(state, "t")
    end

    test "a different column starts over, ascending" do
      state =
        ScoutTable.new()
        |> ScoutTable.toggle_sort("t", "name")
        |> ScoutTable.toggle_sort("t", "name")
        |> ScoutTable.toggle_sort("t", "value")

      assert ScoutTable.sort_for(state, "t") == {"value", :asc}
    end

    test "one table's sort never reaches another" do
      state = ScoutTable.toggle_sort(ScoutTable.new(), "other", "name")

      assert ScoutTable.sort_for(state, "t") == nil
      {names, _meta} = run(state)
      assert names == Enum.map(rows(), & &1.name)
    end
  end

  describe "filtering" do
    test "text is a case-insensitive substring" do
      state = ScoutTable.put_filter(ScoutTable.new(), "t", "name", "astrahus")
      {names, meta} = run(state)

      assert names == ["Astrahus Alpha", "astrahus gamma"]
      assert meta.total == 4
      assert meta.shown == 2
    end

    test "an atom column filters on the word the badge shows" do
      state = ScoutTable.put_filter(ScoutTable.new(), "t", "status", "seen")
      {names, _meta} = run(state)

      assert names == ["Astrahus Alpha", "astrahus gamma"]
    end

    test "numbers take comparisons" do
      assert {["Raitaru Delta"], _meta} =
               run(ScoutTable.put_filter(ScoutTable.new(), "t", "value", ">10"))

      assert {["Astrahus Alpha", "Raitaru Delta"], _meta} =
               run(ScoutTable.put_filter(ScoutTable.new(), "t", "value", ">=10"))

      assert {["Fortizar Beta"], _meta} =
               run(ScoutTable.put_filter(ScoutTable.new(), "t", "value", "<10"))

      assert {["Astrahus Alpha"], _meta} =
               run(ScoutTable.put_filter(ScoutTable.new(), "t", "value", "=10"))
    end

    test "a number column with no comparison falls back to a substring" do
      {names, _meta} = run(ScoutTable.put_filter(ScoutTable.new(), "t", "value", "100"))

      assert names == ["Raitaru Delta"]
    end

    test "times filter by age, and a running timer is negative" do
      assert {["Astrahus Alpha"], _meta} =
               run(ScoutTable.put_filter(ScoutTable.new(), "t", "seen", "<1h"))

      assert {["Fortizar Beta", "Raitaru Delta"], _meta} =
               run(ScoutTable.put_filter(ScoutTable.new(), "t", "seen", ">1h"))

      assert {["Raitaru Delta"], _meta} =
               run(ScoutTable.put_filter(ScoutTable.new(), "t", "seen", ">7d"))

      future = [%{name: "Running", status: :seen, value: 1.0, seen: shift(3_600)}]

      assert {["Running"], _meta} =
               run(ScoutTable.put_filter(ScoutTable.new(), "t", "seen", "<0m"), future)
    end

    test "a nil value matches nothing a reader typed" do
      {names, _meta} = run(ScoutTable.put_filter(ScoutTable.new(), "t", "seen", ">1h"))

      refute "astrahus gamma" in names
    end

    test "two columns narrow together" do
      state =
        ScoutTable.new()
        |> ScoutTable.put_filter("t", "name", "a")
        |> ScoutTable.put_filter("t", "status", "seen")

      {names, _meta} = run(state)

      assert names == ["Astrahus Alpha", "astrahus gamma"]
    end

    test "a blank value removes the filter rather than storing one" do
      state =
        ScoutTable.new()
        |> ScoutTable.put_filter("t", "name", "astrahus")
        |> ScoutTable.put_filter("t", "name", "  ")

      refute ScoutTable.touched?(state, "t")
      assert ScoutTable.filter_for(state, "t", "name") == ""
      assert {names, _meta} = run(state)
      assert length(names) == 4
    end

    test "a filter naming a column this table does not have is ignored" do
      state = ScoutTable.put_filter(ScoutTable.new(), "t", "nonsense", "x")
      {names, _meta} = run(state)

      assert length(names) == 4
    end

    test "a presentation column cannot be filtered even if a value is posted" do
      state = ScoutTable.put_filter(ScoutTable.new(), "t", "actions", "anything")
      {names, _meta} = run(state)

      assert length(names) == 4
    end

    test "clear drops this table's filters and its sort, and only this table's" do
      state =
        ScoutTable.new()
        |> ScoutTable.put_filter("t", "name", "astrahus")
        |> ScoutTable.toggle_sort("t", "value")
        |> ScoutTable.put_filter("other", "name", "keep")

      state = ScoutTable.clear(state, "t")

      refute ScoutTable.touched?(state, "t")
      assert ScoutTable.touched?(state, "other")
    end
  end

  describe "the filter controls the header draws" do
    test "a column declared a vocabulary becomes a dropdown of what is there" do
      {_rows, meta} = run(ScoutTable.new())

      assert meta.options["status"] == ["gone", "missing", "seen"]
      assert meta.types["status"] == :text
    end

    test "an undeclared column stays a box however few values it holds" do
      {_rows, meta} = run(ScoutTable.new())

      # Four rows, four distinct names -- well under the cap. A control
      # that turns into a dropdown because today's window is small, and
      # back into a box tomorrow, is a control nobody can learn.
      assert meta.options["name"] == []
      assert meta.types["name"] == :text
    end

    test "numbers and timestamps are never a dropdown, declared or not" do
      cols = [ScoutTable.col("value", "Value", select?: true, value: fn row, _ -> row.value end)]
      {_rows, meta} = ScoutTable.apply(rows(), "t", cols, ScoutTable.new(), ctx())

      assert meta.options["value"] == []
      assert meta.types["value"] == :number

      {_rows, meta} = run(ScoutTable.new())
      assert meta.types["seen"] == :time
      assert meta.options["seen"] == []
    end

    test "a declared vocabulary that overflows the cap falls back to a box" do
      cols = [ScoutTable.col("name", "Name", select?: true, value: fn row, _ -> row.name end)]
      many = for n <- 1..40, do: %{name: "S#{n}", status: :seen, value: 1.0, seen: @now}
      {_rows, meta} = ScoutTable.apply(many, "t", cols, ScoutTable.new(), ctx())

      assert meta.options["name"] == []
    end

    test "options are computed before the filter, so the select can still be changed" do
      state = ScoutTable.put_filter(ScoutTable.new(), "t", "status", "gone")
      {names, meta} = run(state)

      assert names == ["Raitaru Delta"]
      assert meta.options["status"] == ["gone", "missing", "seen"]
    end

    test "a presentation column is described to nobody" do
      {_rows, meta} = run(ScoutTable.new())

      refute Map.has_key?(meta.options, "actions")
    end
  end
end
