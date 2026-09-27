defmodule WandererApp.Identity.Gdpr do
  @moduledoc """
  Every phase that adds a PII-bearing, user-linked resource must implement
  and register a `purge_for_user/1` callback here — mirrors the retention
  discipline `WandererApp.Sync.Feed` will enforce for ESI data in a later
  phase. See docs/chewy/corp-suite-plan.md §2.8.6.
  """

  @callback purge_for_user(user_id :: Ecto.UUID.t()) :: :ok

  @purgeable [WandererApp.Identity.Gdpr.CorePurge]

  @doc """
  Soft-deletes `user` (via the same `disable!/3`-shaped override used for
  account recovery, §2.8.3 — never a hard delete) and calls every
  registered `purge_for_user/1` callback. Scrubs directly-identifying
  fields; does not touch financial/audit records, which must survive a
  user's deletion per docs/chewy/corp-suite-plan.md §2.8.6's explicit
  "must NOT delete" list.
  """
  def delete_user!(%WandererApp.Api.User{} = user) do
    case WandererApp.Api.UserIdentity.by_user(user.id) do
      {:ok, identity} ->
        {:ok, _identity} =
          identity
          |> WandererApp.Api.UserIdentity.disable(%{
            disabled_at: DateTime.utc_now(),
            disabled_reason: "gdpr_deletion"
          })

        WandererApp.Identity.StateEngine.recompute!(user)

      _ ->
        :ok
    end

    WandererApp.Identity.Audit.log!(%{
      actor_user_id: nil,
      target_user_id: user.id,
      action: :gdpr_deletion,
      details: %{}
    })

    Enum.each(@purgeable, & &1.purge_for_user(user.id))
    :ok
  end
end

defmodule WandererApp.Identity.Gdpr.CorePurge do
  @moduledoc false
  @behaviour WandererApp.Identity.Gdpr

  alias WandererApp.Api.{Character, User}

  @impl true
  def purge_for_user(user_id) do
    case User.by_id(user_id) do
      {:ok, user} ->
        user
        |> Ash.Changeset.for_update(:update, %{name: "[deleted]", hash: nil})
        |> Ash.update!()

        {:ok, characters} = Character.active_by_user(user_id)
        Enum.each(characters, &scrub_character!/1)

      _ ->
        :ok
    end

    :ok
  end

  defp scrub_character!(character) do
    {:ok, character} = Character.update(character, %{name: "[deleted]"})
    Character.mark_as_deleted(character)
  end
end
