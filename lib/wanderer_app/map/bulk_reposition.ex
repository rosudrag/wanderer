defmodule WandererApp.Map.BulkReposition do
  @moduledoc """
  Applies many solar system position updates to a map in a single call.

  The existing drag-and-drop path (`"update_system_position"` /
  `"update_system_positions"` UI events, see
  `WandererAppWeb.MapSystemsEventHandler`) drives every repositioned system
  through `WandererApp.Map.Server.update_system_position/2` unconditionally,
  regardless of whether the system actually moved. That is fine for a human
  dragging one or two nodes, but the map beautifier recomputes positions for
  an entire wormhole chain or region cluster at once (100+ systems), most of
  which end up exactly where they already were. Blindly recursing through the
  single-system path for the whole batch would mean 100+ redundant in-memory
  state writes, Ash `update_position` calls, R-tree updates, and
  `:update_system` broadcasts for systems that never actually changed.

  This module drives the exact same single-system pipeline
  (`WandererApp.Map.Server.SystemsImpl.update_system_position/2` ->
  `update_system/4` -> `WandererApp.Api.MapSystem.update_position` ->
  `Impl.broadcast!/3`) for every position in the batch, but first looks up
  each system's current in-memory position and skips any system that is not
  present on the map, or whose stored position already matches the requested
  one. Only systems that actually move pay for a DB write, R-tree update, and
  broadcast.

  Used exclusively by the map beautifier
  (`WandererApp.Env.map_beautifier?/0`-gated at the call site in
  `WandererAppWeb.MapSystemsEventHandler`); the existing single/bulk drag
  handlers are untouched.
  """

  require Logger

  @type position :: %{
          solar_system_id: integer(),
          position_x: integer(),
          position_y: integer()
        }

  @doc """
  Applies `positions` to `map_id`.

  Each position is a `%{solar_system_id: integer, position_x: integer,
  position_y: integer}` map. Systems that are not currently present on the
  map, or whose stored position already equals the requested position, are
  skipped (logged at debug level) rather than causing a write.
  """
  @spec apply(String.t(), [position()], keyword()) :: :ok
  def apply(map_id, positions, _opts \\ []) when is_list(positions) do
    existing_systems_by_id =
      map_id
      |> WandererApp.Map.list_systems!()
      |> Map.new(&{&1.solar_system_id, &1})

    positions
    |> Enum.each(&apply_position(map_id, existing_systems_by_id, &1))

    :ok
  end

  defp apply_position(map_id, existing_systems_by_id, %{
         solar_system_id: solar_system_id,
         position_x: position_x,
         position_y: position_y
       }) do
    case Map.fetch(existing_systems_by_id, solar_system_id) do
      :error ->
        Logger.debug(fn ->
          "[BulkReposition] skipping solar_system_id=#{solar_system_id}: not present on map #{map_id}"
        end)

      {:ok, %{position_x: ^position_x, position_y: ^position_y}} ->
        Logger.debug(fn ->
          "[BulkReposition] skipping solar_system_id=#{solar_system_id}: position unchanged"
        end)

      {:ok, _system} ->
        WandererApp.Map.Server.update_system_position(map_id, %{
          solar_system_id: solar_system_id,
          position_x: position_x,
          position_y: position_y
        })
    end

    :ok
  end
end
