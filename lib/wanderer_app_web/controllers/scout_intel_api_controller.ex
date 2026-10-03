defmodule WandererAppWeb.ScoutIntelAPIController do
  @moduledoc """
  CHEWY PATCH: ingest endpoints for eveknob's scout logs.

    * `POST /api/maps/:map_identifier/scout/spawns` -- rows of
      `Config/Logs/special_spawns.tsv`
    * `POST /api/maps/:map_identifier/scout/structures` -- rows of
      `Config/Logs/structures.tsv`

  Both take `{"rows": [ ... ]}` where each row is the TSV line as an
  object. Field naming, value coercion and idempotence are
  `WandererApp.Scout.Ingest`'s job; this module only unwraps the envelope
  and shapes the response.

  ## Why these live under `/api/maps/:map_identifier`

  The data is fleet intel and is deliberately *not* map-scoped once
  stored. The route is, because that is the one pipeline (`:api_map`)
  that already authenticates a bot by a map's `public_api_key` -- the
  exact credential eveknob already holds and already sends for
  `POST /signatures/sync`. A second bearer secret would have to be
  minted, deployed and rotated to buy nothing. The authenticating map is
  recorded on each row as provenance.

  Gated by `WANDERER_SCOUT_INTEL`; with the flag off both routes answer
  404 like any nonexistent path.
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.Scout.Ingest

  @spawn_row_schema %OpenApiSpex.Schema{
    title: "ScoutSpawnRow",
    type: :object,
    description: """
    One line of `special_spawns.tsv`. Column names are accepted as-is;
    the resource's own names (`observed_at`, `solar_system_id`) work too.
    Values may be strings: they are coerced. A `character` column is
    accepted and IGNORED -- the log stores no submitter attribution.
    """,
    properties: %{
      utc_timestamp: %OpenApiSpex.Schema{
        type: :string,
        description:
          "UTC observation time, \"YYYY-MM-DD HH:MM:SS\" or ISO8601. Required. " <>
            "The local `timestamp` column is used only as a fallback."
      },
      system_id: %OpenApiSpex.Schema{type: :integer, description: "Solar system ID. Required."},
      system_name: %OpenApiSpex.Schema{type: :string},
      system_truesec: %OpenApiSpex.Schema{type: :number},
      location_type: %OpenApiSpex.Schema{type: :string, description: "belt, skyhook, ..."},
      location_name: %OpenApiSpex.Schema{type: :string},
      spawn_name: %OpenApiSpex.Schema{type: :string},
      spawn_category: %OpenApiSpex.Schema{type: :string, description: "faction, escalation, ..."},
      anomaly_type: %OpenApiSpex.Schema{type: :string},
      players_in_local: %OpenApiSpex.Schema{type: :integer},
      action_taken: %OpenApiSpex.Schema{type: :string},
      outcome: %OpenApiSpex.Schema{type: :string},
      entity_id: %OpenApiSpex.Schema{type: :integer},
      minutes_since_downtime: %OpenApiSpex.Schema{type: :integer},
      isk_value: %OpenApiSpex.Schema{type: :number}
    },
    required: [:utc_timestamp, :system_id],
    example: %{
      utc_timestamp: "2026-09-29 10:12:41",
      system_id: 30_002_698,
      system_name: "Aliette",
      system_truesec: 0.37128,
      location_type: "belt",
      location_name: "Aliette IV - Asteroid Belt 1",
      spawn_name: "Serpentis Clone Soldier Trainer",
      spawn_category: "faction",
      players_in_local: 4,
      action_taken: "scouted",
      outcome: "scouted",
      entity_id: 9_002_310_729_000_024_265,
      minutes_since_downtime: 1392,
      isk_value: 1_000_000.0
    }
  }

  @structure_row_schema %OpenApiSpex.Schema{
    title: "ScoutStructureRow",
    type: :object,
    description: """
    One line of `structures.tsv`.

    Two things to know about that file: its header row is stale (it names
    24 columns while the writer emits 26 -- `anchoring` and `unanchoring`
    sit between `vulnerable` and `timer_seconds`), and its `type_name`
    column holds the player-set structure name, not a type name. Post the
    fields by name and neither matters.

    The solar system name is resolved server-side from `system_id`
    against the static map, the same lookup the `/scout` page uses --
    posting it is no longer necessary. A `system_name` /
    `solar_system_name` field is still accepted for backward
    compatibility, but only as a last-resort fallback when server-side
    resolution comes back empty.
    """,
    properties: %{
      utc_timestamp: %OpenApiSpex.Schema{type: :string, description: "Required."},
      event: %OpenApiSpex.Schema{type: :string, enum: ["SEEN", "CHANGE"]},
      system_id: %OpenApiSpex.Schema{type: :integer, description: "Required."},
      system_truesec: %OpenApiSpex.Schema{type: :number},
      structure_id: %OpenApiSpex.Schema{type: :integer, description: "Required."},
      type_id: %OpenApiSpex.Schema{type: :integer},
      type_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Player-set structure name. Stored as structure_name."
      },
      group_name: %OpenApiSpex.Schema{type: :string, description: "Citadel, Refinery, ..."},
      owner_id: %OpenApiSpex.Schema{type: :integer},
      owner_name: %OpenApiSpex.Schema{type: :string},
      alliance_id: %OpenApiSpex.Schema{type: :integer},
      upkeep_state: %OpenApiSpex.Schema{type: :integer},
      upkeep_label: %OpenApiSpex.Schema{type: :string},
      structure_state: %OpenApiSpex.Schema{type: :integer},
      state_label: %OpenApiSpex.Schema{type: :string},
      vulnerable: %OpenApiSpex.Schema{type: :boolean},
      anchoring: %OpenApiSpex.Schema{type: :boolean},
      unanchoring: %OpenApiSpex.Schema{type: :boolean},
      timer_seconds: %OpenApiSpex.Schema{
        type: :integer,
        description: "Countdown relative to the observation; -1 means no timer."
      },
      shield_pct: %OpenApiSpex.Schema{type: :integer},
      armor_pct: %OpenApiSpex.Schema{type: :integer},
      hull_pct: %OpenApiSpex.Schema{type: :integer},
      distance_m: %OpenApiSpex.Schema{type: :integer},
      nearest_celestial: %OpenApiSpex.Schema{
        type: :string,
        description:
          "Closest static-map body to the STRUCTURE's position (not the observer's). " <>
            "Empty when the client could not resolve it yet -- never a guess."
      },
      nearest_celestial_m: %OpenApiSpex.Schema{
        type: :integer,
        description: "Metres from the structure to nearest_celestial."
      }
    },
    required: [:utc_timestamp, :system_id, :structure_id],
    example: %{
      utc_timestamp: "2026-09-27 17:38:15",
      event: "CHANGE",
      system_id: 30_002_099,
      system_truesec: 0.25287,
      structure_id: 1_055_680_805_214,
      type_id: 35_832,
      type_name: "Egmar - Bondage Gay website",
      group_name: "Citadel",
      owner_id: 98_790_508,
      owner_name: "Moonlight Mouse Hole",
      alliance_id: 99_014_050,
      upkeep_state: 1,
      upkeep_label: "FullPower",
      structure_state: 112,
      state_label: "ArmorVulnerable",
      vulnerable: true,
      anchoring: false,
      unanchoring: false,
      timer_seconds: 896,
      shield_pct: 0,
      armor_pct: 100,
      hull_pct: 100,
      distance_m: 225_354,
      nearest_celestial: "Egmar VI - Moon 3",
      nearest_celestial_m: 12_480
    }
  }

  @result_schema %OpenApiSpex.Schema{
    title: "ScoutIngestResult",
    type: :object,
    properties: %{
      received: %OpenApiSpex.Schema{type: :integer, description: "Rows in the payload."},
      stored: %OpenApiSpex.Schema{
        type: :integer,
        description: "Rows written. A re-sent row counts as stored: it upserts itself."
      },
      failed: %OpenApiSpex.Schema{type: :integer},
      errors: %OpenApiSpex.Schema{
        type: :array,
        description: "Up to 20 per-row failures; `failed` is always the exact count.",
        items: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            index: %OpenApiSpex.Schema{type: :integer, description: "0-based index in `rows`."},
            error: %OpenApiSpex.Schema{type: :string}
          }
        }
      }
    },
    example: %{received: 12, stored: 12, failed: 0, errors: []}
  }

  @map_identifier_parameter [
    in: :path,
    description: "Map identifier (UUID or slug) whose API key authenticates the post",
    type: :string,
    required: true
  ]

  operation(:spawns,
    summary: "Append scouted special-spawn observations to the scout log",
    description: """
    Takes rows of eveknob's `special_spawns.tsv`. Idempotent: rows are
    upserted on (observed_at, system, location, spawn), so a client that
    restarts and re-posts the tail of its file creates no duplicates.
    Two pilots reporting the same spawn at the same second collapse onto
    one row -- the log carries no submitter attribution.

    One malformed row does not reject the batch; it is reported in
    `errors` and the rest are stored.
    """,
    parameters: [map_identifier: @map_identifier_parameter],
    request_body:
      {"Spawn rows", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           rows: %OpenApiSpex.Schema{type: :array, items: @spawn_row_schema}
         },
         required: [:rows],
         example: %{rows: [@spawn_row_schema.example]}
       }},
    responses: [
      ok:
        {"Ingest result", "application/json",
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
           example: %{error: "rows must be an array of objects"}
         }}
    ]
  )

  def spawns(conn, params) do
    ingest(conn, params, &Ingest.ingest_spawns/2)
  end

  operation(:structures,
    summary: "Append scouted structure observations and timers to the scout log",
    description: """
    Takes rows of eveknob's `structures.tsv`. Idempotent: rows are
    upserted on (structure_id, observed_at, event).

    `timer_seconds` is resolved to an absolute expiry at ingest, so the
    log stays meaningful when read hours later.
    """,
    parameters: [map_identifier: @map_identifier_parameter],
    request_body:
      {"Structure rows", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           rows: %OpenApiSpex.Schema{type: :array, items: @structure_row_schema}
         },
         required: [:rows],
         example: %{rows: [@structure_row_schema.example]}
       }},
    responses: [
      ok:
        {"Ingest result", "application/json",
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
           example: %{error: "rows must be an array of objects"}
         }}
    ]
  )

  def structures(conn, params) do
    ingest(conn, params, &Ingest.ingest_structures/2)
  end

  defp ingest(conn, %{"rows" => rows}, ingest_fun) when is_list(rows) do
    case ingest_fun.(rows, conn.assigns[:map_id]) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, {:batch_too_large, max}} ->
        error(conn, "too many rows in one request, maximum is #{max}")

      {:error, reason} ->
        error(conn, to_string(reason))
    end
  end

  defp ingest(conn, _params, _ingest_fun),
    do: error(conn, "rows must be an array of objects")

  defp error(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})
end
