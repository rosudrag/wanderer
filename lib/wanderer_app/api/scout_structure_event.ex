defmodule WandererApp.Api.ScoutStructureEvent do
  @moduledoc """
  CHEWY PATCH: the derived log behind `WandererApp.Api.ScoutStructure`'s
  current-state table -- written only when
  `WandererApp.Scout.Snapshot.diff/2` finds something, never on an
  unchanged re-confirmation (that would spam the log with "Seen 4m ago"
  rows exactly the way `WandererApp.Scout.Merge` already exists to stop
  on the per-row feed).

  One row per `kind`:

    * `:appeared` -- a new `structure_id`, never tracked before.
    * `:changed` -- a tracked field moved on a direct sighting.
      `changed_fields` names which; `status_before`/`status_after`
      capture the one field every reader cares about first.
    * `:cleared` -- confirmed present via `steady_ids`, last known
      status was not already boring. `status_before` and `status_after`
      are the SAME value here -- a steady id carries no state, so there
      is no new status to record, only the presence transition itself
      (see `ScoutStructure`'s moduledoc for why `presence`, not
      `status`, is what this event is really about).
    * `:missing` -- expected and absent this sweep. `changed_fields` is
      always `[]`; nothing about the structure's last known state moved,
      only its presence.
    * `:gone` -- promoted from `:missing`, by either path in
      `docs/design/wanderer-scout-presence.md` section 5.

  This is what `/scout`'s per-structure history drill-down reads
  (`:history`), in place of the old append-only `ScoutStructureSighting`
  log for any structure this feed has touched.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_structure_events_v1")

    custom_indexes do
      index([:structure_id, :observed_at])
      index([:observed_at])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:history, action: :history, args: [:structure_id])
    define(:destroy, action: :destroy)
  end

  actions do
    default_accept [
      :structure_id,
      :solar_system_id,
      :kind,
      :observed_at,
      :status_before,
      :status_after,
      :changed_fields,
      :map_id
    ]

    defaults [:create, :read, :destroy]

    # The drill-down: every event for one structure, newest first.
    read :history do
      argument :structure_id, :integer, allow_nil?: false
      filter expr(structure_id == ^arg(:structure_id))
      prepare build(sort: [observed_at: :desc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :structure_id, :integer do
      allow_nil? false
    end

    attribute :solar_system_id, :integer

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: [:appeared, :changed, :cleared, :missing, :gone]
    end

    attribute :observed_at, :utc_datetime do
      allow_nil? false
    end

    attribute :status_before, :string
    attribute :status_after, :string

    attribute :changed_fields, {:array, :string} do
      default []
      allow_nil? false
    end

    # Provenance only -- which map's API key authenticated the snapshot
    # that produced this event.
    attribute :map_id, :uuid

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
