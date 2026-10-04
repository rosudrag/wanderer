defmodule WandererApp.ScoutCoverageTest do
  @moduledoc """
  Covers the pure parts of `WandererApp.Scout.Coverage` that would be
  consumer-visible if they broke:

    * `kind` validation -- the vocabulary is CLOSED (`visit | anoms | sigs
      | grid`); anything else must be a per-row error, not a silently
      accepted new category (unlike the sighting tables' free-text
      `location_type`/`spawn_category`).
    * `observed_at` coercion -- the client sends EITHER an ISO8601 UTC
      string OR an integer unix-epoch-seconds value, and both must land
      on the same instant.
    * The stale-skip rule -- an incoming `observed_at` older than or
      equal to the stored one must not overwrite it, but must still
      count as `stored` since the ingest succeeded idempotently.

  See `docs/design/wanderer-scout-planner.md` section 4 and
  `test/integration/scout_intel_test.exs` (the sighting-table sibling
  this mirrors).
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.ScoutSystemCoverage
  alias WandererApp.Scout.Coverage

  defp coverage_row(overrides \\ %{}) do
    Map.merge(
      %{
        "solar_system_id" => 30_002_537,
        "kind" => "sigs",
        "observed_at" => "2026-10-04T18:22:05Z",
        "character_eve_id" => "91234567",
        "source" => "eveknob/1.0",
        "sig_count" => 4,
        "scanner_complete" => true
      },
      overrides
    )
  end

  describe "kind validation" do
    test "each of the four closed-vocabulary kinds ingests cleanly" do
      for kind <- ~w(visit anoms sigs grid) do
        assert {:ok, %{stored: 1, failed: 0}} =
                 Coverage.ingest_coverage(
                   [coverage_row(%{"kind" => kind, "solar_system_id" => 30_000_000})],
                   nil
                 )
      end
    end

    test "an unrecognised kind is a per-row error, not a rejected batch" do
      rows = [coverage_row(%{"kind" => "wat"}), coverage_row(%{"solar_system_id" => 30_000_001})]

      assert {:ok, %{received: 2, stored: 1, failed: 1, errors: [%{index: 0, error: message}]}} =
               Coverage.ingest_coverage(rows, nil)

      assert message =~ "unknown kind"
    end

    test "kind is case-insensitive" do
      assert {:ok, %{stored: 1, failed: 0}} =
               Coverage.ingest_coverage([coverage_row(%{"kind" => "SIGS"})], nil)

      assert {:ok, %{kind: :sigs}} =
               ScoutSystemCoverage.by_system_and_kind(30_002_537, "sigs", authorize?: false)
    end

    test "missing kind, solar_system_id or observed_at fails that row only" do
      rows = [
        coverage_row(%{"kind" => nil}),
        coverage_row(%{"solar_system_id" => nil, "kind" => "visit"}),
        coverage_row(%{"observed_at" => nil, "kind" => "anoms"}),
        coverage_row(%{"kind" => "grid"})
      ]

      assert {:ok, %{received: 4, stored: 1, failed: 3}} = Coverage.ingest_coverage(rows, nil)
    end
  end

  describe "observed_at coercion" do
    test "an ISO8601 UTC string and the equivalent epoch integer land on the same instant" do
      assert {:ok, %{stored: 1}} =
               Coverage.ingest_coverage(
                 [coverage_row(%{"kind" => "visit", "observed_at" => "2026-10-04T18:22:05Z"})],
                 nil
               )

      assert {:ok, %{observed_at: from_string}} =
               ScoutSystemCoverage.by_system_and_kind(30_002_537, "visit", authorize?: false)

      assert {:ok, %{stored: 1}} =
               Coverage.ingest_coverage(
                 [coverage_row(%{"kind" => "grid", "observed_at" => 1_791_138_125})],
                 nil
               )

      assert {:ok, %{observed_at: from_epoch}} =
               ScoutSystemCoverage.by_system_and_kind(30_002_537, "grid", authorize?: false)

      assert DateTime.compare(from_string, from_epoch) == :eq
    end

    test "an integer observed_at sent as a numeric string also coerces" do
      assert {:ok, %{stored: 1}} =
               Coverage.ingest_coverage(
                 [coverage_row(%{"kind" => "anoms", "observed_at" => "1759601325"})],
                 nil
               )

      assert {:ok, %{observed_at: stored}} =
               ScoutSystemCoverage.by_system_and_kind(30_002_537, "anoms", authorize?: false)

      assert DateTime.to_unix(stored) == 1_759_601_325
    end

    test "an unparseable observed_at is a per-row error" do
      rows = [coverage_row(%{"observed_at" => "not a time"})]

      assert {:ok, %{stored: 0, failed: 1, errors: [%{error: message}]}} =
               Coverage.ingest_coverage(rows, nil)

      assert message =~ "observed_at"
    end
  end

  describe "stale-skip" do
    test "an older observed_at is skipped but still counts as stored" do
      newer = coverage_row(%{"observed_at" => "2026-10-04T18:22:05Z"})
      older = coverage_row(%{"observed_at" => "2026-10-04T10:00:00Z"})

      assert {:ok, %{stored: 1}} = Coverage.ingest_coverage([newer], nil)
      assert {:ok, %{stored: 1, failed: 0}} = Coverage.ingest_coverage([older], nil)

      assert {:ok, %{observed_at: kept}} =
               ScoutSystemCoverage.by_system_and_kind(30_002_537, "sigs", authorize?: false)

      assert kept == DateTime.from_iso8601("2026-10-04T18:22:05Z") |> elem(1)
    end

    test "an observed_at equal to the stored one is skipped (re-send is a no-op)" do
      row = coverage_row(%{"sig_count" => 4})

      assert {:ok, %{stored: 1}} = Coverage.ingest_coverage([row], nil)
      assert {:ok, %{stored: 1}} = Coverage.ingest_coverage([row], nil)

      assert {:ok, rows} = ScoutSystemCoverage.read(authorize?: false)
      assert length(rows) == 1
    end

    test "a strictly newer observed_at overwrites the stored row" do
      first = coverage_row(%{"observed_at" => "2026-10-04T10:00:00Z", "sig_count" => 1})
      later = coverage_row(%{"observed_at" => "2026-10-04T18:22:05Z", "sig_count" => 9})

      assert {:ok, %{stored: 1}} = Coverage.ingest_coverage([first], nil)
      assert {:ok, %{stored: 1}} = Coverage.ingest_coverage([later], nil)

      assert {:ok, %{sig_count: 9}} =
               ScoutSystemCoverage.by_system_and_kind(30_002_537, "sigs", authorize?: false)

      assert {:ok, rows} = ScoutSystemCoverage.read(authorize?: false)
      assert length(rows) == 1
    end

    test "different kinds for the same system are independent rows" do
      assert {:ok, %{stored: 1}} =
               Coverage.ingest_coverage([coverage_row(%{"kind" => "visit"})], nil)

      assert {:ok, %{stored: 1}} =
               Coverage.ingest_coverage([coverage_row(%{"kind" => "grid"})], nil)

      assert {:ok, rows} = ScoutSystemCoverage.read(authorize?: false)
      assert length(rows) == 2
    end
  end

  describe "provenance" do
    test "map_id is stored but is not part of the upsert identity" do
      map_id = Ecto.UUID.generate()

      assert {:ok, %{stored: 1}} = Coverage.ingest_coverage([coverage_row()], map_id)

      assert {:ok, %{map_id: ^map_id}} =
               ScoutSystemCoverage.by_system_and_kind(30_002_537, "sigs", authorize?: false)

      # A re-post through a different map's key still upserts onto the
      # SAME row (same solar_system_id + kind), overwriting provenance,
      # not creating a second one.
      other_map_id = Ecto.UUID.generate()

      assert {:ok, %{stored: 1}} =
               Coverage.ingest_coverage(
                 [coverage_row(%{"observed_at" => "2026-10-04T19:00:00Z"})],
                 other_map_id
               )

      assert {:ok, rows} = ScoutSystemCoverage.read(authorize?: false)
      assert length(rows) == 1

      assert {:ok, %{map_id: ^other_map_id}} =
               ScoutSystemCoverage.by_system_and_kind(30_002_537, "sigs", authorize?: false)
    end
  end

  describe "batch limits" do
    test "a batch over 1000 rows is rejected outright" do
      rows = List.duplicate(coverage_row(), 1001)
      assert {:error, {:batch_too_large, 1_000}} = Coverage.ingest_coverage(rows, nil)
    end
  end
end
