defmodule WandererApp.Api.ScoutAssetSafety do
  @moduledoc """
  CHEWY PATCH: one row per ESI `StructureItemsMovedToSafety` notification
  this deployment has ever read, keyed on `notification_id`.

  ## What the row means, and why it is worth a board of its own

  Drop a single item into a structure that is unanchoring. When the
  decommission FINISHES, EVE moves that item to asset safety and tells
  the item's owner so — `StructureItemsMovedToSafety`, carrying
  `structureID` and `solarSystemID`. Nothing else in this app can
  observe that instant: `WandererApp.Scout.Unanchor` derives a 7-day
  UPPER BOUND from the first sweep that saw the run, and the absence
  pipeline only notices the hull is gone on the next sweep through that
  system, which may be hours later. The notification is the event
  itself, and the hull is floating, unanchored and scoopable right then.

  So this table is a TRIGGER LOG, not a state table: a row is a thing
  that happened at `notified_at`, it is never revised, and it is never
  the current state of anything. That is the whole reason it is not a
  column on `WandererApp.Api.ScoutStructure` — the structure row may not
  exist at all (nobody ever flew past it), and when it does exist the
  notification says something about a moment, not about the structure.

  ## Written by one caller

  `WandererApp.Sync.Feeds.AssetSafetyFeed` (gated on
  `WANDERER_SCOUT_ASSET_SAFETY`), one scope per opted-in character, via
  the Phase 2 sync scheduler. See `WandererApp.Scout.AssetSafety` for
  the parse and the reads, and `docs/chewy/scout-intel.md`.

  ## The denormalised columns are deliberate

  `structure_name`, `group_name`, `owner_name` and `nearest_celestial`
  are copied off the matching `ScoutStructure` row AT INGEST, when there
  is one, and `group_name` otherwise falls back to the structure TYPE
  name resolved from `structureTypeID`. Two reasons: the notification
  alone identifies a structure only by a 64-bit id, which is unreadable
  on a board; and every shared formatter on `/scout` — the Discord
  `subject/1`, `place/1`, `owner/1` line builders and the table cells —
  already reads exactly those four keys, so a row that carries them
  renders through the existing vocabulary with no new cell. They are a
  snapshot of what was known at ingest and are never refreshed; the
  authoritative current state is, as always, `ScoutStructure`.

  ## Dismissal, and why it is per STRUCTURE

  No presence and no archive-expiry: presence is machinery for a row
  that keeps re-asserting itself, and this row is a single historical
  fact that can never be contradicted. But it does NOT age off fast
  enough to need no control — `horizon_days/0` is seven days, and a
  reader who has already scooped (or written off) a hull is looking at
  the alert banner for a week.

  So `dismissed_at` exists and is the reader's own judgement: "dealt
  with". It is never a delete — the row stays in the table, in the
  retention purge's reach and in every history read — and it is undone
  from the Dismissed board.

  It is applied to every row carrying the same `structure_id`, not to
  one notification: two of your characters seeding the same hull is the
  expected case, the board folds `DISTINCT ON (structure_id)`, and
  dismissing "the row you see" would leave its sibling to surface in
  its place. That is `WandererApp.Scout.AssetSafety.dismiss/2`.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_asset_safety_v1")

    custom_indexes do
      index([:structure_id])
      index([:solar_system_id])
      index([:notified_at])
      index([:character_eve_id])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:by_notification_id, action: :by_notification_id, args: [:notification_id])
    define(:recent, action: :recent, args: [:since])
    define(:stale, action: :stale, args: [:character_eve_id, :before])
    define(:by_structure_id, action: :by_structure_id, args: [:structure_id])
    define(:dismissed, action: :dismissed)

    define(:dismiss, action: :dismiss, args: [:user_id])
    define(:restore, action: :restore)
  end

  actions do
    default_accept [
      :notification_id,
      :type,
      :character_eve_id,
      :character_name,
      :structure_id,
      :structure_type_id,
      :structure_name,
      :group_name,
      :owner_name,
      :nearest_celestial,
      :solar_system_id,
      :is_corp_owned,
      :new_station_id,
      :notified_at,
      :asset_safety_min_at,
      :asset_safety_full_at
    ]

    defaults [:create, :read, :destroy]

    # The feed's idempotency check: ESI hands back the same ~50
    # notifications on every poll, forever.
    read :by_notification_id do
      get? true
      argument :notification_id, :integer, allow_nil?: false
      filter expr(notification_id == ^arg(:notification_id))
    end

    # The board. `q` matches the same four text columns every other
    # board on /scout searches, so one search box narrows this one too;
    # `space` is applied as a query shaper by the caller, like every
    # other scout read.
    #
    # NOT folded per structure here: two of your characters seeded the
    # same hull, EVE sends two notifications, and that is two rows. The
    # fold is a `DISTINCT ON (structure_id)` the caller adds
    # (`WandererApp.Scout.AssetSafety.fold/1`), the same split the
    # spawns tab already uses.
    read :recent do
      argument :since, :utc_datetime, allow_nil?: false
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               is_nil(dismissed_at) and
                 notified_at >= ^arg(:since) and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      structure_name,
                      owner_name,
                      group_name,
                      character_name,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [notified_at: :desc])
    end

    # Retention, per scope — one character's rows past the feed's
    # `retention_days/0`.
    read :stale do
      argument :character_eve_id, :integer, allow_nil?: false
      argument :before, :utc_datetime, allow_nil?: false

      filter expr(character_eve_id == ^arg(:character_eve_id) and notified_at < ^arg(:before))
    end

    # Every row about one structure — what `dismiss/2` writes over, and
    # what a dismissal has to cover: two alts seeding the same hull is
    # two notifications and the board only ever shows one of them.
    read :by_structure_id do
      argument :structure_id, :integer, allow_nil?: false
      filter expr(structure_id == ^arg(:structure_id))
    end

    # The undo list. No `since` argument, for the same reason
    # `ScoutStructure`'s `:archived` has none: a judgement hidden behind
    # the window selector cannot be reversed once it ages out.
    read :dismissed do
      argument :system_id, :integer
      argument :q, :string

      filter expr(
               not is_nil(dismissed_at) and
                 (is_nil(^arg(:system_id)) or solar_system_id == ^arg(:system_id)) and
                 (is_nil(^arg(:q)) or
                    fragment(
                      "(coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'') || ' ' || coalesce(?,'')) ILIKE '%' || ? || '%'",
                      structure_name,
                      owner_name,
                      group_name,
                      character_name,
                      ^arg(:q)
                    ))
             )

      prepare build(sort: [dismissed_at: :desc])
    end

    # Plain attribute writes; not atomic for the same reason
    # `ScoutStructure.archive` is not — a two-field button is not worth
    # an atomic path.
    update :dismiss do
      require_atomic? false
      accept []
      argument :user_id, :uuid

      change set_attribute(:dismissed_at, &DateTime.utc_now/0)
      change set_attribute(:dismissed_by_user_id, arg(:user_id))
    end

    update :restore do
      require_atomic? false
      accept []

      change set_attribute(:dismissed_at, nil)
      change set_attribute(:dismissed_by_user_id, nil)
    end
  end

  attributes do
    uuid_primary_key :id

    # ESI's own id for the notification. The identity: the same
    # notification re-read on the next poll must not create a row, and
    # the same structure seen by two of your characters must (two
    # notifications, two ids).
    attribute :notification_id, :integer do
      allow_nil? false
    end

    # The ESI notification type that produced this row. One value today
    # (`StructureItemsMovedToSafety`); stored rather than implied so a
    # second trigger type can be added without a migration.
    attribute :type, :string do
      allow_nil? false
    end

    # Who was told — the character whose token read it. This is the
    # pilot who seeded the structure, which is also the one who knows
    # what was in it.
    attribute :character_eve_id, :integer do
      allow_nil? false
    end

    attribute :character_name, :string

    attribute :structure_id, :integer do
      allow_nil? false
    end

    attribute :solar_system_id, :integer do
      allow_nil? false
    end

    attribute :structure_type_id, :integer

    # Snapshot of what `ScoutStructure` knew at ingest -- see @moduledoc.
    attribute :structure_name, :string
    attribute :group_name, :string
    attribute :owner_name, :string
    attribute :nearest_celestial, :string

    attribute :is_corp_owned, :boolean
    attribute :new_station_id, :integer

    # When EVE sent it. The only clock on this row that matters: the
    # hull came out of the ground at this instant.
    attribute :notified_at, :utc_datetime do
      allow_nil? false
    end

    # EVE's own asset-safety countdown, carried through because it is
    # free and it bounds how long the OWNER has a reason to come back.
    attribute :asset_safety_min_at, :utc_datetime
    attribute :asset_safety_full_at, :utc_datetime

    # The reader's own "dealt with". Unlike `ScoutStructure`'s archive
    # this never expires: nothing can contradict a notification, so
    # there is no later fact that should bring the row back on its own.
    attribute :dismissed_at, :utc_datetime
    attribute :dismissed_by_user_id, :uuid

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :uniq_notification, [:notification_id]
  end
end
