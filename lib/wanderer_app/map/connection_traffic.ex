defmodule WandererApp.Map.ConnectionTraffic do
  @moduledoc """
  CHEWY PATCH: keeps `map_chain_v1.count_of_passage` in step with the jumps
  already recorded in `map_chain_passages_v1`, and broadcasts the updated
  connection so the map UI can draw a used route differently from an
  untravelled one.

  Why this exists: upstream declares `count_of_passage` on the connection
  resource, accepts it on every action — and never writes it. Measured on the
  live `yugen` map (2026-09-25): 54 passage rows recorded in twelve hours,
  `count_of_passage = 0` on all 37 connections. The data the UI would need to
  show "this is the route everyone is actually using" was being thrown away at
  the moment it was produced.

  Gated by `WANDERER_CONNECTION_TRAFFIC` (default off = upstream behaviour:
  the counter stays at 0 and every connection renders identically).

  Counting is per connection, not per direction: `WandererApp.Map.find_connection/3`
  already resolves either endpoint order to the one stored connection, which is
  also how the map renders it.
  """

  require Logger

  @doc """
  Records one traversal of the connection between `source_id` and `target_id`.

  Returns `:ok` in every case — a missing connection (the jump created no
  connection, e.g. it was filtered by map scope) or a failed write must never
  break the character-jump path that calls this.
  """
  def record_passage(map_id, source_id, target_id) do
    if WandererApp.Env.connection_traffic?() do
      do_record_passage(map_id, source_id, target_id)
    else
      :ok
    end
  end

  @doc """
  Passage count a freshly created connection starts at: 1 for a connection a
  real jump just created (that jump is a passage), 0 for one added manually on
  the map, and 0 whenever the feature is off.
  """
  def initial_count(is_manual) do
    if WandererApp.Env.connection_traffic?() and not is_manual, do: 1, else: 0
  end

  defp do_record_passage(map_id, source_id, target_id) do
    with {:ok, connection} when not is_nil(connection) <-
           WandererApp.Map.find_connection(map_id, source_id, target_id),
         count = (connection.count_of_passage || 0) + 1,
         {:ok, updated} <-
           WandererApp.MapConnectionRepo.update_count_of_passage(connection, %{
             count_of_passage: count
           }) do
      :ok = WandererApp.Map.update_connection(map_id, Map.put(connection, :count_of_passage, count))

      WandererApp.Map.Server.Impl.broadcast!(map_id, :update_connection, updated)

      :ok
    else
      {:ok, nil} ->
        :ok

      error ->
        Logger.warning("Failed to record connection passage: #{inspect(error, pretty: true)}")
        :ok
    end
  end
end
