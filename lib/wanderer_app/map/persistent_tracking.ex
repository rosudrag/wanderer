defmodule WandererApp.Map.PersistentTracking do
  @moduledoc """
  CHEWY PATCH. Keeps character tracking alive while nobody has the map open.

  Upstream ties tracking to Phoenix presence: the map server untracks a
  character as soon as its LiveView disconnects (`Impl.update_presence/1`), and
  the map pool shuts the map server down entirely once presence is empty
  (`MapPool.handle_info(:garbage_collect, ...)`). Close the browser tab and the
  chain stops recording — which is exactly when a roam is happening.

  With `WANDERER_PERSIST_TRACKING=true` the DB flag `map_character_settings_v1.
  tracked` becomes the authority instead of presence:

    * a character the user explicitly tracked keeps its ESI polling when the
      tab closes — the map keeps adding systems as they fly
    * a map with at least one tracked character is not garbage collected
    * on boot, those maps are started again, so a deploy or restart does not
      silently end tracking until someone visits the site

  Everything here is a no-op when the flag is off, so the upstream behaviour is
  one env var away and this module never has to be reverted to take a release.

  Deliberately a separate module with the hooks reduced to one-liners at each
  call site: upstream rewrites `map_server_impl.ex` and `map_pool.ex` often, and
  a one-line call is a merge conflict that resolves itself.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  @doc "Whether persistent tracking is on. `WANDERER_PERSIST_TRACKING`."
  def enabled?, do: WandererApp.Env.persist_tracking?()

  @doc """
  Character ids with `tracked: true` in the DB for this map.

  These are the characters the user asked to track, not the ones whose browser
  happens to be open.
  """
  def tracked_character_ids(map_id) do
    case WandererApp.MapCharacterSettingsRepo.get_tracked_by_map_all(map_id) do
      {:ok, settings} -> Enum.map(settings, & &1.character_id)
      _ -> []
    end
  end

  @doc """
  Removes persistently tracked characters from a list about to be untracked.

  Called with the presence-departed characters; what comes back is the subset
  that really should stop being polled.
  """
  def filter_untrack(_map_id, []), do: []

  def filter_untrack(map_id, character_ids) do
    if enabled?() do
      keep = MapSet.new(tracked_character_ids(map_id))

      {kept, untrack} = Enum.split_with(character_ids, &MapSet.member?(keep, &1))

      if kept != [] do
        Logger.info(fn ->
          "[PersistentTracking] Map #{map_id} - keeping #{length(kept)} character(s) tracked " <>
            "after presence left: #{inspect(kept)}"
        end)
      end

      untrack
    else
      character_ids
    end
  end

  @doc """
  True when the map must stay running even with nobody present.

  Guards the map pool's garbage collector: stopping the server would take the
  tracking down with it, since the ESI poller feeds map updates through it.
  """
  def keep_map_running?(map_id), do: enabled?() and tracked_character_ids(map_id) != []

  @doc """
  Starts tracking for every DB-tracked character on a map that just started.

  Upstream only ever starts tracking from a presence join, so without this a
  restarted map server sits idle until someone opens the tab — the exact gap
  this feature exists to close.
  """
  def resume(map_id) do
    if enabled?() do
      case tracked_character_ids(map_id) do
        [] ->
          :ok

        character_ids ->
          Logger.info(fn ->
            "[PersistentTracking] Map #{map_id} - resuming tracking for " <>
              "#{length(character_ids)} character(s) with no presence: #{inspect(character_ids)}"
          end)

          WandererApp.Map.Server.CharactersImpl.track_characters(map_id, character_ids)
      end
    else
      :ok
    end
  end

  @doc """
  Every map that has at least one tracked character, for boot-time startup.

  A direct query rather than an Ash action on purpose: an extra action would
  mean editing `api/map_character_settings.ex`, and a resource file is the kind
  upstream reshuffles. `map_character_settings_v1` is the table that resource
  declares.
  """
  def map_ids_to_start do
    if enabled?() do
      from(s in "map_character_settings_v1",
        where: s.tracked == true,
        distinct: true,
        select: type(s.map_id, Ecto.UUID)
      )
      |> WandererApp.Repo.all()
    else
      []
    end
  rescue
    error ->
      Logger.error("[PersistentTracking] Failed to list maps to start: #{inspect(error)}")
      []
  end
end
