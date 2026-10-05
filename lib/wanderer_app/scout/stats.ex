defmodule WandererApp.Scout.Stats do
  @moduledoc """
  CHEWY PATCH: the aggregate reads behind `WandererAppWeb.ScoutIntelLive`
  that an Ash read action cannot express.

  Two of them, both schemaless Ecto against the two scout tables:

    * `last_observed_at/0` — how fresh the log is. Without it a dead
      eveknob client and a quiet region render identically, which is the
      one failure mode of a push-only log.

    * `totals/0` — "nothing ever reported" vs "nothing in this window".
      Only called when a table came back empty, because `count(*)` on an
      append-only table is a sequential scan.

  The table names are literals rather than the resources' `postgres do
  table ... end`, which is a real coupling: renaming a table means
  editing here too. Deliberate — the alternative is `Ash.Resource.Info`
  lookups at runtime to save one grep.
  """

  import Ecto.Query

  alias WandererApp.Repo

  @spawns "scout_spawn_sightings_v1"

  # CURRENT STATE, not the retired sighting tape. The presence feed
  # (`WandererApp.Scout.Snapshot`) writes `scout_structures_v1` and
  # nothing else, so reading `scout_structure_sightings_v1` here froze
  # the header's "structures Nh ago" at whenever the last client on the
  # old per-row feed posted -- a dead-client indicator that reports a
  # live client as dead. `last_confirmed_at` is this table's
  # observation clock.
  @structures "scout_structures_v1"
  @structures_observed_at :last_confirmed_at

  @doc """
  Newest observation in each log, or `nil` for an empty one. Cheap: both
  tables carry an index on `observed_at`.
  """
  @spec last_observed_at() :: %{spawns: DateTime.t() | nil, structures: DateTime.t() | nil}
  def last_observed_at do
    %{
      spawns: max_observed_at(@spawns),
      structures: max_observed_at(@structures, @structures_observed_at)
    }
  end

  @doc """
  Row counts for both logs, ignoring any window. Call only on an empty
  table: this is a sequential scan.
  """
  @spec totals() :: %{spawns: non_neg_integer(), structures: non_neg_integer()}
  def totals do
    %{
      spawns: Repo.one(from(s in @spawns, select: count())),
      structures: Repo.one(from(s in @structures, select: count()))
    }
  end

  defp max_observed_at(table, column \\ :observed_at) do
    from(s in table, select: max(field(s, ^column)))
    |> Repo.one()
    |> to_utc()
  end

  # Schemaless Ecto hands back whatever Postgrex decoded, and these
  # columns are `timestamp(0)` without a zone, i.e. NaiveDateTime. The
  # page formats DateTimes.
  defp to_utc(nil), do: nil
  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc(%DateTime{} = datetime), do: datetime
end
