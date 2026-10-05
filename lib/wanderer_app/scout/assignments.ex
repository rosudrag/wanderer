defmodule WandererApp.Scout.Assignments do
  @moduledoc """
  CHEWY PATCH: the orchestration module behind `WandererApp.Api.
  ScoutAssignment` -- writes one split's worth of rows atomically, answers
  "what is currently claimed" for the planner/sweep's hard-exclusion list,
  and closes rows out on expiry or on coverage arriving. See
  `docs/design/wanderer-scout-region-sweeps.md` section 5 and
  `WandererApp.Scout.Split` (the algorithm that decides WHO gets WHAT; this
  module only persists and enforces the result).

  ## The conflict guard is the whole point of this module existing

  `assign/2` refuses, rather than silently overwrites, a system that is
  ACTIVELY owned (not expired, not completed) by a DIFFERENT character --
  `{:error, :already_assigned}`. Re-assigning a system already owned by the
  SAME character is allowed (a caller re-running a split, or extending one,
  is not a conflict with itself); two groups in the same batch claiming the
  same system for two different characters is refused the same way, before
  either touches the database. This is the server-side version of what
  `obj_ScoutMemory`'s same-box claims do for one box -- except it works
  across characters on different boxes and for hours, not 15 minutes, which
  is exactly what `docs/design/wanderer-scout-region-sweeps.md` says a
  region split needs.

  ## `expires_at` is computed here, not in the resource

  `WandererApp.Api.ScoutAssignment` has no attribute-level default for
  `expires_at` on purpose -- the ONE write path into that table is
  `assign/2`, so the "now + 12h, operator-settable" default lives in exactly
  one place (`opts[:expires_at]` / `opts[:ttl_s]`) instead of being
  duplicatable between an Ash default and an Elixir fallback that could
  drift apart.
  """

  require Ash.Query

  alias WandererApp.Api.ScoutAssignment

  @type group :: %{character_eve_id: String.t(), system_ids: [integer()]}

  @kinds [:visit, :anoms, :sigs, :grid]
  @default_kind :sigs
  @default_ttl_s 12 * 3600

  # ---------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------

  @doc """
  Writes one `assignment_id` worth of rows for `groups` -- each group a
  character and the systems handed to it, e.g. `WandererApp.Scout.Split`'s
  parts after `WandererApp.Character.Tracker` resolves which character flies
  which part.

  opts:
    * `:kind` -- defaults `:sigs`, same closed vocabulary as
      `ScoutSystemCoverage`.
    * `:expires_at` -- explicit expiry; overrides `:ttl_s`.
    * `:ttl_s` -- seconds from now; defaults 12h. Ignored if `:expires_at`
      is given.
    * `:scope_label` -- free-text provenance stamped on every row.

  Errors: `:empty_groups`, `:invalid_groups` (malformed shape), `:invalid_kind`,
  `:conflicting_batch` (two groups in this call claim the same system for
  different characters), `:already_assigned` (a system is actively owned by
  a DIFFERENT character from an earlier call).
  """
  @spec assign([group()], keyword()) ::
          {:ok, %{assignment_id: String.t(), rows: non_neg_integer()}} | {:error, atom()}
  def assign(groups, opts \\ [])

  def assign(groups, _opts) when not is_list(groups) or groups == [], do: {:error, :empty_groups}

  def assign(groups, opts) do
    with :ok <- validate_groups(groups),
         {:ok, kind} <- fetch_kind(opts),
         :ok <- validate_no_batch_conflicts(groups) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      with :ok <- validate_no_active_conflicts(groups, kind, now) do
        do_assign(groups, kind, opts, now)
      end
    end
  end

  @doc """
  Every `solar_system_id` with an ACTIVE assignment (not expired, not
  completed) for `kind`. Fed straight into the sweep's `exclude` option --
  "assigned to someone else" is a hard zero, exactly like `avoid` (design
  doc section 5).
  """
  @spec active_system_ids(atom()) :: MapSet.t()
  def active_system_ids(kind) do
    now = now()

    case ScoutAssignment.active_for_kind(kind, now, authorize?: false) do
      {:ok, rows} -> rows |> Enum.map(& &1.solar_system_id) |> MapSet.new()
      {:error, _reason} -> MapSet.new()
    end
  end

  @doc "Every `solar_system_id` actively assigned to `character_eve_id` for `kind`."
  @spec owned_by(String.t(), atom()) :: [integer()]
  def owned_by(character_eve_id, kind) do
    now = now()

    case ScoutAssignment.active_for_character_and_kind(character_eve_id, kind, now,
           authorize?: false
         ) do
      {:ok, rows} -> rows |> Enum.map(& &1.solar_system_id) |> Enum.uniq()
      {:error, _reason} -> []
    end
  end

  @doc """
  Marks any ACTIVE assignment for `(solar_system_id, kind)` completed. Called
  by `WandererApp.Scout.Coverage`'s ingest hook the instant a coverage row
  lands -- NEVER raises, always returns `:ok`, because a completion-tracking
  side effect must not be able to fail the coverage ingest it hangs off.
  """
  @spec complete(integer(), atom()) :: :ok
  def complete(solar_system_id, kind) when kind in @kinds do
    now = now()

    ScoutAssignment
    |> Ash.Query.filter(
      solar_system_id == ^solar_system_id and kind == ^kind and is_nil(completed_at) and
        expires_at > ^now
    )
    |> Ash.bulk_update(:mark_completed, %{}, authorize?: false)

    :ok
  rescue
    _ -> :ok
  end

  def complete(_solar_system_id, _kind), do: :ok

  @doc "Drops every row under `assignment_id`, active or not."
  @spec release(String.t()) :: :ok
  def release(assignment_id) do
    ScoutAssignment
    |> Ash.Query.filter(assignment_id == ^assignment_id)
    |> Ash.bulk_destroy(:destroy, %{}, authorize?: false)

    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------
  # assign/2 internals
  # ---------------------------------------------------------------------

  defp validate_groups(groups) do
    if Enum.all?(groups, &valid_group?/1), do: :ok, else: {:error, :invalid_groups}
  end

  defp valid_group?(%{character_eve_id: char, system_ids: ids})
       when is_binary(char) and char != "" and is_list(ids) and ids != [] do
    Enum.all?(ids, &(is_integer(&1) and &1 > 0))
  end

  defp valid_group?(_group), do: false

  defp fetch_kind(opts) do
    case Keyword.get(opts, :kind, @default_kind) do
      kind when kind in @kinds -> {:ok, kind}
      kind when is_binary(kind) -> normalize_kind_string(kind)
      _other -> {:error, :invalid_kind}
    end
  end

  defp normalize_kind_string(kind) do
    normalized = String.downcase(kind)

    if normalized in ~w(visit anoms sigs grid) do
      {:ok, String.to_existing_atom(normalized)}
    else
      {:error, :invalid_kind}
    end
  rescue
    ArgumentError -> {:error, :invalid_kind}
  end

  # Two groups in the SAME call claiming the same system for two different
  # characters is a caller bug (a split's parts are supposed to be
  # disjoint) -- refused before anything touches the database, same
  # severity as an already-active conflict from an earlier call.
  defp validate_no_batch_conflicts(groups) do
    conflict? =
      groups
      |> Enum.flat_map(fn %{character_eve_id: char, system_ids: ids} ->
        Enum.map(ids, &{&1, char})
      end)
      |> Enum.group_by(fn {id, _char} -> id end, fn {_id, char} -> char end)
      |> Enum.any?(fn {_id, chars} -> chars |> Enum.uniq() |> length() > 1 end)

    if conflict?, do: {:error, :conflicting_batch}, else: :ok
  end

  defp validate_no_active_conflicts(groups, kind, now) do
    all_ids = groups |> Enum.flat_map(& &1.system_ids) |> Enum.uniq()

    case ScoutAssignment.active_for_systems_and_kind(all_ids, kind, now, authorize?: false) do
      {:ok, active_rows} ->
        owner_by_system = Map.new(active_rows, &{&1.solar_system_id, &1.character_eve_id})

        conflict? =
          Enum.any?(groups, fn %{character_eve_id: char, system_ids: ids} ->
            Enum.any?(ids, fn id ->
              case Map.get(owner_by_system, id) do
                nil -> false
                ^char -> false
                _other_character -> true
              end
            end)
          end)

        if conflict?, do: {:error, :already_assigned}, else: :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_assign(groups, kind, opts, now) do
    assignment_id = Ecto.UUID.generate()
    expires_at = resolve_expires_at(opts, now)
    scope_label = Keyword.get(opts, :scope_label)

    rows =
      Enum.flat_map(groups, fn %{character_eve_id: char, system_ids: ids} ->
        ids
        |> Enum.uniq()
        |> Enum.map(fn id ->
          %{
            assignment_id: assignment_id,
            solar_system_id: id,
            character_eve_id: char,
            kind: kind,
            scope_label: scope_label,
            expires_at: expires_at
          }
        end)
      end)

    case insert_rows(rows) do
      {:ok, _records} -> {:ok, %{assignment_id: assignment_id, rows: length(rows)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_expires_at(opts, now) do
    case Keyword.get(opts, :expires_at) do
      %DateTime{} = explicit ->
        DateTime.truncate(explicit, :second)

      _nil ->
        ttl_s = Keyword.get(opts, :ttl_s, @default_ttl_s)
        DateTime.add(now, ttl_s, :second)
    end
  end

  # `Ash.bulk_create/4` (the same idiom `EveDataService`/`TransactionsTrackerImpl`
  # use), not a loop of `ScoutAssignment.create/2` inside a manual `Repo.
  # transaction` -- the latter makes Ash warn-and-drop a notification per row
  # (it has no hook into when a RAW `Repo.transaction` commits), and
  # `transaction: :all` here gives one real atomic batch instead of N
  # Ash-internal transactions nested inside one outer Ecto one.
  defp insert_rows(rows) do
    case Ash.bulk_create(rows, ScoutAssignment, :create,
           authorize?: false,
           transaction: :all,
           return_records?: true,
           return_errors?: true,
           stop_on_error?: true
         ) do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, records}

      %Ash.BulkResult{errors: errors} ->
        {:error, inspect(errors)}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
