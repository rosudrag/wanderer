defmodule WandererApp.Api.ScoutSystemCoverage do
  @moduledoc """
  CHEWY PATCH: one row per `(solar_system_id, kind)` recording when
  eveknob last finished looking at a system to a given depth -- even when
  it found nothing. That "nothing changed" case is exactly what
  `scout_spawn_sightings_v1` / `scout_structure_sightings_v1` and
  `map_system_signature` cannot answer: their timestamps only move when a
  row CHANGES, so an unchanged re-scan is indistinguishable from no scan
  at all. See `docs/design/wanderer-scout-planner.md` sections 1-4.

  Source is `POST /api/maps/:map_identifier/scout/coverage`, fed by
  eveknob's `obj_ScoutSync.iss`. See `WandererApp.Scout.Coverage`.

  ## Latest-wins, NOT an append-only log

  Unlike the sighting tables, this upserts on `:uniq_coverage`
  (`solar_system_id`, `kind`): a staleness ranking only ever reads the
  newest observation of each kind, and the full history already lives in
  the sighting tables and `map_chain_passages_v1`. `:uniq_coverage`'s
  components are `allow_nil? false` for the same reason
  `scout_spawn_sightings_v1`'s identity is -- Postgres's `NULL <> NULL`
  would otherwise let the "same" system silently fan out into many rows.

  ## Four kinds, one ladder

  `kind` is a CLOSED vocabulary -- `visit | anoms | sigs | grid` -- not
  free text like the sighting tables' `location_type`/`spawn_category`.
  Each kind answers a different "have we looked?" question with a
  different intended TTL (session arrival, scanner results, prober
  sweep, physical tour), so they are deliberately four rows per system,
  not one. `legs_scanned` is meaningful only for `kind = "grid"`;
  `sig_count` only for `"sigs"`/`"anoms"`.

  ## The clean-tour verdict (`kind = "grid"` only)

  `spawns_found` and `legs_total` are the other half of what makes a
  `grid` row answer "scouted, clean" rather than just "scouted,
  somewhere": `spawns_found` counts the SCANNED LOCATIONS since arrival
  where `obj_Scout.LogScanSummary` resolved a `specialName` (officer,
  NPC capital, faction, hauler or unclassified special target), and
  `legs_total` is that pass's `TourOrder.Used` -- so a reader can tell a
  COMPLETE clean tour (`legs_scanned == legs_total && spawns_found ==
  0`) from a partial one. Both are nullable and OPTIONAL: an old client
  posting only `legs_scanned` stores NULL in both, same as every other
  optional field here. The client never computes or sends a boolean
  verdict -- `WandererApp.Scout.Planner` derives CLEAN/partial
  server-side, same ruling that dropped the client-side `event` column
  from the structure presence payload.

  ## No submitter-only attribution, and no map scoping

  `character_eve_id` is kept (unlike the sighting tables) because the
  planner's `claimed` term needs to tell "the same scout is still here"
  from "someone else already came through" -- see the design doc's
  staleness-ranking section. `map_id` is provenance only, nullable, and
  is NEVER part of the identity: coverage is a fact about the SYSTEM, the
  same ruling the scout-intel sighting tables already made. This feature
  never creates a `map_system` row and never touches the map canvas.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_system_coverage_v1")

    # The ranking query orders by age within a kind; both indexes exist
    # for that read, not for the upsert (which goes through the
    # :uniq_coverage unique index instead).
    custom_indexes do
      index([:observed_at])
      index([:kind, :observed_at])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:upsert, action: :upsert)

    define(:by_system_and_kind,
      action: :by_system_and_kind,
      args: [:solar_system_id, :kind],
      get?: true
    )
  end

  actions do
    default_accept [
      :solar_system_id,
      :kind,
      :observed_at,
      :character_eve_id,
      :source,
      :legs_scanned,
      :sig_count,
      :scanner_complete,
      :spawns_found,
      :legs_total,
      :map_id
    ]

    defaults [:create, :read, :destroy]

    # The ingest path. `WandererApp.Scout.Coverage` decides, in Elixir,
    # whether an incoming row is fresher than the stored one BEFORE
    # calling this -- see its module doc for why that guard lives there
    # rather than as an `upsert_condition` here.
    create :upsert do
      upsert?(true)
      upsert_identity(:uniq_coverage)
    end

    # The one read the ingest guard needs: the current row for this
    # system+kind, if any.
    read :by_system_and_kind do
      get? true

      argument :solar_system_id, :integer, allow_nil?: false
      argument :kind, :atom, allow_nil?: false

      filter expr(solar_system_id == ^arg(:solar_system_id) and kind == ^arg(:kind))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :solar_system_id, :integer do
      allow_nil? false
    end

    # Closed vocabulary on purpose -- unlike the sighting tables' free-text
    # category columns, a fifth kind here needs a planner change to mean
    # anything, so an unrecognised value is a row-level ingest error
    # rather than a new silently-accepted category.
    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: [:visit, :anoms, :sigs, :grid]
    end

    attribute :observed_at, :utc_datetime do
      allow_nil? false
    end

    # Attribution, not identity -- two scouts reporting the same system
    # at different times both update this one row; the later wins and
    # this field just says who.
    attribute :character_eve_id, :string

    attribute :source, :string

    # Meaningful only for kind = "grid".
    attribute :legs_scanned, :integer

    # Meaningful only for kind = "grid". Count of scanned locations,
    # since arrival, where at least one special spawn was present --
    # see module doc "The clean-tour verdict". 0 is the point of the
    # feature: it means "toured and clean".
    attribute :spawns_found, :integer

    # Meaningful only for kind = "grid". The tour's total leg count for
    # this pass (`TourOrder.Used`) -- lets a reader tell a COMPLETE
    # clean tour from a partial one; see module doc.
    attribute :legs_total, :integer

    # Meaningful only for kind = "sigs" | "anoms".
    attribute :sig_count, :integer

    attribute :scanner_complete, :boolean

    # Provenance only: which map's API key authenticated the submission.
    # NOT part of :uniq_coverage -- see module doc.
    attribute :map_id, :uuid

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :uniq_coverage, [:solar_system_id, :kind]
  end
end
