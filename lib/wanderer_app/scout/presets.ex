defmodule WandererApp.Scout.Presets do
  @moduledoc """
  CHEWY PATCH: named, saved `/scout/planner` control sets, per user.

  Storage is `WandererApp.Api.ScoutPlannerPreset` (see that resource for why
  the state is one jsonb column and not a column per control); this module is
  the only supported write path, the same split every other scout feature
  uses (`Coverage` over `ScoutSystemCoverage`, `Assignments` over
  `ScoutAssignment`).

  What it owns beyond the four CRUD calls:

    * **Name discipline.** A name is trimmed, collapsed on internal
      whitespace and capped at 60 characters. An empty name is refused
      rather than stored, because a blank row in the preset list is
      indistinguishable from a bug, and `(user_id, name)` is the identity
      the upsert writes on -- "" would collide with the next blank save.
    * **A ceiling.** 50 presets per user. Nothing in the UI pages the
      list, and an unbounded list behind a one-click Save button is how a
      dropdown becomes unusable; the error names the cap rather than failing
      silently.

  Every call is scoped by `user_id` and the reads filter on it in SQL -- a
  preset is one user's, and this module never takes an id without also
  taking the user it must belong to (`delete/2`, `get/2`).
  """

  alias WandererApp.Api.ScoutPlannerPreset

  require Logger

  @max_name_length 60
  @max_presets 50

  @doc "Every preset this user has saved, name order."
  def list(user_id) when is_binary(user_id) do
    case ScoutPlannerPreset.by_user(user_id) do
      {:ok, presets} -> presets
      {:error, reason} -> log_error("list", reason)
    end
  end

  def list(_user_id), do: []

  @doc """
  Saves `state` under `name` for this user, replacing a preset of the same
  name (`:uniq_user_preset` upsert).

  Returns `{:ok, preset}`, or `{:error, :blank_name | {:too_many, max} |
  :failed}`.
  """
  def save(user_id, name, state) when is_binary(user_id) and is_map(state) do
    with {:ok, name} <- normalize_name(name),
         :ok <- check_capacity(user_id, name) do
      case ScoutPlannerPreset.upsert(%{user_id: user_id, name: name, state: state}) do
        {:ok, preset} ->
          {:ok, preset}

        {:error, reason} ->
          log_error("save", reason)
          {:error, :failed}
      end
    end
  end

  @doc "One preset by id, refusing it if it is not this user's."
  def get(user_id, id) when is_binary(user_id) and is_binary(id) do
    case Ash.get(ScoutPlannerPreset, id) do
      {:ok, %{user_id: ^user_id} = preset} -> {:ok, preset}
      {:ok, _other_users_preset} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  def get(_user_id, _id), do: {:error, :not_found}

  @doc "Deletes one of this user's presets. A preset that is already gone is `:ok`."
  def delete(user_id, id) do
    case get(user_id, id) do
      {:ok, preset} ->
        case Ash.destroy(preset) do
          :ok ->
            :ok

          {:ok, _destroyed} ->
            :ok

          {:error, reason} ->
            log_error("delete", reason)
            {:error, :failed}
        end

      {:error, :not_found} ->
        :ok
    end
  end

  @doc "The cap `save/3` enforces, so the UI can say it before the click."
  def max_presets, do: @max_presets

  @doc "The length `save/3` truncates a name to."
  def max_name_length, do: @max_name_length

  defp normalize_name(name) when is_binary(name) do
    normalized =
      name
      |> String.trim()
      |> String.replace(~r/\s+/u, " ")
      |> String.slice(0, @max_name_length)

    if normalized == "", do: {:error, :blank_name}, else: {:ok, normalized}
  end

  defp normalize_name(_name), do: {:error, :blank_name}

  # Overwriting an existing name is always allowed -- the cap is on how many
  # DISTINCT presets exist, and refusing to re-save one a user already has is
  # the one case where the limit would be actively wrong.
  defp check_capacity(user_id, name) do
    presets = list(user_id)

    cond do
      Enum.any?(presets, &(&1.name == name)) -> :ok
      length(presets) < @max_presets -> :ok
      true -> {:error, {:too_many, @max_presets}}
    end
  end

  defp log_error(op, reason) do
    Logger.error("[scout presets] #{op} failed: #{inspect(reason)}")
    []
  end
end
