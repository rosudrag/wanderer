defmodule WandererApp.Api.ScoutAssignment do
  @moduledoc """
  CHEWY PATCH: one row per `(assignment_id, solar_system_id, character_eve_id)`
  recording "this character has been handed this system to scout, for this
  kind, until this row expires or coverage lands for it". See
  `docs/design/wanderer-scout-region-sweeps.md` section 5 and
  `WandererApp.Scout.Assignments` (the orchestration module this resource is
  the storage for -- same split as `ScoutSystemCoverage` / `WandererApp.Scout.
  Coverage`).

  ## Why this exists at all

  `obj_ScoutMemory`'s claims are same-box relay only, 15 minutes, advisory --
  fine for one character avoiding itself, useless for keeping three
  characters on different boxes off each other's systems for the hours a
  region split takes. This is the server-side record that makes a split
  STICKY: written once per split (`WandererApp.Scout.Assignments.assign/2`),
  read by the planner/sweep as a hard exclusion (`active_system_ids/1`), and
  cleared two ways -- `expires_at` passing on its own (an offline character
  cannot freeze a region forever), or `completed_at` being set the instant a
  coverage row lands for that `(solar_system_id, kind)` (see
  `WandererApp.Scout.Coverage`'s hook).

  ## Multiple rows per `(solar_system_id, kind)` are NORMAL, unlike coverage

  `ScoutSystemCoverage` upserts on `(solar_system_id, kind)` because it holds
  one current fact. This table does NOT: every `assign/2` call is a new batch
  of rows under a fresh `assignment_id`, and old rows are left to expire or
  complete rather than being overwritten, so the history of who had what
  stays inspectable. "One owner per system per kind" is therefore enforced
  for ACTIVE rows only (`completed_at is nil and expires_at in the future`),
  and it is enforced in `WandererApp.Scout.Assignments.assign/2`, in Elixir
  -- a plain unique index cannot express "unique among rows matching a
  runtime-relative filter", the same reason `ScoutSystemCoverage`'s own
  staleness guard lives in Elixir rather than as an `upsert_condition`.

  ## Never map-scoped

  Same ruling as `ScoutSystemCoverage`: an assignment is a fact about a
  character and a system, not about a map, so there is no `map_id` column
  here at all (coverage at least keeps one as provenance; this doesn't even
  need that -- a split is requested by an operator, not posted by a map's
  API key).

  `expires_at` has no resource-level default; `WandererApp.Scout.Assignments.
  assign/2` always supplies one (its own default is now + 12h, operator-
  settable via that function's `opts`), so every row written through the one
  supported write path is correct, and this resource has no second,
  divergent source of truth for what "default" means.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("scout_assignments_v1")

    # The active-ownership check (`assign/2`'s conflict guard,
    # `active_system_ids/1`) filters by `(solar_system_id, kind)` plus
    # `completed_at`/`expires_at`; the character/kind pair backs
    # `owned_by/2`; `assignment_id` backs `release/1`.
    custom_indexes do
      index([:solar_system_id, :kind])
      index([:character_eve_id, :kind])
      index([:assignment_id])
      index([:expires_at])
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:active_for_kind, action: :active_for_kind, args: [:kind, :now])

    define(:active_for_character_and_kind,
      action: :active_for_character_and_kind,
      args: [:character_eve_id, :kind, :now]
    )

    define(:active_for_systems_and_kind,
      action: :active_for_systems_and_kind,
      args: [:solar_system_ids, :kind, :now]
    )

    define(:by_assignment_id, action: :by_assignment_id, args: [:assignment_id])
  end

  actions do
    default_accept [
      :assignment_id,
      :solar_system_id,
      :character_eve_id,
      :kind,
      :scope_label,
      :expires_at
    ]

    defaults [:create, :read, :destroy]

    # `WandererApp.Scout.Assignments.complete/2`'s write: not atomic (a
    # plain `utc_now()` default is a function call, same reason
    # `ScoutStructure`'s `:archive` action needs `require_atomic? false`),
    # and a one-row-at-a-time button is not worth more ceremony than that.
    update :mark_completed do
      require_atomic? false
      accept []

      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    # Every ACTIVE-row read below takes `now` as an explicit argument
    # rather than reaching for a DB-side `now()` -- same idiom `Planner`
    # and `Coverage` use everywhere else in this feature: the comparison
    # value is computed once in Elixir and passed in, not re-derived
    # inside the query.
    read :active_for_kind do
      argument :kind, :atom, allow_nil?: false
      argument :now, :utc_datetime, allow_nil?: false

      filter expr(kind == ^arg(:kind) and is_nil(completed_at) and expires_at > ^arg(:now))
    end

    read :active_for_character_and_kind do
      argument :character_eve_id, :string, allow_nil?: false
      argument :kind, :atom, allow_nil?: false
      argument :now, :utc_datetime, allow_nil?: false

      filter expr(
               character_eve_id == ^arg(:character_eve_id) and kind == ^arg(:kind) and
                 is_nil(completed_at) and expires_at > ^arg(:now)
             )
    end

    # Batched over a list of systems -- `Assignments.assign/2`'s conflict
    # check and `Coverage`'s completion hook both want "which of these
    # systems are actively assigned, and to whom" in one query rather than
    # one round trip per system.
    read :active_for_systems_and_kind do
      argument :solar_system_ids, {:array, :integer}, allow_nil?: false
      argument :kind, :atom, allow_nil?: false
      argument :now, :utc_datetime, allow_nil?: false

      filter expr(
               solar_system_id in ^arg(:solar_system_ids) and kind == ^arg(:kind) and
                 is_nil(completed_at) and expires_at > ^arg(:now)
             )
    end

    read :by_assignment_id do
      argument :assignment_id, :uuid, allow_nil?: false

      filter expr(assignment_id == ^arg(:assignment_id))
    end
  end

  attributes do
    uuid_primary_key :id

    # Groups every row written by one `Assignments.assign/2` call -- the
    # unit `release/1` drops whole.
    attribute :assignment_id, :uuid do
      allow_nil? false
    end

    attribute :solar_system_id, :integer do
      allow_nil? false
    end

    attribute :character_eve_id, :string do
      allow_nil? false
    end

    # Same closed vocabulary as `ScoutSystemCoverage.kind` -- see that
    # resource's moduledoc for why a fifth value is a planner change, not a
    # silently-accepted category.
    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: [:visit, :anoms, :sigs, :grid]
    end

    # Free-text provenance for the UI -- "Domain sweep, part 2 of 4" --
    # never read by any filter.
    attribute :scope_label, :string

    attribute :expires_at, :utc_datetime do
      allow_nil? false
    end

    attribute :completed_at, :utc_datetime

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
