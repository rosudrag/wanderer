defmodule WandererApp.Api.ScoutStructureSighting do
  @moduledoc """
  CHEWY PATCH: one row per observation of a player-owned Upwell structure
  by an eveknob client — the state it was in, and the reinforcement timer
  running on it if any. **Append-only**, like
  `WandererApp.Api.ScoutSpawnSighting`: a structure observed on Monday
  and again on Friday is two rows, and the difference between them is the
  point. The UI folds them to latest-per-structure at read time.

  Source is eveknob's `Config/Logs/structures.tsv`
  (`core/obj_StructureWatch.iss`), shipped to
  `POST /api/maps/:map_identifier/scout/structures`. See
  `WandererApp.Scout.Ingest`.

  ## Two traps in the source file, both handled at ingest

    * Its header row is **stale**: it names 24 columns while the writer
      emits 26. `anchoring` and `unanchoring` were added between
      `vulnerable` and `timer_seconds` and the header was never rewritten,
      so a positional parse against the on-disk header shifts every field
      after `vulnerable` by two. Ingest takes named JSON, so the client
      owns the mapping — but anyone reading the raw TSV must use the
      writer's order, not the file's header.

    * Its `type_name` column is not a type name. The writer fills it from
      `Entity.Name`, i.e. the player-set structure name ("Sirekur - Happy
      MC TIMES"); the actual type is `type_id`, and `group_name` carries
      "Citadel"/"Refinery". Stored here as `structure_name`, which is what
      it is. Ingest accepts `type_name` as an alias so the client can post
      the raw column name.

  ## Timers

  `timer_seconds` is a countdown *relative to the observation*, with `-1`
  meaning "no timer". Stored as-is, but also resolved to an absolute
  `timer_expires_at` at ingest — a relative countdown is useless in a log
  read hours later, and an absolute instant is what the page sorts on.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_structure_sightings_v1")

    custom_indexes do
      index([:observed_at])
      # :active_timers filters and sorts on this, and it is the query the
      # page runs on every mount.
      index([:timer_expires_at])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:upsert, action: :upsert)

    define(:recent, action: :recent, args: [:since])
    define(:active_timers, action: :active_timers, args: [:now])
  end

  actions do
    default_accept [
      :observed_at,
      :character_name,
      :event,
      :solar_system_id,
      :solar_system_name,
      :system_truesec,
      :structure_id,
      :type_id,
      :structure_name,
      :group_name,
      :owner_id,
      :owner_name,
      :alliance_id,
      :upkeep_state,
      :upkeep_label,
      :structure_state,
      :state_label,
      :vulnerable,
      :anchoring,
      :unanchoring,
      :timer_seconds,
      :timer_expires_at,
      :shield_pct,
      :armor_pct,
      :hull_pct,
      :distance_m,
      :map_id
    ]

    defaults [:create, :read, :destroy]

    create :upsert do
      upsert?(true)
      upsert_identity(:uniq_sighting)
    end

    read :recent do
      argument :since, :utc_datetime, allow_nil?: false
      filter expr(observed_at >= ^arg(:since))
      prepare build(sort: [observed_at: :desc])
    end

    # Structures whose reinforcement timer has not run out yet — the one
    # query that is genuinely time-critical rather than historical.
    read :active_timers do
      argument :now, :utc_datetime, allow_nil?: false
      filter expr(not is_nil(timer_expires_at) and timer_expires_at > ^arg(:now))
      prepare build(sort: [timer_expires_at: :asc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :observed_at, :utc_datetime do
      allow_nil? false
    end

    attribute :character_name, :string do
      allow_nil? false
    end

    # :seen on a sweep that first noticed a notable state, :change when an
    # already-tracked structure moved to a different state. Closed set --
    # unlike the spawn strings, the writer emits exactly these two literals.
    attribute :event, :atom do
      constraints one_of: [:seen, :change]
      default :seen
      allow_nil? false
    end

    attribute :solar_system_id, :integer do
      allow_nil? false
    end

    # Often just the system ID as a string: the client caches the resolved
    # name and logs the ID when resolution has not happened yet.
    attribute :solar_system_name, :string
    attribute :system_truesec, :float

    attribute :structure_id, :integer do
      allow_nil? false
    end

    attribute :type_id, :integer

    # The player-set name (source column `type_name`, see @moduledoc).
    attribute :structure_name, :string

    # "Citadel" | "Refinery" | ...
    attribute :group_name, :string

    attribute :owner_id, :integer
    attribute :owner_name, :string
    attribute :alliance_id, :integer

    attribute :upkeep_state, :integer
    attribute :upkeep_label, :string
    attribute :structure_state, :integer
    attribute :state_label, :string

    attribute :vulnerable, :boolean
    attribute :anchoring, :boolean
    attribute :unanchoring, :boolean

    # -1 in the source means "no timer"; normalised to nil at ingest.
    attribute :timer_seconds, :integer

    # observed_at + timer_seconds, computed at ingest. See @moduledoc.
    attribute :timer_expires_at, :utc_datetime

    attribute :shield_pct, :integer
    attribute :armor_pct, :integer
    attribute :hull_pct, :integer

    # Metres to the observing character. int64: values above 1e13 occur.
    attribute :distance_m, :integer

    attribute :map_id, :uuid

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :uniq_sighting, [:structure_id, :observed_at, :event]
  end
end
