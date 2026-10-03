defmodule WandererApp.Repo.Migrations.AddScoutStructureNearestCelestial do
  @moduledoc """
  CHEWY PATCH: `scout_structure_sightings_v1` gains the closest static-map
  body to the structure's position (`nearest_celestial`) and the gap in
  metres (`nearest_celestial_m`) -- eveknob already writes both to
  `structures.tsv` columns 28/29 (`core/obj_StructureWatch.iss`), this
  just stops throwing them away at ingest.

  Hand-written rather than generated (no Elixir toolchain on the
  authoring box), but shaped exactly like
  `mix ash_postgres.generate_migrations` output: a plain nullable column
  pair, no index -- neither field is filtered on its own, only matched
  through the existing `:search` / `:active_timers` ILIKE fragment.

  `down` drops both columns; there is nothing to backfill, the celestial
  is only ever known live, off a structure's current position.
  """

  use Ecto.Migration

  def up do
    alter table(:scout_structure_sightings_v1) do
      add :nearest_celestial, :text
      add :nearest_celestial_m, :bigint
    end
  end

  def down do
    alter table(:scout_structure_sightings_v1) do
      remove :nearest_celestial
      remove :nearest_celestial_m
    end
  end
end
