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

  ## How a run ENDS, and why that is its own column

  A decommission we are watching ends in exactly one way that is good
  for us: the hull comes out and sits in space `Unanchored`, which is
  what the alert board and the asset-safety trigger are for. Every
  other ending means somebody else sorted it -- the owner cancelled,
  a third party reinforced it, or it finished and was collected
  between two of our visits.

  Before this, those endings were unobservable after the fact. The
  status write simply overwrote `status` and nulled `unanchoring_since`,
  and an absence only moved `presence`, so a run that ended left no
  trace anywhere except the append-only event log -- and the row just
  vanished off the Unanchoring board with no reason given. `outcome/2`
  names the ending and `unanchor_ended_at`/`unanchor_outcome` store it:

    * `:unanchored` -- re-sighted in `Status.unanchored_family/0`. The
      hull is loose; this is the ending we want.
    * `:stopped` -- re-sighted in any other status. The decommission is
      not running any more and the structure is still there.
    * `:vanished` -- the absence pipeline promoted it to `:gone` while
      it was still unanchoring: it finished and was collected (or
      killed) between two of our visits.
    * `:expired` -- DERIVED, never stored: nothing has contradicted the
      row, but `unanchoring_since + 7d` has passed, so it cannot still
      be in the ground. Nothing observed this, so nothing writes it.

  `unanchoring_since` is therefore KEPT across the ending (it was
  nulled before) -- it is what dates the run on the resolved board --
  and `predicted_max_at/1` refuses to answer for an ended run so no
  other board can read a dead anchor as a live deadline. Starting a new
  run clears both columns, because a cancel restarts the full 7 days.
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
  def predicted_max_at(%{unanchor_ended_at: %DateTime{}}), do: nil

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
  The unanchoring columns to write for one observation, as attributes
  to merge into the row's update:

    * already unanchoring with an anchor stored -> no write. The anchor
      is the FIRST sighting of this run; every later sweep confirming
      the same run must not push it forward.
    * now unanchoring, previously not (or no anchor stored -- a
      backfilled row) -> this observation becomes the anchor, and any
      recorded ending is cleared: a cancel restarts the full 7 days.
    * was unanchoring, now is not -> the run ENDED here. The anchor is
      kept (it dates the run) and `unanchor_outcome` records how:
      `:unanchored` if the hull is now loose, `:stopped` otherwise.
    * anything else -> no write.
  """
  @spec transition(String.t() | nil, String.t() | nil, DateTime.t() | nil, DateTime.t()) :: map()
  def transition(previous_status, next_status, current_since, observed_at) do
    cond do
      unanchoring?(next_status) and unanchoring?(previous_status) and not is_nil(current_since) ->
        %{}

      unanchoring?(next_status) ->
        %{unanchoring_since: observed_at, unanchor_ended_at: nil, unanchor_outcome: nil}

      # The run ends here: keep the anchor (it dates the run on the
      # resolved board) and record HOW it ended. Only ever written once
      # per run -- a row that was already not unanchoring has nothing
      # to end.
      unanchoring?(previous_status) ->
        %{unanchor_ended_at: observed_at, unanchor_outcome: ended_outcome(next_status)}

      true ->
        %{}
    end
  end

  @doc """
  The ending recorded when an absence proves the structure is gone
  (`presence` reached `:gone`) while it was still unanchoring: it came
  out and was collected, or was killed, between two of our visits.
  Returns `%{}` for a row that was not unanchoring or whose run was
  already resolved -- an absence must never overwrite a sighting's own
  verdict.
  """
  @spec vanished(map(), DateTime.t()) :: map()
  def vanished(row, observed_at), do: end_run(row, observed_at, :vanished)

  @doc """
  The ending recorded when a `steady_ids` entry confirms the structure
  is still there and boring. The id carries no status, so `status` is
  left alone (the resource's own rule) -- but "steady" is by definition
  not unanchoring, so the run is over and somebody stopped it.
  """
  @spec stopped(map(), DateTime.t()) :: map()
  def stopped(row, observed_at), do: end_run(row, observed_at, :stopped)

  defp end_run(row, observed_at, outcome) do
    if unanchoring?(Map.get(row, :status)) and is_nil(Map.get(row, :unanchor_outcome)) do
      %{unanchor_ended_at: observed_at, unanchor_outcome: outcome}
    else
      %{}
    end
  end

  # The only ending that is good news: the hull is loose in space.
  # Everything else means the run stopped with the structure still in
  # the ground, whoever caused it.
  defp ended_outcome(status) do
    if status in Status.unanchored_family(), do: :unanchored, else: :stopped
  end

  @doc """
  How this run ended, as one atom, for a row from ANY board.

  `nil` means it has not: either the structure is not unanchoring at
  all, or it still is and its window has not run out. `:expired` is the
  one verdict derived rather than stored -- see the moduledoc.
  """
  @spec outcome(map(), DateTime.t()) :: :unanchored | :stopped | :vanished | :expired | nil
  def outcome(row, now \\ DateTime.utc_now())

  def outcome(%{unanchor_outcome: outcome}, _now) when not is_nil(outcome), do: outcome

  def outcome(row, now) do
    with true <- unanchoring?(Map.get(row, :status)),
         %DateTime{} = at <- predicted_max_at(row),
         :lt <- DateTime.compare(at, now) do
      :expired
    else
      _still_running -> nil
    end
  end

  @doc "A reader's words for an ending, for the board's Reason column."
  @spec outcome_label(atom()) :: String.t()
  def outcome_label(:unanchored), do: "came out — hull loose"
  def outcome_label(:stopped), do: "no longer unanchoring"
  def outcome_label(:vanished), do: "gone when we next looked"
  def outcome_label(:expired), do: "7-day window passed"
  def outcome_label(_other), do: "—"

  defp unanchoring?(status), do: status in Status.unanchoring_family()
end
