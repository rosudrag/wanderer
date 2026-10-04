defmodule WandererAppWeb.ScoutSnapshotAPIController do
  @moduledoc """
  CHEWY PATCH: ingest endpoint for eveknob's structure presence feed.

    * `POST /api/maps/:map_identifier/scout/structures/snapshot` -- the
      COMPLETE set of structures one sweep can see, plus the sphere it
      proves (`observer_x/y/z`, `horizon_m`). The server diffs it
      against stored current state and derives `appeared` / `changed` /
      `cleared` / `missing` / `gone`.

  Takes the blob as the raw JSON body (no `{"rows": [...]}` envelope --
  unlike the per-row feeds, this is one object per POST). Validation,
  normalization and the diff/apply pipeline are
  `WandererApp.Scout.Snapshot`'s job; this module only shapes the
  response. See `docs/design/wanderer-scout-presence.md` for the full
  wire contract.

  ## Why this lives under `/api/maps/:map_identifier`

  Same reasoning as `WandererAppWeb.ScoutIntelAPIController`: this is the
  one pipeline (`:api_map`) that already authenticates a bot by a map's
  `public_api_key`, the exact credential eveknob already holds. The
  stored state is NOT map-scoped; the authenticating map is recorded on
  each row as provenance only.

  Gated by `WANDERER_SCOUT_PRESENCE`; with the flag off the route
  answers 404 like any nonexistent path.
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.Scout.Snapshot

  @structure_schema %OpenApiSpex.Schema{
    title: "ScoutSnapshotStructure",
    type: :object,
    description: """
    One notable structure on grid. Every value may arrive as a string --
    the client's only JSON escaping primitive always emits quoted
    strings. `type_name` carries the player-set structure name (stored
    as `structure_name`); a record whose `pos_x`/`pos_y`/`pos_z` are
    empty still stores, but is never archivable (excluded from removal).
    """,
    properties: %{
      structure_id: %OpenApiSpex.Schema{type: :string, description: "Required."},
      type_id: %OpenApiSpex.Schema{type: :string},
      type_name: %OpenApiSpex.Schema{type: :string},
      group_name: %OpenApiSpex.Schema{type: :string},
      owner_id: %OpenApiSpex.Schema{type: :string},
      owner_name: %OpenApiSpex.Schema{type: :string},
      alliance_id: %OpenApiSpex.Schema{type: :string},
      upkeep_state: %OpenApiSpex.Schema{type: :string},
      structure_state: %OpenApiSpex.Schema{type: :string},
      status: %OpenApiSpex.Schema{type: :string},
      vulnerable: %OpenApiSpex.Schema{type: :string},
      anchoring: %OpenApiSpex.Schema{type: :string},
      unanchoring: %OpenApiSpex.Schema{type: :string},
      timer_seconds: %OpenApiSpex.Schema{type: :string},
      shield_pct: %OpenApiSpex.Schema{type: :string},
      armor_pct: %OpenApiSpex.Schema{type: :string},
      hull_pct: %OpenApiSpex.Schema{type: :string},
      pos_x: %OpenApiSpex.Schema{type: :string},
      pos_y: %OpenApiSpex.Schema{type: :string},
      pos_z: %OpenApiSpex.Schema{type: :string},
      nearest_celestial: %OpenApiSpex.Schema{type: :string},
      nearest_celestial_m: %OpenApiSpex.Schema{type: :string}
    },
    required: [:structure_id]
  }

  @result_schema %OpenApiSpex.Schema{
    title: "ScoutSnapshotResult",
    type: :object,
    properties: %{
      structures: %OpenApiSpex.Schema{type: :integer, description: "Notable records in the blob."},
      steady: %OpenApiSpex.Schema{type: :integer, description: "Bare ids in the blob."},
      appeared: %OpenApiSpex.Schema{type: :integer},
      changed: %OpenApiSpex.Schema{type: :integer},
      cleared: %OpenApiSpex.Schema{type: :integer},
      missing: %OpenApiSpex.Schema{type: :integer},
      gone: %OpenApiSpex.Schema{type: :integer},
      skipped: %OpenApiSpex.Schema{type: :integer},
      errors: %OpenApiSpex.Schema{
        type: :array,
        description: "Up to 20 per-row failures.",
        items: %OpenApiSpex.Schema{type: :object}
      }
    },
    example: %{
      structures: 1,
      steady: 2,
      appeared: 1,
      changed: 0,
      cleared: 0,
      missing: 0,
      gone: 0,
      skipped: 0,
      errors: []
    }
  }

  @map_identifier_parameter [
    in: :path,
    description: "Map identifier (UUID or slug) whose API key authenticates the post",
    type: :string,
    required: true
  ]

  operation(:snapshot,
    summary: "Post the complete structure snapshot for one system sweep",
    description: """
    The server diffs this blob against stored current state
    (`WandererApp.Api.ScoutStructure`) and derives appeared/changed/
    cleared/missing/gone. `observer_x/y/z` and `horizon_m` scope the
    sphere removal is computed inside -- absence outside that sphere is
    never inferred. A blob that saw nothing (`structures` and
    `steady_ids` both empty) is refused.

    A per-structure row that fails coercion is skipped, reported in
    `errors`, and the batch is still applied for every other row --
    except a blob with any skipped row is never used to compute `missing`,
    since a truncated list cannot prove absence.
    """,
    parameters: [map_identifier: @map_identifier_parameter],
    request_body:
      {"Snapshot blob", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           solar_system_id: %OpenApiSpex.Schema{type: :string, description: "Required."},
           observed_at: %OpenApiSpex.Schema{
             type: :string,
             description: "EVE server time, unix-epoch seconds. Required."
           },
           source: %OpenApiSpex.Schema{type: :string},
           observer_x: %OpenApiSpex.Schema{type: :string, description: "Required."},
           observer_y: %OpenApiSpex.Schema{type: :string, description: "Required."},
           observer_z: %OpenApiSpex.Schema{type: :string, description: "Required."},
           horizon_m: %OpenApiSpex.Schema{type: :string, description: "Required, > 0."},
           structures: %OpenApiSpex.Schema{type: :array, items: @structure_schema},
           steady_ids: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}}
         },
         required: [:solar_system_id, :observed_at, :observer_x, :observer_y, :observer_z, :horizon_m],
         example: %{
           solar_system_id: "30000142",
           observed_at: "1759574400",
           source: "eveknob/1.0",
           observer_x: "-120000000000",
           observer_y: "34000000000",
           observer_z: "780000000000",
           horizon_m: "820000000",
           structures: [],
           steady_ids: ["1047987654321"]
         }
       }},
    responses: [
      ok:
        {"Diff result", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{data: @result_schema},
           example: %{data: @result_schema.example}
         }},
      unprocessable_entity:
        {"Validation error", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{error: %OpenApiSpex.Schema{type: :string}},
           example: %{error: "horizon_m is required and must be greater than 0"}
         }}
    ]
  )

  def snapshot(conn, params) do
    body = Map.drop(params, ["map_identifier"])

    case Snapshot.ingest(conn.assigns[:map_id], body) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, :no_observation} ->
        error(conn, "a blob that saw nothing (empty structures and steady_ids) proves nothing")

      {:error, {:batch_too_large, max}} ->
        error(conn, "too many ids in one blob, maximum is #{max}")

      {:error, reason} when is_binary(reason) ->
        error(conn, reason)

      {:error, reason} ->
        error(conn, inspect(reason))
    end
  end

  defp error(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})
end
