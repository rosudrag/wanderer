defmodule WandererApp.Api.ScoutSpawnSighting do
  @moduledoc """
  CHEWY PATCH: one row per special NPC spawn an eveknob client saw and
  logged — faction spawns, NPC escalations, haulers. An **append-only
  log**, not a live-state table: the same belt spawning a Dark Blood
  Phantom twice is two rows, because the question this answers is "what
  has spawned where, how often, and what was it worth".

  Source is eveknob's `Config/Logs/special_spawns.tsv`
  (`core/obj_SpawnLog.iss`), shipped to
  `POST /api/maps/:map_identifier/scout/spawns` by the same bridge that
  already posts signatures. See `WandererApp.Scout.Ingest`.

  ## Idempotence

  The client tails an append-only file and is expected to re-send rows it
  already sent (restart, overlapping window, retry). `:uniq_sighting`
  over the source row's natural key makes that free: ingest upserts, so a
  replayed row updates itself instead of duplicating. Every component of
  that identity is `allow_nil? false` — in Postgres `NULL <> NULL`, so a
  nullable identity column silently disables the constraint.

  ## No submitter attribution

  The observing character is deliberately NOT stored. This log answers
  "what spawned where, when, and what was it worth"; a name on every row
  only adds a per-pilot activity trail for anyone with scout access to
  read. The field is dropped at ingest, so an older client may keep
  sending it with no effect. Consequence worth knowing: the name is also
  out of `:uniq_sighting`, so two pilots reporting the same spawn at the
  same second in the same place now upsert onto ONE row — which is the
  honest count of the event anyway.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_spawn_sightings_v1")

    # Every read this resource has sorts or filters on observed_at, and the
    # table only grows.
    custom_indexes do
      index([:observed_at])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:upsert, action: :upsert)

    define(:recent, action: :recent, args: [:since])
  end

  actions do
    default_accept [
      :observed_at,
      :solar_system_id,
      :solar_system_name,
      :system_truesec,
      :location_type,
      :location_name,
      :spawn_name,
      :spawn_category,
      :anomaly_type,
      :players_in_local,
      :action_taken,
      :outcome,
      :entity_id,
      :minutes_since_downtime,
      :isk_value,
      :map_id
    ]

    defaults [:create, :read, :destroy]

    # The ingest path. `upsert?: true` keyed on the natural identity makes a
    # re-sent tail of the source file a no-op rather than a duplicate row.
    create :upsert do
      upsert?(true)
      upsert_identity(:uniq_sighting)
    end

    read :recent do
      argument :since, :utc_datetime, allow_nil?: false
      filter expr(observed_at >= ^arg(:since))
      prepare build(sort: [observed_at: :desc])
    end

    # The page's read. Optional filters, nil meaning "no filter", so the
    # unfiltered table is the same action with no arguments set. The text
    # match runs in Postgres for the same reason as the structure one:
    # the caller's `limit` is the only thing keeping a 90-day window off
    # the heap, and filtering in Elixir would defeat it.
    read :search do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               observed_at >= ^arg(:since) and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      spawn_name,
                      location_name,
                      solar_system_name,
                      spawn_category,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [observed_at: :desc])
    end
  end

  attributes do
    uuid_primary_key :id

    # The source row's `utc_timestamp` column, NOT its local `timestamp`
    # column: the log is shared by clients in different timezones, so the
    # local one is not comparable across rows.
    attribute :observed_at, :utc_datetime do
      allow_nil? false
    end

    attribute :solar_system_id, :integer do
      allow_nil? false
    end

    attribute :solar_system_name, :string
    attribute :system_truesec, :float

    # "belt", "skyhook", ... — free text from the client, not an enum: a new
    # location kind should land in the log, not be rejected by it.
    attribute :location_type, :string

    attribute :location_name, :string do
      allow_nil? false
      default ""
    end

    attribute :spawn_name, :string do
      allow_nil? false
      default ""
    end

    # "faction" | "escalation" | "hauler" | ... Same reasoning as
    # :location_type — open vocabulary on purpose.
    attribute :spawn_category, :string
    attribute :anomaly_type, :string
    attribute :players_in_local, :integer
    attribute :action_taken, :string
    attribute :outcome, :string

    # int64 in the source. Ash `:integer` is a Postgres bigint, which holds
    # the full EVE entity-ID range (observed: 9_002_310_729_000_024_265).
    attribute :entity_id, :integer

    attribute :minutes_since_downtime, :integer
    attribute :isk_value, :decimal

    # Provenance only: which map's API key authenticated the submission.
    # The log itself is deliberately NOT map-scoped — it is fleet intel.
    attribute :map_id, :uuid

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :uniq_sighting, [
      :observed_at,
      :solar_system_id,
      :location_name,
      :spawn_name
    ]
  end
end
