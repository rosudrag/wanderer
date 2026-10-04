defmodule WandererApp.Scout.Merge do
  @moduledoc """
  CHEWY PATCH: collapses a repeat structure observation into the row it
  repeats, instead of appending another one.

  The eveknob client re-reports every structure on grid on every pass, so
  a Fortizar sitting in armor reinforcement for 36 hours used to produce
  one row per pass — hundreds of rows saying exactly the same thing. The
  page folds to latest-per-structure at read time, so this never showed
  as duplicates once that fold was right, but the table still grew
  linearly in poll frequency and the per-structure history drill-down was
  unreadable: 200 identical lines where three state changes happened.

  ## The rule

  A row is merged into the previous sighting of the same structure when
  **both are `SEEN`** and nothing a reader would act on has changed:
  status, the timer, ownership, the name, the vulnerability flags and the
  HP readings (`changed_fields/0` is the exact list). The stored row's
  `observed_at` moves forward to the new sighting's, so "Seen 4m ago"
  stays honest, and the timer estimate is refreshed with it.

  Anything else inserts:

    * `event: :change` — the writer already decided this is news. Never
      merged, in either direction: the history exists for these.
    * any field in `changed_fields/0` differing — that IS the news.
    * no previous sighting, or the incoming row is older than the stored
      one (a client replaying an old file tail).

  ## Timers are compared with a tolerance

  `timer_expires_at` is derived at ingest from the client's relative
  `timer_seconds`, which is re-read each pass and drifts by the time
  between the client's read and the POST. Comparing for equality would
  make every pass "a change" and defeat the whole module, so two expiries
  within `@timer_tolerance_seconds` are the same timer.
  """

  require Ash.Query
  require Logger

  alias WandererApp.Api.ScoutStructureSighting

  # Two minutes: far below the shortest real timer change (a
  # reinforcement cycle is hours) and far above the client's own jitter.
  @timer_tolerance_seconds 120

  @changed_fields [
    :status,
    :event,
    :owner_id,
    :owner_name,
    :alliance_id,
    :structure_name,
    :group_name,
    :solar_system_id,
    :vulnerable,
    :anchoring,
    :unanchoring,
    :upkeep_state,
    :structure_state,
    :shield_pct,
    :armor_pct,
    :hull_pct
  ]

  @doc "The fields whose difference makes an observation news."
  @spec changed_fields() :: [atom()]
  def changed_fields, do: @changed_fields

  @doc """
  Writes one structure observation, merging it into the previous sighting
  when it repeats it.

  Returns whatever the underlying Ash call returns, so the ingest's
  per-row error reporting is unchanged.
  """
  @spec upsert_structure(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def upsert_structure(attrs, opts \\ []) do
    case previous(attrs) do
      {:ok, previous} -> touch(previous, attrs, opts)
      :none -> ScoutStructureSighting.upsert(attrs, opts)
    end
  end

  # The newest stored sighting of this structure, when the incoming row
  # repeats it. `nil` structure_id cannot happen (allow_nil?: false) but
  # costs nothing to guard.
  defp previous(%{structure_id: structure_id} = attrs) when not is_nil(structure_id) do
    ScoutStructureSighting
    |> Ash.Query.filter(structure_id == ^structure_id)
    |> Ash.Query.sort(observed_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [previous]} -> if mergeable?(previous, attrs), do: {:ok, previous}, else: :none
      _ -> :none
    end
  end

  defp previous(_attrs), do: :none

  defp mergeable?(previous, attrs) do
    Map.get(attrs, :event, :seen) == :seen and previous.event == :seen and
      not_older?(previous, attrs) and
      Enum.all?(@changed_fields, &(Map.get(previous, &1) == Map.get(attrs, &1))) and
      same_timer?(previous.timer_expires_at, Map.get(attrs, :timer_expires_at))
  end

  # A client replaying an old tail must never drag a row's `observed_at`
  # backwards: "seen 4m ago" is the field this module exists to keep true.
  defp not_older?(previous, attrs) do
    case Map.get(attrs, :observed_at) do
      nil -> false
      observed_at -> DateTime.compare(observed_at, previous.observed_at) != :lt
    end
  end

  defp same_timer?(nil, nil), do: true
  defp same_timer?(nil, _new), do: false
  defp same_timer?(_old, nil), do: false

  defp same_timer?(old, new),
    do: abs(DateTime.diff(old, new, :second)) <= @timer_tolerance_seconds

  # Moves the stored row forward rather than writing a new one. The timer
  # fields come along: the newer reading of the same timer is the better
  # estimate of when it comes out.
  #
  # `observed_at` is part of `:uniq_sighting`, so this can collide with an
  # already-stored row at exactly that instant (a client posting the same
  # line twice). That is precisely a duplicate, so the collision is
  # swallowed and the stored row kept.
  defp touch(previous, attrs, opts) do
    previous
    |> Ash.Changeset.for_update(
      :touch,
      Map.take(attrs, [:observed_at, :timer_seconds, :timer_expires_at, :distance_m]),
      opts
    )
    |> Ash.update(Keyword.put(opts, :authorize?, false))
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, _reason} -> {:ok, previous}
    end
  end
end
