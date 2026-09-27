defmodule WandererAppWeb.MapSignatureSyncAPIController do
  @moduledoc """
  CHEWY PATCH: whole-system signature sync for an automated scanner client.

  `POST /api/maps/:map_identifier/signatures/sync` takes the COMPLETE probe
  scanner list for one solar system and reconciles it in a single request:
  the server diffs it against what the map already holds and applies the adds,
  updates and (when the caller says the list is authoritative) removals as one
  batch. See `WandererApp.Map.Operations.SignatureSync` for the diff rules and
  the removal guards.

  Gated by `WANDERER_BOT_SYNC`; with the flag off the route answers 404 like
  any nonexistent path.
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.Map.Operations.SignatureSync

  @signature_schema %OpenApiSpex.Schema{
    title: "SyncSignature",
    type: :object,
    properties: %{
      eve_id: %OpenApiSpex.Schema{
        type: :string,
        description: "In-game signature id, e.g. ABC-123. Required; entries without one are skipped."
      },
      name: %OpenApiSpex.Schema{type: :string, nullable: true},
      description: %OpenApiSpex.Schema{type: :string, nullable: true},
      temporary_name: %OpenApiSpex.Schema{type: :string, nullable: true},
      kind: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Cosmic Signature | Cosmic Anomaly | Structure | Ship | Deployable | Drone | Starbase"
      },
      group: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Cosmic Signature | Wormhole | Gas Site | Relic Site | Data Site | Ore Site | Combat Site"
      },
      type: %OpenApiSpex.Schema{type: :string, nullable: true},
      custom_info: %OpenApiSpex.Schema{type: :string, nullable: true},
      linked_system_id: %OpenApiSpex.Schema{
        type: :integer,
        nullable: true,
        description:
          "Destination solar system for a wormhole. When present the far system is auto-added and a connection created."
      },
      character_eve_id: %OpenApiSpex.Schema{type: :string, nullable: true}
    },
    required: [:eve_id],
    example: %{
      eve_id: "ABC-123",
      kind: "Cosmic Signature",
      group: "Relic Site",
      name: "Ruined Sleeper Crystal Quarry",
      custom_info: "{\"certainty\":1.0,\"hazard\":1,\"tier\":3}"
    }
  }

  @request_schema %OpenApiSpex.Schema{
    title: "SignatureSyncRequest",
    type: :object,
    properties: %{
      solar_system_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "EVE solar system the list belongs to. Auto-added to the map if absent."
      },
      character_eve_id: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Acting character. Defaults to the map owner when omitted."
      },
      source: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Free-form client identifier, for operator diagnostics only."
      },
      authoritative: %OpenApiSpex.Schema{
        type: :boolean,
        default: false,
        description:
          "TRUE asserts the list is the COMPLETE scanner result for that system, which is what permits removals. A stale, mid-jump or still-loading snapshot MUST send false: then the request can only add and update."
      },
      allow_empty: %OpenApiSpex.Schema{
        type: :boolean,
        default: false,
        description:
          "Required alongside authoritative=true to clear the LAST signatures off a system. Without it an empty authoritative payload for a non-empty system is refused, because an empty list and a failed scanner read look identical on the wire."
      },
      signatures: %OpenApiSpex.Schema{type: :array, items: @signature_schema}
    },
    required: [:solar_system_id, :signatures],
    example: %{
      solar_system_id: 31_002_604,
      character_eve_id: "91234567",
      source: "eveknob/1.0",
      authoritative: true,
      signatures: [@signature_schema.example]
    }
  }

  @result_schema %OpenApiSpex.Schema{
    title: "SignatureSyncResult",
    type: :object,
    properties: %{
      added: %OpenApiSpex.Schema{type: :integer},
      updated: %OpenApiSpex.Schema{type: :integer},
      removed: %OpenApiSpex.Schema{type: :integer},
      skipped: %OpenApiSpex.Schema{
        type: :integer,
        description: "Payload entries dropped for a missing/blank eve_id, or as duplicates."
      }
    },
    example: %{added: 3, updated: 1, removed: 2, skipped: 0}
  }

  operation(:sync,
    summary: "Reconcile the complete signature list for one solar system",
    description: """
    Posts the whole probe-scanner list for one system. The server diffs it
    against the map and applies adds, updates and removals in a single batch,
    emitting the same events the map UI does.

    Removals happen only when `authoritative` is true. Connections are never
    deleted as a side effect of a signature disappearing.
    """,
    parameters: [
      map_identifier: [
        in: :path,
        description: "Map identifier (UUID or slug)",
        type: :string,
        required: true
      ]
    ],
    request_body: {"Signature list", "application/json", @request_schema},
    responses: [
      ok:
        {"Sync result", "application/json",
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
           example: %{error: "empty_authoritative_payload"}
         }}
    ]
  )

  def sync(conn, params) do
    case SignatureSync.sync(conn, params) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(error)})
    end
  end
end
