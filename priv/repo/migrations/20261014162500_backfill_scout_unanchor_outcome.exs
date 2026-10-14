defmodule WandererApp.Repo.Migrations.BackfillScoutUnanchorOutcome do
  @moduledoc """
  CHEWY PATCH: gives every unanchoring run that ALREADY ended the ending
  it was never able to record.

  Until `add_scout_unanchor_outcome`, a run that stopped left no trace on
  the current-state row: the status write nulled `unanchoring_since` and
  an absence only moved `presence`, so the row dropped off the
  Unanchoring board with no reason given. Measured on the live database
  2026-10-14, that is 41 rows sitting at `status='Unanchoring'` /
  `presence='gone'` plus 2 re-sighted in another status -- 43 endings
  nobody can see, against the 30 rows the board was still offering.

  The append-only event log is what makes the backfill possible: it kept
  the instant each of those endings was observed. Where it did not (a
  `:gone` promotion whose event write failed), `missing_since` is the
  honest second choice -- the first absence of the run that ended it.

  `presence='missing'` rows are deliberately left alone. One quiet
  d-scan is not an ending; `Snapshot.gone?/5` is where that judgement
  lives, and those rows get their outcome from it on the next pass.
  """

  use Ecto.Migration

  def up do
    # Ended with the structure gone: it finished and was collected, or
    # was killed, between two of our visits.
    execute("""
    UPDATE scout_structures_v1 s
    SET unanchor_outcome = 'vanished',
        unanchor_ended_at = e.observed_at
    FROM (
      SELECT DISTINCT ON (structure_id) structure_id, observed_at
      FROM scout_structure_events_v1
      WHERE kind = 'gone'
      ORDER BY structure_id, observed_at DESC
    ) e
    WHERE e.structure_id = s.structure_id
      AND s.status = 'Unanchoring'
      AND s.presence = 'gone'
      AND s.unanchor_outcome IS NULL
    """)

    execute("""
    UPDATE scout_structures_v1
    SET unanchor_outcome = 'vanished',
        unanchor_ended_at = COALESCE(missing_since, last_confirmed_at)
    WHERE status = 'Unanchoring'
      AND presence = 'gone'
      AND unanchor_outcome IS NULL
    """)

    # Still there, and confirmed boring by a steady id: somebody stopped
    # the decommission. `status` is untouched by that path, which is why
    # these rows still read 'Unanchoring'.
    execute("""
    UPDATE scout_structures_v1
    SET unanchor_outcome = 'stopped',
        unanchor_ended_at = last_confirmed_at
    WHERE status = 'Unanchoring'
      AND presence = 'cleared'
      AND unanchor_outcome IS NULL
    """)

    # Re-sighted in another status. The old code dropped the anchor, so
    # these rows get an ending with no run length -- the board renders
    # that as an em dash rather than guessing.
    execute("""
    UPDATE scout_structures_v1 s
    SET unanchor_outcome = CASE WHEN e.status_after = 'Unanchored' THEN 'unanchored' ELSE 'stopped' END,
        unanchor_ended_at = e.observed_at
    FROM (
      SELECT DISTINCT ON (structure_id) structure_id, observed_at, status_after
      FROM scout_structure_events_v1
      WHERE kind = 'changed'
        AND status_before = 'Unanchoring'
        AND status_after IS DISTINCT FROM 'Unanchoring'
      ORDER BY structure_id, observed_at DESC
    ) e
    WHERE e.structure_id = s.structure_id
      AND s.status <> 'Unanchoring'
      AND s.unanchor_outcome IS NULL
    """)
  end

  def down do
    execute("""
    UPDATE scout_structures_v1
    SET unanchor_outcome = NULL, unanchor_ended_at = NULL
    """)
  end
end
