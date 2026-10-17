defmodule WandererAppWeb.ScoutTable do
  @moduledoc """
  CHEWY PATCH: per-column sort and per-column filter for every table on
  `/scout`.

  Every board on these pages is a list of places to go, and the only
  orders the page offered were the two the LiveView assigned
  (`by_deadline/1`, `by_recent/1`) with one page-wide text box across
  them. "Show me only Astrahus hulls", "sort the sweep by jumps", "which
  of these is in Delve" were all re-reads of the whole table by eye.

  The mechanism is deliberately small and runs in the BEAM, over rows the
  socket ALREADY holds:

    * A **column spec** (`col/3`) names the column and, crucially, how to
      get ONE comparable value out of a row. That value is what both the
      sort and the filter read, so a column can never sort by one thing
      and filter by another.

    * `apply/5` filters, then sorts, then reports the distinct values it
      saw. No query, no read action, no second copy of the rows.

    * State lives in the socket (`new/0` plus the three `handle_*`
      helpers) and is NOT persisted, exactly like the board solo chip:
      a sort is "for the next thirty seconds", a stored one is a page
      that opens in a shape nobody asked for.

  ## What a filter string means

  The value's TYPE decides, so a reader never configures anything:

    * text (`"Astrahus"`, `:seen`) — case-insensitive substring. A
      column with few enough distinct values renders a `<select>`
      instead of a box (see `options/3`); an exact pick is still a
      substring match, so the two agree by construction.
    * number (`42`, `1.5`) — `>`, `>=`, `<`, `<=`, `=` with a number
      (`>10`), or a bare string which falls back to a substring match on
      the rendered number.
    * `DateTime` — an AGE comparison against `ctx.now`: `<2h` is
      "younger than two hours", `>7d` is "older than a week"
      (`m`/`h`/`d`). A future timestamp — every reinforcement timer —
      has a negative age, so `<0m` is "still running". Anything else
      falls back to a substring match on the rendered timestamp.

  Nils are always last, in both directions: a row with no deadline is
  not "the soonest" when you sort by deadline descending.
  """

  defmodule Col do
    @moduledoc """
    One column: its key (stable, used in the sort/filter events), its
    header label, and `value/2` — the single accessor both the sort and
    the filter read.

    A column with no `value` is a presentation column (the archive
    button, the `⤳` cell) and is neither sortable nor filterable.
    """

    @type t :: %__MODULE__{}

    defstruct [
      :key,
      :label,
      :value,
      :class,
      :title,
      sort?: false,
      filter?: false,
      select?: false
    ]
  end

  @max_options 12
  @max_filter_length 100

  @time_re ~r/^(<=|>=|<|>)\s*(\d+(?:\.\d+)?)\s*([mhd])$/
  @number_re ~r/^(<=|>=|<|>|=)?\s*(-?\d+(?:\.\d+)?)$/

  @doc """
  Build one column.

  `value` is a 2-arity function `(row, ctx)` returning the comparable:
  a string, an atom, a number, a `DateTime`, or `nil`. Pass none and the
  column is inert (no sort control, no filter box) — which is what the
  action columns want.

  Options: `:value`, `:class` (the `<th>`'s classes, carried to the
  filter row so the columns stay aligned), `:title`, `:sort?` /
  `:filter?` to switch one half off for a column that has a value but
  should not offer both, and `:select?` for a column whose values are a
  fixed VOCABULARY (status, presence, outcome, leg) — those render as a
  dropdown of the values actually present.

  `:select?` is declared, never inferred from cardinality: a filter box
  that turns into a dropdown because this window happens to hold eight
  rows, and back into a box tomorrow, is a control that changes shape
  under the reader. A structure name is free text at any row count.
  """
  @spec col(String.t(), String.t(), keyword()) :: Col.t()
  def col(key, label, opts \\ []) do
    value = Keyword.get(opts, :value)
    has_value? = is_function(value, 2)

    %Col{
      key: key,
      label: label,
      value: value,
      class: Keyword.get(opts, :class),
      title: Keyword.get(opts, :title),
      sort?: Keyword.get(opts, :sort?, has_value?),
      filter?: Keyword.get(opts, :filter?, has_value?),
      select?: Keyword.get(opts, :select?, false)
    }
  end

  # -------------------------------------------------------------------
  # State
  # -------------------------------------------------------------------

  @doc "The empty state: no table sorted, no column filtered."
  @spec new() :: map()
  def new, do: %{sorts: %{}, filters: %{}}

  @doc "The sort on one table, as `{column_key, :asc | :desc}` or nil."
  @spec sort_for(map(), String.t()) :: {String.t(), :asc | :desc} | nil
  def sort_for(state, table), do: Map.get(state.sorts, table)

  @doc "The filter string on one column, `\"\"` when unset."
  @spec filter_for(map(), String.t(), String.t()) :: String.t()
  def filter_for(state, table, key) do
    state.filters |> Map.get(table, %{}) |> Map.get(key, "")
  end

  @doc "Does this table carry any sort or filter the reader set?"
  @spec touched?(map(), String.t()) :: boolean()
  def touched?(state, table) do
    Map.has_key?(state.sorts, table) or Map.get(state.filters, table, %{}) != %{}
  end

  @doc """
  Cycle one column's sort: unsorted -> ascending -> descending ->
  unsorted, which is how a reader gets the page's own order back without
  knowing what it was.
  """
  @spec toggle_sort(map(), String.t(), String.t()) :: map()
  def toggle_sort(state, table, key) do
    sorts =
      case Map.get(state.sorts, table) do
        {^key, :asc} -> Map.put(state.sorts, table, {key, :desc})
        {^key, :desc} -> Map.delete(state.sorts, table)
        _other -> Map.put(state.sorts, table, {key, :asc})
      end

    %{state | sorts: sorts}
  end

  @doc """
  Set one column's filter. A blank value removes it rather than storing
  an empty string, so `touched?/2` stays honest and the "clear" chip
  disappears on its own.
  """
  @spec put_filter(map(), String.t(), String.t(), String.t()) :: map()
  def put_filter(state, table, key, value) do
    value = value |> to_string() |> String.slice(0, @max_filter_length) |> String.trim()

    columns =
      case value do
        "" -> state.filters |> Map.get(table, %{}) |> Map.delete(key)
        term -> state.filters |> Map.get(table, %{}) |> Map.put(key, term)
      end

    filters =
      if columns == %{} do
        Map.delete(state.filters, table)
      else
        Map.put(state.filters, table, columns)
      end

    %{state | filters: filters}
  end

  @doc "Drop every filter and the sort on one table."
  @spec clear(map(), String.t()) :: map()
  def clear(state, table) do
    %{state | sorts: Map.delete(state.sorts, table), filters: Map.delete(state.filters, table)}
  end

  # -------------------------------------------------------------------
  # Applying it
  # -------------------------------------------------------------------

  @doc """
  Filter, then sort, then report.

  Returns `{rows, meta}` where `meta` carries `:total` (rows in),
  `:shown` (rows out) and `:options` (the distinct rendered values per
  column, computed over the rows BEFORE filtering so a `<select>` can
  still offer the value you just filtered away).
  """
  @spec apply(list(), String.t(), [Col.t()], map(), map()) :: {list(), map()}
  def apply(rows, table, cols, state, ctx) do
    filters = Map.get(state.filters, table, %{})
    by_key = Map.new(cols, &{&1.key, &1})

    filtered =
      Enum.reduce(filters, rows, fn {key, term}, acc ->
        case Map.get(by_key, key) do
          %Col{filter?: true} = col -> Enum.filter(acc, &matches?(col.value.(&1, ctx), term, ctx))
          _other -> acc
        end
      end)

    sorted =
      case Map.get(state.sorts, table) do
        {key, dir} ->
          case Map.get(by_key, key) do
            %Col{sort?: true} = col -> sort(filtered, col, dir, ctx)
            _other -> filtered
          end

        nil ->
          filtered
      end

    {sorted, Map.merge(describe(rows, cols, ctx), %{total: length(rows), shown: length(sorted)})}
  end

  @doc """
  What the header component needs to draw a filter control for each
  column, computed over the rows BEFORE filtering:

    * `:options` — for a column DECLARED `select?: true`, the distinct
      values actually present, so the dropdown offers this board's
      vocabulary and nothing else. Every other column gets `[]`, which
      is the header's signal to render a box. A declared select whose
      values overflow the cap also falls back to a box rather than a
      wall of options.
    * `:types` — `:text`, `:number` or `:time`, which is the only thing
      that decides what the box's placeholder tells the reader to type.
  """
  @spec describe(list(), [Col.t()], map()) :: %{options: map(), types: map()}
  def describe(rows, cols, ctx) do
    cols
    |> Enum.filter(& &1.filter?)
    |> Enum.reduce(%{options: %{}, types: %{}}, fn col, acc ->
      values = Enum.map(rows, &col.value.(&1, ctx))
      type = type_of(values)

      options =
        if col.select? and type == :text do
          distinct = values |> Enum.map(&text/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
          if length(distinct) <= @max_options, do: Enum.sort(distinct), else: []
        else
          []
        end

      %{
        options: Map.put(acc.options, col.key, options),
        types: Map.put(acc.types, col.key, type)
      }
    end)
  end

  defp type_of(values) do
    Enum.reduce_while(values, :text, fn
      nil, acc -> {:cont, acc}
      %DateTime{}, _acc -> {:halt, :time}
      value, _acc when is_number(value) -> {:halt, :number}
      _value, acc -> {:cont, acc}
    end)
  end

  @doc """
  The value one column reads out of one row, as the string the filter
  and the `<select>` both compare against. Public because the render
  test asserts the two agree.
  """
  @spec text(term()) :: String.t()
  def text(nil), do: ""
  def text(value) when is_binary(value), do: value
  def text(value) when is_atom(value), do: to_string(value)
  def text(value) when is_integer(value), do: Integer.to_string(value)

  def text(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 2])

  def text(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M")
  def text(%Date{} = value), do: Date.to_iso8601(value)
  def text(value), do: to_string(value)

  # -------------------------------------------------------------------
  # Filtering
  # -------------------------------------------------------------------

  defp matches?(value, term, ctx) do
    cond do
      match?(%DateTime{}, value) -> time_matches?(value, term, ctx)
      is_number(value) -> number_matches?(value, term)
      true -> substring?(text(value), term)
    end
  end

  defp substring?(text, term) do
    String.contains?(String.downcase(text), String.downcase(term))
  end

  defp number_matches?(value, term) do
    case Regex.run(@number_re, String.trim(term)) do
      [_all, op, number | _rest] -> compare(value, parse_number(number), op)
      _no_match -> substring?(text(value), term)
    end
  end

  # The age, in seconds, of a stored timestamp: positive in the past,
  # negative for a running timer. `<2h` therefore reads the same way on
  # both kinds of column -- "inside two hours of now".
  defp time_matches?(%DateTime{} = at, term, ctx) do
    case Regex.run(@time_re, String.trim(term)) do
      [_all, op, number, unit] ->
        now = Map.get(ctx, :now) || DateTime.utc_now()
        compare(DateTime.diff(now, at, :second), parse_number(number) * unit_seconds(unit), op)

      _no_match ->
        substring?(text(at), term)
    end
  end

  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3_600
  defp unit_seconds("d"), do: 86_400

  defp parse_number(string) do
    case Float.parse(string) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp compare(left, right, ">"), do: left > right
  defp compare(left, right, ">="), do: left >= right
  defp compare(left, right, "<"), do: left < right
  defp compare(left, right, "<="), do: left <= right
  defp compare(left, right, _eq), do: left == right

  # -------------------------------------------------------------------
  # Sorting
  # -------------------------------------------------------------------

  defp sort(rows, %Col{} = col, dir, ctx) do
    Enum.sort_by(rows, &col.value.(&1, ctx), &compare_values(&1, &2, dir))
  end

  # Nils last in BOTH directions: a structure with no deadline is not
  # the most urgent thing on the board just because the sort flipped.
  defp compare_values(nil, nil, _dir), do: true
  defp compare_values(nil, _right, _dir), do: false
  defp compare_values(_left, nil, _dir), do: true

  defp compare_values(left, right, dir) do
    case order(left, right) do
      :lt -> dir == :asc
      :gt -> dir == :desc
      :eq -> true
    end
  end

  defp order(%DateTime{} = left, %DateTime{} = right), do: DateTime.compare(left, right)
  defp order(%Date{} = left, %Date{} = right), do: Date.compare(left, right)

  defp order(left, right) when is_number(left) and is_number(right) do
    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  defp order(left, right) do
    left = left |> text() |> String.downcase()
    right = right |> text() |> String.downcase()

    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end
end
