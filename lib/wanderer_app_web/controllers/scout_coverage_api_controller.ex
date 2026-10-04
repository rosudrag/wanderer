defmodule WandererAppWeb.ScoutCoverageAPIController do
  @moduledoc """
  CHEWY PATCH: ingest endpoint for eveknob's scout-coverage reports.

    * `POST /api/maps/:map_identifier/scout/coverage` -- rows saying "I
      finished looking at system S to depth K at time T", posted even
      when nothing was found there.

  Takes `{"rows": [ ... ]}` where each row is one coverage report.
  Row shape, `observed_at` coercion and the stale-skip rule are
  `WandererApp.Scout.Coverage`'s job; this module only unwraps the
  envelope and shapes the response -- same split as
  `WandererAppWeb.ScoutIntelAPIController`.

  ## Why this lives under `/api/maps/:map_identifier`

  Coverage is a fact about the SYSTEM and is deliberately *not*
  map-scoped once stored (see `WandererApp.Api.ScoutSystemCoverage`'s
  module doc). The route is, because that is the one pipeline
  (`:api_map`) that already authenticates a bot by a map's
  `public_api_key` -- the exact credential eveknob already holds. The
  authenticating map is recorded on each row as provenance only.

  Gated by `WANDERER_SCOUT_COVERAGE`; with the flag off the route
  answers 404 like any nonexistent path.
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.Scout.Coverage

  @row_schema %OpenApiSpex.Schema{
    title: "ScoutCoverageRow",
    type: :object,
    description: """
    One coverage report: "I finished looking at this system to this
    depth at this time", posted even when nothing was found. `kind` is a
    CLOSED vocabulary. `observed_at` accepts EITHER an ISO8601 UTC
    string OR an integer unix-epoch-seconds value; every other field may
    arrive as a string and is coerced.
    """,
    properties: %{
      solar_system_id: %OpenApiSpex.Schema{type: :integer, description: "Required."},
      kind: %OpenApiSpex.Schema{
        type: :string,
        enum: ["visit", "anoms", "sigs", "grid"],
        description: "Required."
      },
      observed_at: %OpenApiSpex.Schema{
        description: "ISO8601 UTC string, or integer unix-epoch-seconds. Required.",
        oneOf: [
          %OpenApiSpex.Schema{type: :string},
          %OpenApiSpex.Schema{type: :integer}
        ]
      },
      character_eve_id: %OpenApiSpex.Schema{
        type: :string,
        description: "Attribution only; never part of the storage identity."
      },
      source: %OpenApiSpex.Schema{type: :string, description: "e.g. \"eveknob/1.0\"."},
      legs_scanned: %OpenApiSpex.Schema{
        type: :integer,
        description: "Meaningful only for kind = \"grid\"."
      },
      sig_count: %OpenApiSpex.Schema{
        type: :integer,
        description: "Meaningful only for kind = \"sigs\" | \"anoms\"."
      },
      scanner_complete: %OpenApiSpex.Schema{type: :boolean}
    },
    required: [:solar_system_id, :kind, :observed_at],
    example: %{
      solar_system_id: 30_002_537,
      kind: "sigs",
      observed_at: "2026-10-04T18:22:05Z",
      character_eve_id: "91234567",
      source: "eveknob/1.0",
      legs_scanned: 7,
      sig_count: 4,
      scanner_complete: true
    }
  }

  @result_schema %OpenApiSpex.Schema{
    title: "ScoutCoverageIngestResult",
    type: :object,
    properties: %{
      received: %OpenApiSpex.Schema{type: :integer, description: "Rows in the payload."},
      stored: %OpenApiSpex.Schema{
        type: :integer,
        description:
          "Rows ingested successfully, INCLUDING ones skipped as stale (an older or " <>
            "equal observed_at than what was already stored) -- the ingest still " <>
            "succeeded idempotently."
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
    example: %{received: 1, stored: 1, failed: 0, errors: []}
  }

  @map_identifier_parameter [
    in: :path,
    description: "Map identifier (UUID or slug) whose API key authenticates the post",
    type: :string,
    required: true
  ]

  operation(:coverage,
    summary: "Append scout-coverage reports (looked at a system, found nothing or not)",
    description: """
    Takes rows saying "I finished looking at system S to depth K at time
    T", even when nothing was found. Upserts on (solar_system_id, kind):
    the latest observation of each kind is all that is kept, and a row
    whose observed_at is older than or equal to the stored one is
    skipped (still counted as `stored`, since the ingest succeeded
    idempotently).

    One malformed row does not reject the batch; it is reported in
    `errors` and the rest are stored.
    """,
    parameters: [map_identifier: @map_identifier_parameter],
    request_body:
      {"Coverage rows", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           rows: %OpenApiSpex.Schema{type: :array, items: @row_schema}
         },
         required: [:rows],
         example: %{rows: [@row_schema.example]}
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

  def coverage(conn, %{"rows" => rows}) when is_list(rows) do
    case Coverage.ingest_coverage(rows, conn.assigns[:map_id]) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, {:batch_too_large, max}} ->
        error(conn, "too many rows in one request, maximum is #{max}")

      {:error, reason} ->
        error(conn, to_string(reason))
    end
  end

  def coverage(conn, _params), do: error(conn, "rows must be an array of objects")

  defp error(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})
end
