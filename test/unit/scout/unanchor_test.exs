defmodule WandererApp.Scout.UnanchorTest do
  @moduledoc """
  The Unanchoring board's deadline, which is a prediction and has
  exactly one safety property: it must be an UPPER bound. A structure
  shown as "≤ 2d" that is actually gone costs a reader a wasted trip; a
  structure shown as "≤ 6d" that leaves tomorrow costs the kill.
  """

  use ExUnit.Case, async: true

  alias WandererApp.Scout.Unanchor

  @since ~U[2026-10-01 12:00:00Z]

  test "the prediction is the anchor plus EVE's fixed 7-day decommission" do
    assert Unanchor.predicted_max_at(%{unanchoring_since: @since, group_name: "Citadel"}) ==
             ~U[2026-10-08 12:00:00Z]
  end

  test "no anchor means no prediction, never a guess from now" do
    assert Unanchor.predicted_max_at(%{unanchoring_since: nil, group_name: "Citadel"}) == nil
  end

  test "orbitals are excluded: minutes, not days, and a different mechanic" do
    for group <- ["Orbital Infrastructure", "Orbital Skyhook", "Customs Office Gantry"] do
      assert Unanchor.predicted_max_at(%{unanchoring_since: @since, group_name: group}) == nil
    end
  end

  test "an ended run has no prediction: a dead anchor must never read as a live deadline" do
    assert Unanchor.predicted_max_at(%{
             unanchoring_since: @since,
             group_name: "Citadel",
             unanchor_ended_at: ~U[2026-10-03 12:00:00Z]
           }) == nil
  end

  describe "transition/4" do
    test "the first sighting of a run is the anchor, and clears any older ending" do
      assert Unanchor.transition("FullPower", "Unanchoring", nil, @since) ==
               %{unanchoring_since: @since, unanchor_ended_at: nil, unanchor_outcome: nil}
    end

    test "a later sighting of the same run writes nothing" do
      assert Unanchor.transition("Unanchoring", "Unanchoring", @since, ~U[2026-10-02 12:00:00Z]) ==
               %{}
    end

    test "a row already unanchoring with no anchor stored heals" do
      later = ~U[2026-10-02 12:00:00Z]

      assert Unanchor.transition("Unanchoring", "Unanchoring", nil, later) ==
               %{unanchoring_since: later, unanchor_ended_at: nil, unanchor_outcome: nil}
    end

    test "leaving the family ends the run and keeps the anchor that dates it" do
      ended = ~U[2026-10-02 12:00:00Z]

      assert Unanchor.transition("Unanchoring", "FullPower", @since, ended) ==
               %{unanchor_ended_at: ended, unanchor_outcome: :stopped}
    end

    test "coming out as a loose hull is the one good ending, and is named differently" do
      ended = ~U[2026-10-02 12:00:00Z]

      assert Unanchor.transition("Unanchoring", "Unanchored", @since, ended) ==
               %{unanchor_ended_at: ended, unanchor_outcome: :unanchored}
    end

    test "a structure that was never unanchoring has nothing to end" do
      assert Unanchor.transition("FullPower", "NoFuel", nil, @since) == %{}
    end
  end

  describe "the two endings no status write can express" do
    test "an absence that reached :gone ends the run as vanished" do
      assert Unanchor.vanished(%{status: "Unanchoring", unanchor_outcome: nil}, @since) ==
               %{unanchor_ended_at: @since, unanchor_outcome: :vanished}
    end

    test "a steady id ends it as stopped -- it carries no status to overwrite with" do
      assert Unanchor.stopped(%{status: "Unanchoring", unanchor_outcome: nil}, @since) ==
               %{unanchor_ended_at: @since, unanchor_outcome: :stopped}
    end

    test "neither overwrites an ending a sighting already recorded" do
      row = %{status: "Unanchoring", unanchor_outcome: :unanchored}

      assert Unanchor.vanished(row, @since) == %{}
      assert Unanchor.stopped(row, @since) == %{}
    end

    test "neither touches a structure that was not unanchoring" do
      row = %{status: "NoFuel", unanchor_outcome: nil}

      assert Unanchor.vanished(row, @since) == %{}
      assert Unanchor.stopped(row, @since) == %{}
    end
  end

  describe "outcome/2" do
    @now ~U[2026-10-09 12:00:00Z]

    test "a stored ending is reported as stored" do
      assert Unanchor.outcome(%{status: "FullPower", unanchor_outcome: :stopped}, @now) ==
               :stopped
    end

    test "a live run inside its window has no outcome" do
      row = %{
        status: "Unanchoring",
        unanchor_outcome: nil,
        unanchoring_since: ~U[2026-10-08 12:00:00Z],
        group_name: "Citadel"
      }

      assert Unanchor.outcome(row, @now) == nil
    end

    test "a run past its 7 days is :expired -- derived, because nothing observed it" do
      row = %{
        status: "Unanchoring",
        unanchor_outcome: nil,
        unanchoring_since: @since,
        group_name: "Citadel"
      }

      assert Unanchor.outcome(row, @now) == :expired
    end

    test "an orbital never expires: it carries no prediction to pass" do
      row = %{
        status: "Unanchoring",
        unanchor_outcome: nil,
        unanchoring_since: @since,
        group_name: "Orbital Skyhook"
      }

      assert Unanchor.outcome(row, @now) == nil
    end
  end
end
