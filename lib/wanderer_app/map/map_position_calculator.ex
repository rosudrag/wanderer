defmodule WandererApp.Map.PositionCalculator do
  @moduledoc """
  Finds a free grid cell to place a new system on the map.

  Normally this spiral-searches outward from the parent system (see
  `check_system_available_positions/5`), which packs chains into a dense
  blob. When `WandererApp.Env.tidy_insert?/0` is enabled, `get_new_system_position/3`
  instead prefers a cell one grid pitch away from the parent along the chain's
  primary axis (x for left_to_right, y for top_to_bottom), fanning out along the
  secondary axis for siblings before falling back to the original spiral search.
  See the `# CHEWY PATCH` block below for the geometry.
  """
  require Logger

  @ddrt Application.compile_env(:wanderer_app, :ddrt)

  # Node height
  @h 34
  # Node weight
  @w 130
  # Nodes margin
  @m_x 50
  @m_y 41

  @start_x 0
  @start_y 0

  # CHEWY PATCH: tidy-insert candidate geometry (WandererApp.Env.tidy_insert?/0).
  # Fan offsets tried on the secondary axis, closest-to-parent first, alternating sides.
  @tidy_fan [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6]
  # Primary-axis pitches tried, in order, before giving up and spiral-searching.
  @tidy_primary_offsets [1, 2]

  def get_system_bounding_rect(%{position_x: x, position_y: y} = _system) do
    [{x, x + @w}, {y, y + @h}]
  end

  def get_system_bounding_rect(_system), do: [{0, 0}, {0, 0}]

  def get_new_system_position(nil, rtree_name, opts) do
    {:ok, {x, y}} = rtree_name |> check_system_available_positions(@start_x, @start_y, 1, opts)
    %{x: x, y: y}
  end

  def get_new_system_position(
        %{position_x: start_x, position_y: start_y} = _old_system,
        rtree_name,
        opts
      ) do
    # CHEWY PATCH: direction-aware tidy insert, gated behind WandererApp.Env.tidy_insert?/0.
    if WandererApp.Env.tidy_insert?() do
      case tidy_insert_position(rtree_name, start_x, start_y, opts) do
        {:ok, {x, y}} ->
          %{x: x, y: y}

        :error ->
          {:ok, {x, y}} =
            rtree_name |> check_system_available_positions(start_x, start_y, 1, opts)

          %{x: x, y: y}
      end
    else
      {:ok, {x, y}} = rtree_name |> check_system_available_positions(start_x, start_y, 1, opts)

      %{x: x, y: y}
    end
  end

  # CHEWY PATCH: pure candidate generator for tidy insert, unit-testable without a live R-tree.
  # Candidates are ordered: primary pitch 1 with no fan, then primary pitch 1 fanned out on the
  # secondary axis (+1,-1,+2,-2,...,+6,-6), then the same fan at primary pitch 2.
  @doc false
  def tidy_insert_candidates(start_x, start_y, opts) do
    {{px, py}, {sx, sy}} = tidy_insert_axes(opts[:layout])

    for primary <- @tidy_primary_offsets, secondary <- @tidy_fan do
      {
        start_x + px * primary + sx * secondary,
        start_y + py * primary + sy * secondary
      }
    end
  end

  defp tidy_insert_axes("top_to_bottom"), do: {{0, @h + @m_y}, {@w + @m_x, 0}}
  # Default (including "left_to_right" and nil) grows along x.
  defp tidy_insert_axes(_layout), do: {{@w + @m_x, 0}, {0, @h + @m_y}}

  defp tidy_insert_position(rtree_name, start_x, start_y, opts) do
    start_x
    |> tidy_insert_candidates(start_y, opts)
    |> Enum.find(&is_available_position(&1, rtree_name))
    |> case do
      nil -> :error
      position -> {:ok, position}
    end
  end

  defp check_system_available_positions(_rtree_name, _start_x, _start_y, 100, _opts),
    do: {:ok, {@start_x, @start_y}}

  defp check_system_available_positions(rtree_name, start_x, start_y, level, opts) do
    possible_positions = get_available_positions(level, start_x, start_y, opts)

    case get_available_position(possible_positions, rtree_name) do
      {:ok, nil} ->
        rtree_name |> check_system_available_positions(start_x, start_y, level + 1, opts)

      {:ok, position} ->
        {:ok, position}
    end
  end

  defp get_available_position([], _rtree_name), do: {:ok, nil}

  defp get_available_position([position | rest], rtree_name) do
    if is_available_position(position, rtree_name) do
      {:ok, position}
    else
      get_available_position(rest, rtree_name)
    end
  end

  defp is_available_position({x, y} = _position, rtree_name) do
    case @ddrt.query(get_system_bounding_rect(%{position_x: x, position_y: y}), rtree_name) do
      {:ok, []} ->
        true

      {:ok, _} ->
        false

      _ ->
        true
    end
  end

  def get_available_positions(level, x, y, opts),
    do: adjusted_coordinates(1 + level * 2, x, y, opts)

  defp edge_coordinates(n, _opts) when n > 1 do
    min = -div(n, 2)
    max = div(n, 2)
    # Top edge
    top_edge = for x <- min..max, do: {x, min}
    # Right edge
    right_edge = for y <- min..max, do: {max, y}
    # Bottom edge
    bottom_edge = for x <- max..min, do: {x, max}
    # Left edge
    left_edge = for y <- max..min, do: {min, y}

    # Combine all edges in clockwise order
    (right_edge ++ bottom_edge ++ left_edge ++ top_edge)
    |> Enum.uniq()
  end

  defp sorted_edge_coordinates(n, opts) when n > 1 do
    coordinates = edge_coordinates(n, opts)
    start_index = get_start_index(n, opts[:layout])

    Enum.slice(coordinates, start_index, length(coordinates) - start_index) ++
      Enum.slice(coordinates, 0, start_index)
  end

  defp get_start_index(n, "left_to_right"), do: div(n, 2)

  defp get_start_index(n, "top_to_bottom"), do: div(n, 2) + n - 1

  # Default to left_to_right when layout is nil
  defp get_start_index(n, nil), do: div(n, 2)

  defp adjusted_coordinates(n, start_x, start_y, opts) when n > 1 do
    sorted_coords = sorted_edge_coordinates(n, opts)

    Enum.map(sorted_coords, fn {x, y} ->
      {
        start_x + x * (@w + @m_x),
        start_y + y * (@h + @m_y)
      }
    end)
  end
end
