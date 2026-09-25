defmodule WandererApp.Map.ChainStandoff do
  @moduledoc """
  CHEWY PATCH: how far a newly scanned system should be dropped from the system
  it was scanned FROM.

  Upstream (and tidy insert) puts a new system one grid pitch from its origin.
  That is right inside a chain, and wrong when the origin is a k-space system
  laid out on the Dotlan-geometry lattice: the lattice's own gate gaps are
  compressed to one cell, so a wormhole dropped one cell away lands on top of
  the geography the map is read by. `WANDERER_CHAIN_STANDOFF` (0 = upstream)
  pushes exactly that case further out, matching the pocket the beautifier
  reserves for the same chain (see layout/index.ts step 2).

  Gate hops and hops that start in wormhole space are never affected: inside a
  chain, and along a gate, adjacency is the readable thing.
  """

  alias WandererApp.Map.Server.ConnectionsImpl

  @doc """
  Extra grid pitches to add to the tidy-insert offsets for this jump.

  0 whenever the feature is off, the jump is a stargate hop, either end is
  unknown, or the origin is not k-space.
  """
  def cells(nil, _target_solar_system_id), do: 0

  def cells(_source_solar_system_id, nil), do: 0

  def cells(source_solar_system_id, target_solar_system_id) do
    standoff = WandererApp.Env.chain_standoff_cells()

    cond do
      standoff <= 0 -> 0
      source_solar_system_id == target_solar_system_id -> 0
      gate_hop?(source_solar_system_id, target_solar_system_id) -> 0
      not kspace?(source_solar_system_id) -> 0
      true -> standoff
    end
  end

  defp gate_hop?(source_solar_system_id, target_solar_system_id),
    do: ConnectionsImpl.is_connection_valid(:stargates, source_solar_system_id, target_solar_system_id)

  # J-space solar system ids start at 31_000_000; everything below is k-space
  # (the same split `layout/index.ts` makes by "has a gate edge on this map").
  defp kspace?(solar_system_id) when is_integer(solar_system_id), do: solar_system_id < 31_000_000

  defp kspace?(_solar_system_id), do: false
end
