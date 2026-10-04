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

  describe "transition/4" do
    test "the first sighting of a run is the anchor" do
      assert Unanchor.transition("FullPower", "Unanchoring", nil, @since) ==
               %{unanchoring_since: @since}
    end

    test "a later sighting of the same run writes nothing" do
      assert Unanchor.transition("Unanchoring", "Unanchoring", @since, ~U[2026-10-02 12:00:00Z]) ==
               %{}
    end

    test "a row already unanchoring with no anchor stored heals" do
      later = ~U[2026-10-02 12:00:00Z]

      assert Unanchor.transition("Unanchoring", "Unanchoring", nil, later) ==
               %{unanchoring_since: later}
    end

    test "leaving the family clears the anchor -- a cancel restarts the 7 days" do
      assert Unanchor.transition("Unanchoring", "FullPower", @since, ~U[2026-10-02 12:00:00Z]) ==
               %{unanchoring_since: nil}
    end
  end
end
