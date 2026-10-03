defmodule WandererAppWeb.ScoutExportController do
  @moduledoc """
  CHEWY PATCH: `GET /scout/export.csv` — the scout log as a file.

  The page is a reader; a fleet commander planning a timer board wants
  the rows. Same flag, same permission and the same `:search` read
  actions as `WandererAppWeb.ScoutIntelLive`, taking its filters from
  the query string (`tab`, `days`, `q`, `system_id`) so "what I am
  looking at" and "what I exported" cannot drift.

  Unlike the page, the export carries **every** stored column: the point
  of a CSV is the fields the HTML had no room for.

  The permission is re-checked here rather than inherited: this is a
  plain controller, so nothing in the `/scout` `live_session` gate
  applies to it.
  """

  use WandererAppWeb, :controller

  require Ash.Query

  alias WandererApp.Api.{ScoutSpawnSighting, ScoutStructureSighting}
  alias WandererApp.Identity.ScoutAccess

  # A hard cap, not a page: a CSV has no "load more". 50k rows is a few
  # megabytes and still a single round trip.
  @max_rows 50_000

  @default_days 7
  @max_days 365

  @structure_columns ~w(observed_at event solar_system_id solar_system_name system_truesec
                        structure_id type_id structure_name group_name owner_id owner_name
                        alliance_id upkeep_state upkeep_label structure_state state_label
                        vulnerable anchoring unanchoring timer_seconds timer_expires_at
                        shield_pct armor_pct hull_pct distance_m nearest_celestial
                        nearest_celestial_m)a

  @spawn_columns ~w(observed_at solar_system_id solar_system_name system_truesec location_type
                    location_name spawn_name spawn_category anomaly_type players_in_local
                    action_taken outcome entity_id minutes_since_downtime isk_value)a

  def export(conn, params) do
    user = conn.assigns[:current_user]

    if user && ScoutAccess.can_view?(user.id) do
      {tab, columns, rows} = read(params)

      body =
        [Enum.map(columns, &to_string/1) | Enum.map(rows, &row(&1, columns))]
        |> NimbleCSV.RFC4180.dump_to_iodata()

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="scout-#{tab}-#{Date.utc_today()}.csv")
      )
      |> send_resp(200, body)
    else
      conn |> put_status(:forbidden) |> text("Forbidden")
    end
  end

  defp read(params) do
    since = DateTime.add(DateTime.utc_now(), -days(params), :day)

    args = %{
      since: since,
      system_id: integer(params["system_id"]),
      q: search_term(params["q"])
    }

    case params["tab"] do
      "spawns" -> {"spawns", @spawn_columns, rows(ScoutSpawnSighting, args)}
      _ -> {"structures", @structure_columns, rows(ScoutStructureSighting, args)}
    end
  end

  defp rows(resource, args) do
    resource
    |> Ash.Query.for_read(:search, args)
    |> Ash.Query.limit(@max_rows)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  defp row(record, columns), do: Enum.map(columns, &value(Map.get(record, &1)))

  defp value(nil), do: ""
  defp value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp value(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp value(value) when is_binary(value), do: value
  defp value(value), do: to_string(value)

  # Clamped rather than rejected: a hand-edited URL should give a file,
  # not a 400.
  defp days(params) do
    case integer(params["days"]) do
      nil -> @default_days
      days when days < 1 -> 1
      days when days > @max_days -> @max_days
      days -> days
    end
  end

  defp integer(nil), do: nil

  defp integer(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp search_term(nil), do: nil

  defp search_term(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      term -> term
    end
  end
end
