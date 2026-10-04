defmodule WandererApp.Scout.Space do
  @moduledoc """
  CHEWY PATCH: the space-type filter shared by every table on `/scout`
  and by the CSV export — "show me lowsec and nullsec, drop highsec".

  ## Why the class, not the stored truesec

  Both sighting resources carry `system_truesec`, which looks like the
  cheap way to split high from low from null. It is not: J-space,
  Pochven and nullsec all sit at or below 0.0, so truesec cannot tell
  a wormhole from Delve, and the client may not have filled it in at
  all. The authoritative answer is `map_solar_system_v2.system_class`
  (7 = HS, 8 = LS, 9 = NS, 25 = Pochven, and
  `WandererApp.SystemClass.wormhole_classes/0` for W-space), so the
  filter is a subquery against that table keyed on `solar_system_id`.
  One index lookup per row in Postgres beats loading a 90-day window
  into the BEAM to classify it here, which is exactly what the page's
  `limit` exists to prevent.

  ## Total by construction

  `:other` is a real bucket — abyssal/Zarzakh classes and any system
  missing from the static table — expressed as the NOT-IN complement of
  every class the named buckets claim. Selecting all of them therefore
  means "no filter at all", and no row can vanish from the page unless
  the reader unticked the bucket it lives in. Unticking everything is
  allowed and shows nothing; the empty subquery says so without a
  special case.
  """

  require Ash.Query

  import Ecto.Query, only: [where: 3]

  alias WandererApp.SystemClass

  @hs 7
  @ls 8
  @ns 9
  @pochven 25

  # Order is the order the chips render in: the k-space ladder first,
  # because "drop highsec" is the filter this exists for.
  @types [
    {:hs, "High", [@hs]},
    {:ls, "Low", [@ls]},
    {:ns, "Null", [@ns]},
    {:wh, "W-Space", SystemClass.wormhole_classes()},
    {:pochven, "Pochven", [@pochven]},
    {:other, "Other", []}
  ]

  @keys Enum.map(@types, &elem(&1, 0))
  @named_classes @types |> Enum.flat_map(&elem(&1, 2)) |> Enum.sort()

  @doc "`[{key, label}]` in chip order."
  @spec types() :: [{atom(), String.t()}]
  def types, do: Enum.map(@types, fn {key, label, _classes} -> {key, label} end)

  @doc "Every bucket — the default selection, and the one that filters nothing."
  @spec all() :: [atom()]
  def all, do: @keys

  @spec all?([atom()]) :: boolean()
  def all?(selected), do: Enum.sort(selected) == Enum.sort(@keys)

  @doc """
  Parses a selection from the wire: a list of keys, or the
  comma-separated form the export URL carries. Anything unrecognised is
  dropped; `nil` and an absent parameter mean "everything", so a
  hand-written URL gives the unfiltered page rather than an empty one.

  An explicitly empty selection (`""`) stays empty — that is a reader
  who unticked every chip, not a missing parameter.
  """
  @spec parse(term()) :: [atom()]
  def parse(nil), do: all()

  def parse(value) when is_binary(value), do: value |> String.split(",", trim: true) |> parse()

  def parse(values) when is_list(values) do
    values
    |> Enum.map(&to_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def parse(_value), do: all()

  @doc "Flips one bucket, keeping chip order stable."
  @spec toggle([atom()], term()) :: [atom()]
  def toggle(selected, key) do
    case to_key(key) do
      nil -> selected
      key -> Enum.filter(@keys, &((&1 == key) != (&1 in selected)))
    end
  end

  @doc "The query-string form; `nil` when nothing is filtered out."
  @spec to_param([atom()]) :: String.t() | nil
  def to_param(selected) do
    if all?(selected), do: nil, else: selected |> Enum.map(&to_string/1) |> Enum.join(",")
  end

  @doc """
  Narrows an Ash query on either sighting resource. A no-op when every
  bucket is selected, so the common case costs nothing.
  """
  @spec filter(Ash.Query.t(), [atom()]) :: Ash.Query.t()
  def filter(query, selected) do
    if all?(selected) do
      query
    else
      ids = class_ids(selected)
      named = @named_classes

      if :other in selected do
        Ash.Query.filter(
          query,
          fragment(
            "(? IN (SELECT solar_system_id FROM map_solar_system_v2 WHERE system_class = ANY(?)) OR ? NOT IN (SELECT solar_system_id FROM map_solar_system_v2 WHERE system_class = ANY(?)))",
            solar_system_id,
            ^ids,
            solar_system_id,
            ^named
          )
        )
      else
        Ash.Query.filter(
          query,
          fragment(
            "? IN (SELECT solar_system_id FROM map_solar_system_v2 WHERE system_class = ANY(?))",
            solar_system_id,
            ^ids
          )
        )
      end
    end
  end

  @doc """
  The same predicate for `WandererApp.Scout.Stats`' schemaless Ecto
  queries, which have no Ash resource to hang a filter on.
  """
  @spec filter_ecto(Ecto.Query.t(), [atom()]) :: Ecto.Query.t()
  def filter_ecto(query, selected) do
    if all?(selected) do
      query
    else
      ids = class_ids(selected)
      named = @named_classes

      if :other in selected do
        where(
          query,
          [s],
          fragment(
            "(? IN (SELECT solar_system_id FROM map_solar_system_v2 WHERE system_class = ANY(?)) OR ? NOT IN (SELECT solar_system_id FROM map_solar_system_v2 WHERE system_class = ANY(?)))",
            s.solar_system_id,
            ^ids,
            s.solar_system_id,
            ^named
          )
        )
      else
        where(
          query,
          [s],
          fragment(
            "? IN (SELECT solar_system_id FROM map_solar_system_v2 WHERE system_class = ANY(?))",
            s.solar_system_id,
            ^ids
          )
        )
      end
    end
  end

  # The class ids the named buckets in `selected` claim. `:other` has
  # none of its own by construction — it IS the complement.
  defp class_ids(selected) do
    @types
    |> Enum.filter(fn {key, _label, _classes} -> key in selected end)
    |> Enum.flat_map(fn {_key, _label, classes} -> classes end)
  end

  defp to_key(key) when is_atom(key), do: if(key in @keys, do: key, else: nil)

  defp to_key(key) when is_binary(key) do
    Enum.find(@keys, &(to_string(&1) == key))
  end

  defp to_key(_key), do: nil
end
