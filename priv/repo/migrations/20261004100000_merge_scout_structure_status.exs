defmodule WandererApp.Repo.Migrations.MergeScoutStructureStatus do
  @moduledoc """
  CHEWY PATCH: `upkeep_state`/`upkeep_label` (power) and
  `structure_state`/`state_label` (lifecycle/combat) described ONE verdict
  with two labels, and the pair lies on its own: a structure that never
  finished deploying has no service module *by construction*, so the
  server drives it to `LowPower` immediately and `Abandoned` ~7 days later
  (`structures/structure.py:586-608`), which is exactly why live data had
  5 rows of `Abandoned + Onlining` that were half-finished drops, not
  abandoned hulls.

  Replaces both label columns with one merged `status` (PascalCase,
  eveknob-computed, stored verbatim -- never re-derived server-side) per
  the 16-row precedence table in `docs/chewy/scout-intel.md`:
  `unanchoring` outranks everything, then the deployment family (rows
  1-7, which is what turns those `Abandoned + Onlining` rows into honest
  `Onlining`), then `Abandoned` (row 8, outranks a reinforcement timer --
  asset safety off is the rarest, highest-value finding), then the
  reinforce/vulnerable tiers, then `LowPower` -> `NoFuel` (deployment
  finished, nobody shooting), then the two steady states.

  Orbitals (POCO groupID 1025, Orbital Skyhook groupID 4736) have no
  upkeep concept -- `upkeep_state` is NULL for every orbital row already
  -- so for those the existing `state_label` (already the correct family
  label, from `obj_StructureLabels.PocoStateLabel` /
  `.SkyhookStateLabel`) is carried over verbatim rather than re-derived.

  Hand-written rather than generated (no Elixir toolchain on the
  authoring box), but shaped like `mix ash_postgres.generate_migrations`
  output plus the one thing codegen cannot do: a `CASE` backfill BEFORE
  the source columns are dropped, so no existing row loses its verdict.

  `down` re-adds both label columns and repopulates them from
  `upkeep_state` / `structure_state` via `obj_StructureLabels`'s own
  int -> label tables (`UpkeepLabel`, `StateLabel`) -- the rollback
  restores the SHAPE and the Upwell labels exactly. It cannot restore the
  orbital rows' original `state_label` text: POCO/Skyhook have their own
  numbering (`PocoStateLabel`/`SkyhookStateLabel`), not the Upwell
  `StateLabel` table the `CASE` below uses, so an orbital row's raw
  `structure_state` falls through to `'Unknown'` on rollback.
  `upkeep_label` is unaffected either way -- it was already `NULL` for
  every orbital row and the `CASE` reproduces that.
  """

  use Ecto.Migration

  def up do
    alter table(:scout_structure_sightings_v1) do
      add :status, :text
    end

    execute("""
    UPDATE scout_structure_sightings_v1 SET status =
      CASE
        WHEN unanchoring THEN 'Unanchoring'
        WHEN upkeep_state IS NULL THEN COALESCE(state_label, 'Unknown')
        WHEN structure_state = 1 THEN 'Unanchored'
        WHEN structure_state = 2 THEN 'Anchoring'
        WHEN structure_state = 115 THEN 'AnchorVulnerable'
        WHEN structure_state = 116 THEN 'Deploying'
        WHEN structure_state = 101 THEN 'Fitting'
        WHEN structure_state = 102 THEN 'Onlining'
        WHEN upkeep_state = 3 THEN 'Abandoned'
        WHEN structure_state = 111 THEN 'ArmorReinforced'
        WHEN structure_state = 113 THEN 'HullReinforced'
        WHEN structure_state = 112 THEN 'ArmorVulnerable'
        WHEN structure_state = 114 THEN 'HullVulnerable'
        WHEN upkeep_state = 2 THEN 'NoFuel'
        WHEN structure_state = 118 THEN 'FobInvulnerable'
        WHEN upkeep_state = 1 AND structure_state = 110 THEN 'FullPower'
        ELSE 'Unknown'
      END
    """)

    create index(:scout_structure_sightings_v1, [:status])

    alter table(:scout_structure_sightings_v1) do
      remove :upkeep_label
      remove :state_label
    end
  end

  def down do
    alter table(:scout_structure_sightings_v1) do
      add :upkeep_label, :text
      add :state_label, :text
    end

    execute("""
    UPDATE scout_structure_sightings_v1 SET
      upkeep_label = CASE
        WHEN upkeep_state IS NULL THEN NULL
        WHEN upkeep_state = 1 THEN 'FullPower'
        WHEN upkeep_state = 2 THEN 'LowPower'
        WHEN upkeep_state = 3 THEN 'Abandoned'
        ELSE 'Unknown'
      END,
      state_label = CASE
        WHEN structure_state IS NULL THEN NULL
        WHEN structure_state = 1 THEN 'Unanchored'
        WHEN structure_state = 2 THEN 'Anchoring'
        WHEN structure_state = 100 THEN 'OnlineDeprecated'
        WHEN structure_state = 101 THEN 'Fitting'
        WHEN structure_state = 102 THEN 'Onlining'
        WHEN structure_state = 110 THEN 'ShieldVulnerable'
        WHEN structure_state = 111 THEN 'ArmorReinforced'
        WHEN structure_state = 112 THEN 'ArmorVulnerable'
        WHEN structure_state = 113 THEN 'HullReinforced'
        WHEN structure_state = 114 THEN 'HullVulnerable'
        WHEN structure_state = 115 THEN 'AnchorVulnerable'
        WHEN structure_state = 116 THEN 'Deploying'
        WHEN structure_state = 118 THEN 'FobInvulnerable'
        ELSE 'Unknown'
      END
    """)

    drop_if_exists index(:scout_structure_sightings_v1, [:status])

    alter table(:scout_structure_sightings_v1) do
      remove :status
    end
  end
end
