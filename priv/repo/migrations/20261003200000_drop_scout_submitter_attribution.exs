defmodule WandererApp.Repo.Migrations.DropScoutSubmitterAttribution do
  @moduledoc """
  CHEWY PATCH: the scout log stops carrying who reported a row.

  Hand-written rather than generated (no Elixir toolchain on the authoring
  box), but shaped exactly like `mix ash_postgres.generate_migrations`
  output plus one thing a generated migration could not do: the spawn
  table's unique identity CONTAINED `character_name`, so dropping the
  column turns rows that differed only by reporter into duplicates. Those
  must be collapsed BEFORE the new unique index is created or the index
  build fails on live data. The survivor is the oldest `inserted_at`
  (stable, and the one whose `id` other rows never referenced).

  Structures need no such dedupe: their identity was already
  `(structure_id, observed_at, event)`.

  `down` restores the columns NULLABLE and backfills the literal
  'unknown' - the names themselves are gone for good, which is the point
  of the change; the rollback only restores the SHAPE.
  """

  use Ecto.Migration

  def up do
    # Collapse spawn rows that were distinct only by reporter.
    execute("""
    DELETE FROM scout_spawn_sightings_v1 a
    USING scout_spawn_sightings_v1 b
    WHERE a.observed_at = b.observed_at
      AND a.solar_system_id = b.solar_system_id
      AND a.location_name = b.location_name
      AND a.spawn_name = b.spawn_name
      AND (a.inserted_at, a.id) > (b.inserted_at, b.id)
    """)

    drop_if_exists unique_index(
                     :scout_spawn_sightings_v1,
                     [:character_name, :observed_at, :solar_system_id, :location_name, :spawn_name],
                     name: "scout_spawn_sightings_v1_uniq_sighting_index"
                   )

    create unique_index(
             :scout_spawn_sightings_v1,
             [:observed_at, :solar_system_id, :location_name, :spawn_name],
             name: "scout_spawn_sightings_v1_uniq_sighting_index"
           )

    alter table(:scout_spawn_sightings_v1) do
      remove :character_name
    end

    alter table(:scout_structure_sightings_v1) do
      remove :character_name
    end
  end

  def down do
    alter table(:scout_structure_sightings_v1) do
      add :character_name, :text
    end

    alter table(:scout_spawn_sightings_v1) do
      add :character_name, :text
    end

    execute("UPDATE scout_structure_sightings_v1 SET character_name = 'unknown'")
    execute("UPDATE scout_spawn_sightings_v1 SET character_name = 'unknown'")

    alter table(:scout_structure_sightings_v1) do
      modify :character_name, :text, null: false
    end

    alter table(:scout_spawn_sightings_v1) do
      modify :character_name, :text, null: false
    end

    drop_if_exists unique_index(
                     :scout_spawn_sightings_v1,
                     [:observed_at, :solar_system_id, :location_name, :spawn_name],
                     name: "scout_spawn_sightings_v1_uniq_sighting_index"
                   )

    create unique_index(
             :scout_spawn_sightings_v1,
             [:character_name, :observed_at, :solar_system_id, :location_name, :spawn_name],
             name: "scout_spawn_sightings_v1_uniq_sighting_index"
           )
  end
end
