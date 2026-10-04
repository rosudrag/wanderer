defmodule WandererApp.Scout.Unanchor do
  @moduledoc """
  CHEWY PATCH: the Unanchoring board's deadline column.

  A reinforcement timer arrives on the wire (`timer_seconds`, relative,
  re-read every sweep). A DECOMMISSION does not: the client reads no
  countdown off an unanchoring structure, so `timer_expires_at` is nil
  for every row on that board and the "Comes out" column it fed could
  never show anything but an em dash.

  What IS known is the mechanic. Decommissioning an Upwell structure is
  a FIXED 7 days, and cancelling it restarts the full 7
  (`support.eveonline.com`, "Upwell Structure Deployment and
  Unanchoring"), so the only unknown is when the owner started it. The
  feed bounds that from one side: `unanchoring_since` on
  `WandererApp.Api.ScoutStructure` is the first sweep that saw the
  structure unanchoring, cleared the moment its status leaves the
  family. Therefore

      predicted max = unanchoring_since + 7 days

  is the LATEST instant the hull can still be in space. The true
  completion is at or before it, never after: an unanchor may have been
  running for days before a scout first flew past, but cannot have
  started after we saw it. Hence "predicted max", rendered with a `≤`,
  and never presented as an exact timer.

  Orbitals are excluded rather than predicted. A customs office gantry
  unanchors in seconds and a POCO in minutes; it is a different
  mechanic, and a 7-day prediction on one would be a lie with a
  timestamp on it. `predicted_max_at/1` returns nil for them and the
  cell stays an em dash.
  """

  alias WandererApp.Scout.Status

  # 7 days, the whole prediction. Not configurable: it is a game
  # constant, not a tuning knob, and an env var would only let a
  # deployment disagree with EVE.
  @window_seconds 7 * 24 * 60 * 60

  @doc "The fixed Upwell decommission window, in seconds."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc """
  The latest instant this structure can still be in space, or nil when
  there is nothing honest to say: not unanchoring (no `unanchoring_since`),
  or an orbital, whose unanchor is minutes rather than days.
  """
  @spec predicted_max_at(map()) :: DateTime.t() | nil
  def predicted_max_at(%{unanchoring_since: %DateTime{} = since} = row) do
    if orbital?(row), do: nil, else: DateTime.add(since, @window_seconds, :second)
  end

  def predicted_max_at(_row), do: nil

  @doc """
  `group_name`, not type or category: the wire carries the SDE group
  name ("Citadel", "Refinery", "Engineering Complex", "Orbital
  Infrastructure", "Orbital Skyhook") and nothing else that separates
  the two unanchor mechanics. An unknown/absent group is treated as
  Upwell — that is what the overwhelming majority of rows are, and the
  column is labelled a prediction.
  """
  @spec orbital?(map()) :: boolean()
  def orbital?(%{group_name: name}) when is_binary(name),
    do: name =~ ~r/orbital|customs/i

  def orbital?(_row), do: false

  @doc """
  The `unanchoring_since` write for one observation, as attributes to
  merge into the row's update. Three cases, and the middle one is the
  point:

    * the new status is not in the unanchoring family -> nil. A
      cancelled decommission restarts the 7 days, so a stale anchor
      would under-predict, which is the one error direction that makes
      the column dangerous.
    * already unanchoring with an anchor stored -> no write. The anchor
      is the FIRST sighting of this run; every later sweep confirming
      the same run must not push it forward.
    * anything else (first sighting of a run, or a row carrying no
      anchor yet — a backfilled one) -> this observation.
  """
  @spec transition(String.t() | nil, String.t() | nil, DateTime.t() | nil, DateTime.t()) :: map()
  def transition(previous_status, next_status, current_since, observed_at) do
    cond do
      not unanchoring?(next_status) -> %{unanchoring_since: nil}
      unanchoring?(previous_status) and not is_nil(current_since) -> %{}
      true -> %{unanchoring_since: observed_at}
    end
  end

  defp unanchoring?(status), do: status in Status.unanchoring_family()
end
