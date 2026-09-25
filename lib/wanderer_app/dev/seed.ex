defmodule WandererApp.Dev.Seed do
  @moduledoc """
  Idempotent, dev-only seeder that provisions a user, a character, and a map
  with a realistic (deliberately messy) k-space sample, so an agentic
  developer can log in via the dev-auth bypass (`GET /dev/login`, see
  `WandererAppWeb.DevAuthController`) and immediately have something worth
  looking at in the map UI — without an EVE Online account or EVE SSO.

  Contains NO Mix dependency, so it is callable from a compiled release:

      bin/wanderer_app eval 'WandererApp.Dev.Seed.run() |> IO.inspect()'

  From a source checkout, `mix wanderer.dev.seed` is a thin wrapper around
  this module (see `Mix.Tasks.Wanderer.Dev.Seed`).

  Running `run/1` twice is a no-op on the second run: the user, character,
  map, systems, and connections are all found-or-created / upserted against
  their natural identities, so nothing is duplicated.

  This module is never invoked automatically by the application — it must be
  called explicitly via the mix task or `eval`.
  """

  require Ash.Query
  require Logger

  alias WandererApp.Api.{
    Character,
    Map,
    MapCharacterSettings,
    MapConnection,
    MapSolarSystem,
    MapSystem,
    User
  }

  # Identity shared with WandererAppWeb.DevAuthController — both sides MUST
  # use exactly these values so the dev-login session lands on the same
  # user/character this seeder provisions.
  @dev_user_hash "dev-auth-agent"
  @dev_character_eve_id "2100000001"
  @dev_character_name "Agent Smith"

  # A real Heimatar/Metropolis low-sec/null-sec pocket (public EVE Online
  # static-universe data — no secrets). {solar_system_id, position_x,
  # position_y}.
  #
  # The layout is DELIBERATELY untidy: columns don't line up, spacing is
  # uneven, and a couple of systems (30000070, 30002983, 30002515) sit off on
  # their own away from the rest of the chain. This gives an agent something
  # real to fix with a beautify/auto-layout pass and lets that pass be
  # visually verified against a known-messy starting point.
  @systems [
    {30_002_090, 360, 525},
    {30_002_091, 540, 600},
    {30_000_070, 1260, 675},
    {30_002_092, 540, 675},
    {30_002_093, 540, 750},
    {30_002_983, 1260, 750},
    {30_002_094, 540, 825},
    {30_002_095, 540, 900},
    {30_002_537, 990, 915},
    {30_002_539, 540, 975},
    {30_002_540, 540, 1050},
    {30_002_541, 540, 1125},
    {30_002_542, 540, 1200},
    {30_002_515, 900, 1200},
    {30_003_068, 540, 1275}
  ]

  # {source, target, type}, type per WandererApp.Api.MapConnection's :type
  # attribute: 0 = wormhole, 1 = gate.
  @connections [
    {30_002_540, 30_002_541, 1},
    {30_002_541, 30_002_542, 1},
    {30_002_542, 30_002_537, 1},
    {30_002_541, 30_002_537, 1},
    {30_002_542, 30_002_515, 0},
    {30_002_542, 30_003_068, 1},
    {30_002_542, 30_002_539, 1},
    {30_002_539, 30_002_537, 1},
    {30_002_541, 30_002_539, 1},
    {30_002_539, 30_002_095, 1},
    {30_002_095, 30_002_093, 1},
    {30_002_093, 30_000_070, 0},
    {30_002_093, 30_002_983, 0},
    {30_002_093, 30_002_091, 1},
    {30_002_091, 30_002_090, 1},
    {30_002_090, 30_002_092, 1},
    {30_002_092, 30_002_094, 1}
  ]

  @type result :: %{
          user_id: binary(),
          character_eve_id: binary(),
          map_slug: binary(),
          map_id: binary(),
          sde_loaded: boolean()
        }

  @doc """
  Provisions (or reuses) the dev auth user/character and a dev map seeded
  with a 15-system / 17-connection k-space sample.

  ## Options

    * `:map_name` - display name for the map (default `"Agent Dev Map"`)
    * `:slug` - map slug / URL segment (default `"agent-dev-map"`)
    * `:reset_positions` - when true, rewrite every seeded system back to its
      original deliberately-messy coordinates. Upserting a system does not
      touch its position, so without this a second run leaves an already
      beautified map beautified, and there is nothing left to exercise.

  Safe to call repeatedly: reuses the existing user, character, map,
  systems, and connections instead of duplicating them.
  """
  @spec run(keyword()) :: {:ok, result()}
  def run(opts \\ []) do
    map_name = Keyword.get(opts, :map_name, "Agent Dev Map")
    slug = Keyword.get(opts, :slug, "agent-dev-map")

    sde_loaded? = sde_loaded?()

    unless sde_loaded? do
      Logger.warning(
        "[WandererApp.Dev.Seed] map_solar_system_v2 is empty — seeded systems will render " <>
          "with no names/class info. Run WandererApp.EveDataService.update_eve_data/0 first, " <>
          "then re-run this seeder."
      )
    end

    {:ok, user} = find_or_create_user()
    {:ok, character} = find_or_create_character(user)
    {:ok, map} = find_or_create_map(map_name, slug, character)
    {:ok, _settings} = track_character(map, character)

    :ok = seed_systems(map, sde_loaded?)
    :ok = seed_connections(map)

    if Keyword.get(opts, :reset_positions, false) do
      :ok = reset_positions(map)
    end

    # The map LiveView only renders systems that the map server holds in memory,
    # and the server loads them once at start. Without this a freshly seeded map
    # opens empty until something else happens to start it.
    :ok = start_map_server(map)

    Logger.warning("[WandererApp.Dev.Seed] dev map ready: /#{map.slug}")

    {:ok,
     %{
       user_id: user.id,
       character_eve_id: character.eve_id,
       map_slug: map.slug,
       map_id: map.id,
       sde_loaded: sde_loaded?
     }}
  end

  defp sde_loaded? do
    case Ash.count(MapSolarSystem, authorize?: false) do
      {:ok, count} when count > 0 -> true
      _other -> false
    end
  end

  defp find_or_create_user do
    case User.by_hash(@dev_user_hash, authorize?: false) do
      {:ok, user} ->
        {:ok, user}

      # WandererApp.Api.User exposes no `create` code interface, so go through the
      # changeset API directly, exactly as WandererAppWeb.AuthController does.
      {:error, _not_found} ->
        User
        |> Ash.Changeset.for_create(
          :create,
          %{name: @dev_character_name, hash: @dev_user_hash},
          authorize?: false
        )
        |> Ash.create()
    end
  end

  defp find_or_create_character(user) do
    case Character.by_eve_id(@dev_character_eve_id, authorize?: false) do
      {:ok, character} -> ensure_character_owner(character, user)
      {:error, _not_found} -> create_and_assign_character(user)
    end
  end

  defp ensure_character_owner(%{user_id: user_id} = character, %{id: user_id}),
    do: {:ok, character}

  defp ensure_character_owner(character, user),
    do: Character.assign_user(character, %{user_id: user.id}, authorize?: false)

  defp create_and_assign_character(user) do
    with {:ok, character} <-
           Character.create(
             %{eve_id: @dev_character_eve_id, name: @dev_character_name},
             authorize?: false
           ) do
      Character.assign_user(character, %{user_id: user.id}, authorize?: false)
    end
  end

  defp find_or_create_map(map_name, slug, owner_character) do
    case Map.get_map_by_slug(slug, authorize?: false) do
      {:ok, map} -> {:ok, map}
      {:error, _not_found} -> create_map(map_name, slug, owner_character)
    end
  end

  defp create_map(map_name, slug, owner_character) do
    Map.new(
      %{
        name: map_name,
        slug: slug,
        description: "Seeded dev map for UI verification without EVE SSO.",
        scope: :wormholes,
        only_tracked_characters: false,
        owner_id: owner_character.id,
        create_default_acl: true
      },
      authorize?: false
    )
  end

  defp track_character(map, character) do
    MapCharacterSettings.create(
      %{map_id: map.id, character_id: character.id, tracked: true},
      authorize?: false
    )
  end

  defp seed_systems(map, sde_loaded?) do
    Enum.each(@systems, fn {solar_system_id, position_x, position_y} ->
      {:ok, _system} =
        MapSystem.upsert(
          %{
            map_id: map.id,
            solar_system_id: solar_system_id,
            name: system_name(solar_system_id, sde_loaded?),
            position_x: position_x,
            position_y: position_y,
            visible: true
          },
          authorize?: false
        )
    end)

    :ok
  end

  # Positions are the one thing `upsert` leaves alone, which is what makes
  # re-running the seeder safe. `reset_positions: true` is the deliberate
  # opt-in that puts an already beautified map back into its messy shape.
  defp reset_positions(map) do
    Enum.each(@systems, fn {solar_system_id, position_x, position_y} ->
      case MapSystem.by_map_id_and_solar_system_id(map.id, solar_system_id, authorize?: false) do
        {:ok, system} ->
          {:ok, _system} =
            MapSystem.update_position(
              system,
              %{position_x: position_x, position_y: position_y},
              authorize?: false
            )

        _not_found ->
          :ok
      end
    end)

    :ok
  end

  defp start_map_server(map) do
    WandererApp.Map.Manager.start_map(map.id)
    :ok
  end

  defp system_name(solar_system_id, true) do
    case MapSolarSystem.by_solar_system_id(solar_system_id, authorize?: false) do
      {:ok, %{solar_system_name: name}} when is_binary(name) -> name
      _not_found -> Integer.to_string(solar_system_id)
    end
  end

  defp system_name(solar_system_id, false), do: Integer.to_string(solar_system_id)

  defp seed_connections(map) do
    Enum.each(@connections, fn {source, target, type} ->
      ensure_connection(map, source, target, type)
    end)

    :ok
  end

  # Connections have no identity to upsert against, so duplicate suppression is
  # a manual existence check. Two traps, both found by running this against a
  # live instance:
  #
  #   * `MapConnection`'s PRIMARY read is prepared with
  #     `FilterConnectionsByActorMap`, so an actor-less read returns nothing
  #     even with `authorize?: false` — the guard saw 0 and re-inserted every
  #     connection on the second run (34 rows instead of 17). The purpose-built
  #     `:read_by_locations` action filters on its own arguments instead.
  #   * A stored row is an unordered pair of endpoints, so a seed pair must be
  #     suppressed by a stored row in EITHER orientation.
  defp ensure_connection(map, source, target, type) do
    if connection_exists?(map, source, target) or connection_exists?(map, target, source) do
      :ok
    else
      {:ok, _connection} =
        MapConnection.create(
          %{
            map_id: map.id,
            solar_system_source: source,
            solar_system_target: target,
            type: type
          },
          authorize?: false
        )

      :ok
    end
  end

  defp connection_exists?(map, source, target) do
    args = %{map_id: map.id, solar_system_source: source, solar_system_target: target}

    case MapConnection.by_locations(args, authorize?: false) do
      {:ok, []} -> false
      {:ok, _found} -> true
      {:error, _reason} -> false
    end
  end
end
