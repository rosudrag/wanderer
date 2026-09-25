defmodule Mix.Tasks.Wanderer.Dev.Seed do
  @moduledoc """
  Seeds a dev user, character, and map so the map UI can be exercised
  without an EVE Online account or EVE SSO (see `WandererApp.Dev.Seed` and
  `WandererAppWeb.DevAuthController` / `GET /dev/login`).

  This is a thin wrapper: all logic lives in `WandererApp.Dev.Seed.run/1`,
  which has no Mix dependency and is idempotent.

  ## Usage

      mix wanderer.dev.seed
      mix wanderer.dev.seed --map-name "My Map" --slug my-map

  ## In a release

  Mix tasks do not exist in a compiled release. From a release, call the
  seeder directly instead:

      bin/wanderer_app eval 'WandererApp.Dev.Seed.run() |> IO.inspect()'
  """

  use Mix.Task

  @shortdoc "Seeds a dev user/character/map for UI verification without EVE SSO"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args, strict: [map_name: :string, slug: :string])

    Mix.Task.run("app.start")

    seed_opts =
      opts
      |> Enum.flat_map(fn
        {:map_name, value} -> [map_name: value]
        {:slug, value} -> [slug: value]
      end)

    case WandererApp.Dev.Seed.run(seed_opts) do
      {:ok, result} ->
        Mix.shell().info("✅ Dev seed complete: #{inspect(result)}")

      {:error, reason} ->
        Mix.shell().error("❌ Dev seed failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
