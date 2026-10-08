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

  ## Manual archive: `archived_at`

  Presence is derived from what the client reports; `archived_at` is the
  one thing a READER can assert -- "I flew there, it is not there, stop
  shouting at me". It is not a delete: the row, its history and the CSV
  export keep it.

  An archive expires on its own, and the rule is `last_changed_at`, NOT
  `last_confirmed_at`: a sweep re-confirming the SAME unanchored hull
  every ten minutes must not resurrect a finding a human already
  judged, but an actual state change (status, owner, timer, ...) is new
  information and brings it straight back. That is the `:archived`
  calculation, and every opportunity board filters `archived == false`
  next to its `presence == :seen`. `:search` again shows everything.

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
    define(:archived, action: :archived)
    define(:targets, action: :targets, args: [:statuses, :since])

    define(:archive, action: :archive, args: [:user_id])
    define(:restore, action: :restore)
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
      :unanchoring_since,
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
      prepare build(load: [:archived])
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
                 archived == false and
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

      prepare build(sort: [last_confirmed_at: :desc], load: [:archived])
    end

    # Asset safety off: everything inside drops. Its own board since
    # 1.103.4-chewy.86 -- it used to share one with `NoFuel` through
    # `Status.dead_family/0`, and the two are not the same errand: an
    # abandoned hull is loot, an unfuelled one is a hull whose owner
    # stopped paying and may still come back. `presence == :seen` for the
    # same reason every other board filters it: one that was since
    # refuelled or killed comes back as `:cleared`/`:gone` and stops
    # being a target, even though its last stored `status` still says so
    # (a steady id carries no state to overwrite it with).
    read :abandoned do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               presence == :seen and
                 archived == false and
                 last_confirmed_at >= ^arg(:since) and
                 status in ^WandererApp.Scout.Status.abandoned_family() and
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

      prepare build(sort: [last_confirmed_at: :desc], load: [:archived])
    end

    # Low power: no tether, no services, and an owner who is not paying
    # attention. Same shape as `:abandoned`, different half of the old
    # `Status.dead_family/0`.
    read :no_fuel do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               presence == :seen and
                 archived == false and
                 last_confirmed_at >= ^arg(:since) and
                 status in ^WandererApp.Scout.Status.no_fuel_family() and
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

      prepare build(sort: [last_confirmed_at: :desc], load: [:archived])
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
                 archived == false and
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

      prepare build(sort: [last_confirmed_at: :desc], load: [:archived])
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
                 archived == false and
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

      prepare build(sort: [last_confirmed_at: :desc], load: [:archived])
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
                 archived == false and
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

      prepare build(sort: [timer_expires_at: :asc], load: [:archived])
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

      prepare build(sort: [last_confirmed_at: :desc], load: [:archived])
    end

    # What a reader archived and the feed has not contradicted since --
    # the restore list, and the only place an archived structure is
    # listed as such. No `since` argument on purpose: an archive is a
    # standing judgement, so hiding it behind the window selector would
    # make it unrecoverable from the UI the moment it aged out.
    read :archived do
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               archived == true and
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

      prepare build(sort: [archived_at: :desc], load: [:archived])
    end

    # CHEWY PATCH (target routing): the membership behind the planner's
    # Targets mode -- "take me to every system where we last saw one of
    # THESE". Deliberately not one of the board actions above: it takes
    # the status families as an ARGUMENT (the page lets a reader tick
    # more than one) and carries no `q`/`system_id` filter, because a
    # route is built from the whole finding set, not from whatever the
    # intel page's search box happens to hold.
    #
    # `presence == :seen` and `archived == false` for the same reasons
    # every board applies them: a structure the absence pipeline already
    # took to `:missing`/`:gone` is not somewhere to fly, and an
    # archived finding is one a reader has explicitly dismissed.
    read :targets do
      argument :statuses, {:array, :string}, allow_nil?: false
      argument :since, :utc_datetime, allow_nil?: false

      filter expr(
               presence == :seen and
                 archived == false and
                 last_confirmed_at >= ^arg(:since) and
                 status in ^arg(:statuses)
             )

      prepare build(sort: [last_confirmed_at: :desc], load: [:archived])
    end

    # Not atomic: both changes are plain attribute writes, but the
    # actor-supplied argument keeps Ash from proving that, and a bulk
    # path for a one-row button is not worth the ceremony.
    update :archive do
      require_atomic? false
      accept []
      argument :user_id, :uuid

      change set_attribute(:archived_at, &DateTime.utc_now/0)
      change set_attribute(:archived_by_user_id, arg(:user_id))
    end

    update :restore do
      require_atomic? false
      accept []

      change set_attribute(:archived_at, nil)
      change set_attribute(:archived_by_user_id, nil)
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

    # CHEWY PATCH: the first sweep that saw this structure in the
    # unanchoring family, cleared the moment it leaves it. Written only
    # by `WandererApp.Scout.Snapshot` via
    # `WandererApp.Scout.Unanchor.transition/4`; the Unanchoring board's
    # "Predicted max out" column is this plus the fixed 7-day
    # decommission. A decommission carries no wire timer, so without
    # this column that board has no deadline at all.
    attribute :unanchoring_since, :utc_datetime

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

    # Set by a reader, never by the feed. See @moduledoc: suppression
    # lasts until `last_changed_at` moves past this.
    attribute :archived_at, :utc_datetime
    attribute :archived_by_user_id, :uuid

    attribute :map_id, :uuid

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  calculations do
    # The suppression predicate, defined ONCE and inlined into every
    # board's filter by AshPostgres. `last_changed_at` nil means nothing
    # has ever changed about this structure, so the archive stands.
    calculate :archived,
              :boolean,
              expr(
                not is_nil(archived_at) and
                  (is_nil(last_changed_at) or last_changed_at <= archived_at)
              )
  end

  identities do
    identity :uniq_structure, [:structure_id]
  end
end
