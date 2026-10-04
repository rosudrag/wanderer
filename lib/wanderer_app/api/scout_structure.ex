defmodule WandererApp.Api.ScoutStructure do
  @moduledoc """
  CHEWY PATCH: CURRENT STATE of every structure a snapshot blob has ever
  mentioned -- one row per `structure_id`, the identity. This is the
  table `/scout`'s opportunity boards read from.

  Written exclusively by `WandererApp.Scout.Snapshot.ingest/2`
  (`POST /api/maps/:map_identifier/scout/structures/snapshot`, gated on
  `WANDERER_SCOUT_PRESENCE`) and by the one-time backfill migration that
  seeds it from `scout_structure_sightings_v1`
  (`DISTINCT ON (structure_id) ORDER BY observed_at DESC`). See
  `docs/design/wanderer-scout-presence.md` for the full contract and
  `docs/chewy/scout-intel.md` for how this is rendered.

  ## `presence`, not `status`, is what the opportunity boards filter on

  `status` is the last known specific state string
  ("ArmorReinforced", "FullPower", ...) and only ever arrives on a
  direct sighting (`structures[]` in the blob) -- it is NOT updated by a
  `steady_ids` entry, because a steady id carries no state, only an id.
  `presence` is the orthogonal, server-derived "is this still a target"
  signal:

    * `:seen` -- directly observed, notable or freshly confirmed boring.
    * `:cleared` -- confirmed present via `steady_ids`, but the LAST
      stored `status` was not already in the steady family: a genuine
      "went boring" transition. The specific new status is unknown (a
      steady id carries no state) so `status` itself is left untouched;
      `presence` alone is what takes this off the boards.
    * `:missing` -- expected (in a prior blob's scope) and absent from
      this one.
    * `:gone` -- `:missing` for long enough, or unanchored/unanchored's
      own timer ran out. Never terminal: any positive sighting resets to
      `:seen`.

  So every opportunity board additionally filters `presence == :seen`;
  `:search` alone shows every presence, because it is the "what do we
  know" table, not a target list.

  ## No `solar_system_name` / `system_truesec`

  Unlike `ScoutStructureSighting`, this resource does not carry a
  resolved system name or truesec -- `/scout` already resolves both from
  `solar_system_id` via `WandererApp.CachedInfo` at read time
  (`ScoutIntelLive.assign_systems/2`), and a current-state table has no
  reason to duplicate a value that never changes per system.

  ## `map_id` is provenance only

  Same ruling as every other scout table: which map's API key
  authenticated the snapshot that last touched this row. Never part of
  the identity, never scopes a read.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_structures_v1")

    custom_indexes do
      index([:solar_system_id])
      index([:presence])
      index([:status])
      index([:timer_expires_at])
      index([:last_confirmed_at])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:by_structure_id, action: :by_structure_id, args: [:structure_id])
    define(:update, action: :update)
    define(:destroy, action: :destroy)

    define(:anchoring, action: :anchoring, args: [:since])
    define(:unanchored, action: :unanchored, args: [:since])
    define(:unanchoring, action: :unanchoring, args: [:since])
    define(:active_timers, action: :active_timers, args: [:now])
    define(:search, action: :search, args: [:since])
  end

  actions do
    default_accept [
      :structure_id,
      :solar_system_id,
      :type_id,
      :structure_name,
      :group_name,
      :owner_id,
      :owner_name,
      :alliance_id,
      :upkeep_state,
      :structure_state,
      :status,
      :vulnerable,
      :anchoring,
      :unanchoring,
      :timer_seconds,
      :timer_expires_at,
      :shield_pct,
      :armor_pct,
      :hull_pct,
      :pos_x,
      :pos_y,
      :pos_z,
      :nearest_celestial,
      :nearest_celestial_m,
      :presence,
      :first_seen_at,
      :last_confirmed_at,
      :last_changed_at,
      :missing_count,
      :missing_since,
      :map_id
    ]

    defaults [:create, :read, :update, :destroy]

    # The ingest path's own per-row lookup when it already knows the id
    # (the LiveView drill-down modal). Loading a whole system's rows for
    # the diff goes through a plain `Ash.Query.filter` in
    # `WandererApp.Scout.Snapshot`, the same way `Scout.Merge.previous/1`
    # looks up a single sighting -- no action needed for that.
    read :by_structure_id do
      get? true
      argument :structure_id, :integer, allow_nil?: false
      filter expr(structure_id == ^arg(:structure_id))
    end

    # Cheapest-kill board: no fitting, no services online yet, a live
    # vulnerability window. `presence == :seen` -- a cleared/missing/gone
    # structure is not a target, whatever its last known status was.
    read :anchoring do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               presence == :seen and
                 last_confirmed_at >= ^arg(:since) and
                 status in ^WandererApp.Scout.Status.anchoring_family() and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      structure_name,
                      owner_name,
                      group_name,
                      nearest_celestial,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [last_confirmed_at: :desc])
    end

    # Nothing to shoot and nothing to wait for: asset safety off
    # (`Abandoned`) or simply unfuelled (`NoFuel`) -- the highest-value
    # findings short of a running timer. `presence == :seen` for the same
    # reason every other board filters it: an unfuelled hull somebody has
    # since refuelled comes back as `:cleared` and stops being a target,
    # even though its last stored `status` is still "NoFuel" (a steady id
    # carries no state to overwrite it with).
    read :abandoned do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               presence == :seen and
                 last_confirmed_at >= ^arg(:since) and
                 status in ^WandererApp.Scout.Status.dead_family() and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      structure_name,
                      owner_name,
                      group_name,
                      nearest_celestial,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [last_confirmed_at: :desc])
    end

    # The alert board: `status == "Unanchored"` -- sitting in space fully
    # deployed into nothing. `presence == :seen` for the same reason
    # `:anchoring` filters it: a structure that unanchored, sat there,
    # and then genuinely vanished is `:gone`, not an active alert.
    read :unanchored do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               presence == :seen and
                 last_confirmed_at >= ^arg(:since) and
                 status in ^WandererApp.Scout.Status.unanchored_family() and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      structure_name,
                      owner_name,
                      group_name,
                      nearest_celestial,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [last_confirmed_at: :desc])
    end

    # Being pulled out of the ground: a one-shot opportunity with a hard
    # deadline. `presence == :seen` -- once it finishes and the
    # structure actually leaves, the absence pipeline takes it to
    # `:missing` / `:gone`, and this board stops claiming it.
    read :unanchoring do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               presence == :seen and
                 last_confirmed_at >= ^arg(:since) and
                 status in ^WandererApp.Scout.Status.unanchoring_family() and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      structure_name,
                      owner_name,
                      group_name,
                      nearest_celestial,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [last_confirmed_at: :desc])
    end

    # The one genuinely time-critical board. `since` deliberately does
    # not apply -- a running timer is running however old the sighting
    # that found it -- but `presence == :seen` still does: a timer on a
    # structure the diff has since marked `:missing`/`:gone` is not a
    # fleet to form over.
    read :active_timers do
      argument :now, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               presence == :seen and
                 not is_nil(timer_expires_at) and timer_expires_at > ^arg(:now) and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      structure_name,
                      owner_name,
                      group_name,
                      nearest_celestial,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [timer_expires_at: :asc])
    end

    # "What do we know" -- every presence, including cleared/missing/gone.
    # The one board a reader searching for a specific structure actually
    # wants to find it on regardless of whether it is still a target.
    read :search do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               last_confirmed_at >= ^arg(:since) and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      structure_name,
                      owner_name,
                      group_name,
                      nearest_celestial,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [last_confirmed_at: :desc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :structure_id, :integer do
      allow_nil? false
    end

    attribute :solar_system_id, :integer do
      allow_nil? false
    end

    attribute :type_id, :integer
    # Source wire key `type_name` -- the player-set structure name, same
    # confusing-but-established mapping `ScoutStructureSighting` uses.
    attribute :structure_name, :string
    attribute :group_name, :string

    attribute :owner_id, :integer
    attribute :owner_name, :string
    attribute :alliance_id, :integer

    attribute :upkeep_state, :integer
    attribute :structure_state, :integer

    # Last known specific verdict. Only ever written from a direct
    # sighting (`structures[]`); a `steady_ids` entry never touches it --
    # see @moduledoc.
    attribute :status, :string

    attribute :vulnerable, :boolean
    attribute :anchoring, :boolean
    attribute :unanchoring, :boolean

    attribute :timer_seconds, :integer
    attribute :timer_expires_at, :utc_datetime

    attribute :shield_pct, :integer
    attribute :armor_pct, :integer
    attribute :hull_pct, :integer

    # Absolute solar-system metres. Structures do not move, so one
    # resolved reading is permanent; nil until the client resolves one.
    # NOT archivable (excluded from `in_scope`) while any of the three
    # is nil -- fail-open, same discipline `nearest_celestial` already
    # uses on the sighting table.
    attribute :pos_x, :float
    attribute :pos_y, :float
    attribute :pos_z, :float

    attribute :nearest_celestial, :string
    attribute :nearest_celestial_m, :integer

    attribute :presence, :atom do
      constraints one_of: [:seen, :cleared, :missing, :gone]
      default :seen
      allow_nil? false
    end

    attribute :first_seen_at, :utc_datetime do
      allow_nil? false
    end

    # The freshness column every board sorts/filters on: the last time
    # ANY positive signal (a direct sighting or a steady id) confirmed
    # this structure still exists. Never moved by a `:missing` tick.
    attribute :last_confirmed_at, :utc_datetime do
      allow_nil? false
    end

    # Only moved by a `:changed` diff outcome -- unlike
    # `last_confirmed_at`, an unchanged re-sighting leaves this alone.
    attribute :last_changed_at, :utc_datetime

    attribute :missing_count, :integer do
      default 0
      allow_nil? false
    end

    # Set on the FIRST miss, left alone on every subsequent one -- the
    # anchor the 30-minute `:gone` promotion window measures from. Reset
    # to nil by any positive sighting.
    attribute :missing_since, :utc_datetime

    attribute :map_id, :uuid

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :uniq_structure, [:structure_id]
  end
end
