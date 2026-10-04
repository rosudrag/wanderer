defmodule WandererApp.Scout.SnapshotTest do
  @moduledoc """
  The reconciliation half of the structure presence feed.

  `diff/2` decides which structures an unattended client's blob is allowed
  to mark as no longer there, and `normalize/1` decides what counts as an
  observation at all. Both are pure, so they are gated here rather than
  behind HTTP.

  The bias every case below protects: a blob may only ever archive a
  structure it can PROVE it should have seen. Getting that wrong deletes
  somebody's target list, so the interesting tests are the ones where
  `missing` must come back EMPTY.
  """

  use ExUnit.Case, async: true

  alias WandererApp.Scout.Snapshot

  @observer %{x: 0.0, y: 0.0, z: 0.0}

  defp at(seconds), do: DateTime.from_unix!(1_759_574_400 + seconds)

  defp known(structure_id, attrs \\ %{}) do
    Map.merge(
      %{
        structure_id: structure_id,
        solar_system_id: 30_000_142,
        status: "NoFuel",
        owner_id: 98_123_456,
        owner_name: "Corp",
        alliance_id: nil,
        structure_name: "Mouse",
        group_name: "Citadel",
        type_id: 35_832,
        vulnerable: false,
        anchoring: false,
        unanchoring: false,
        upkeep_state: 2,
        structure_state: 110,
        shield_pct: 100,
        armor_pct: 100,
        hull_pct: 100,
        timer_expires_at: nil,
        pos_x: 1_000.0,
        pos_y: 0.0,
        pos_z: 0.0,
        presence: :seen,
        missing_count: 0,
        missing_since: nil,
        last_confirmed_at: at(0)
      },
      attrs
    )
  end

  defp seen(structure_id, attrs \\ %{}) do
    known(structure_id, attrs)
    |> Map.drop([:presence, :missing_count, :missing_since, :last_confirmed_at])
  end

  defp blob(attrs) do
    Map.merge(
      %{
        solar_system_id: 30_000_142,
        observed_at: at(60),
        observer: @observer,
        horizon_m: 100_000.0,
        structures: [],
        steady_ids: [],
        complete?: true
      },
      attrs
    )
  end

  defp ids(rows), do: Enum.map(rows, &(Map.get(&1, :structure_id) || &1.known.structure_id))

  describe "diff/2 - absence is bounded by the proven sphere" do
    test "a known structure outside horizon_m is never missing" do
      far = known(1, %{pos_x: 500_000.0})

      result = Snapshot.diff([far], blob(%{steady_ids: [2]}))

      assert result.missing == []
    end

    test "a known structure inside horizon_m and in neither list is missing" do
      near = known(1, %{pos_x: 1_000.0})

      result = Snapshot.diff([near], blob(%{steady_ids: [2]}))

      assert ids(result.missing) == [1]
    end

    test "horizon is a sphere, not a per-axis box" do
      # 60k on each of three axes is ~103.9 km away: outside a 100 km
      # horizon even though no single component exceeds it.
      corner = known(1, %{pos_x: 60_000.0, pos_y: 60_000.0, pos_z: 60_000.0})

      result = Snapshot.diff([corner], blob(%{steady_ids: [2]}))

      assert result.missing == []
    end

    test "a known structure with no stored position is never missing" do
      positionless = known(1, %{pos_x: nil, pos_y: nil, pos_z: nil})

      result = Snapshot.diff([positionless], blob(%{steady_ids: [2]}))

      assert result.missing == []
    end

    test "a partially positioned structure is never missing" do
      half = known(1, %{pos_z: nil})

      result = Snapshot.diff([half], blob(%{steady_ids: [2]}))

      assert result.missing == []
    end

    test "an incomplete blob archives nothing, however much it proves" do
      near = known(1)

      result = Snapshot.diff([near], blob(%{steady_ids: [2], complete?: false}))

      assert result.missing == []
    end

    test "a structure already gone is not re-reported as missing" do
      dead = known(1, %{presence: :gone})

      result = Snapshot.diff([dead], blob(%{steady_ids: [2]}))

      assert result.missing == []
    end

    test "a structure already missing stays in scope so a second absence can promote it" do
      absent = known(1, %{presence: :missing, missing_count: 1, missing_since: at(0)})

      result = Snapshot.diff([absent], blob(%{steady_ids: [2]}))

      assert ids(result.missing) == [1]
    end
  end

  describe "diff/2 - steady ids are presence, not absence" do
    test "a steady id for a previously notable structure clears it, never archives it" do
      result = Snapshot.diff([known(1, %{status: "NoFuel"})], blob(%{steady_ids: [1]}))

      assert ids(result.cleared) == [1]
      assert result.missing == []
    end

    test "a steady id for an already steady structure is only a confirmation" do
      result = Snapshot.diff([known(1, %{status: "FullPower"})], blob(%{steady_ids: [1]}))

      assert result.cleared == []
      assert result.missing == []
      assert ids(Enum.map(result.unchanged, & &1.known)) == [1]
    end

    test "a steady id for a structure we have never tracked is ignored entirely" do
      result = Snapshot.diff([], blob(%{steady_ids: [999]}))

      assert result.cleared == []
      assert result.appeared == []
      assert result.unchanged == []
    end

    test "a steady-only blob still confirms and still archives correctly" do
      result = Snapshot.diff([known(1), known(2)], blob(%{steady_ids: [1]}))

      assert ids(result.cleared) == [1]
      assert ids(result.missing) == [2]
    end
  end

  describe "diff/2 - direct sightings" do
    test "a structure we have never seen appears" do
      result = Snapshot.diff([], blob(%{structures: [seen(1)]}))

      assert ids(result.appeared) == [1]
    end

    test "a status move is news" do
      result =
        Snapshot.diff(
          [known(1, %{status: "NoFuel"})],
          blob(%{structures: [seen(1, %{status: "Abandoned"})]})
        )

      assert [%{changed_fields: fields}] = result.changed
      assert :status in fields
    end

    test "an identical re-sighting is not news" do
      result = Snapshot.diff([known(1)], blob(%{structures: [seen(1)]}))

      assert result.changed == []
      assert ids(Enum.map(result.unchanged, & &1.known)) == [1]
    end

    test "timer drift inside the tolerance is not news" do
      result =
        Snapshot.diff(
          [known(1, %{timer_expires_at: at(10_000)})],
          blob(%{structures: [seen(1, %{timer_expires_at: at(10_060)})]})
        )

      assert result.changed == []
    end

    test "timer drift beyond the tolerance is news" do
      result =
        Snapshot.diff(
          [known(1, %{timer_expires_at: at(10_000)})],
          blob(%{structures: [seen(1, %{timer_expires_at: at(10_600)})]})
        )

      assert [%{changed_fields: fields}] = result.changed
      assert :timer_expires_at in fields
    end

    test "a timer appearing where there was none is news" do
      result =
        Snapshot.diff(
          [known(1, %{timer_expires_at: nil})],
          blob(%{structures: [seen(1, %{timer_expires_at: at(10_000)})]})
        )

      assert [%{changed_fields: fields}] = result.changed
      assert :timer_expires_at in fields
    end

    test "a directly sighted structure is never also missing" do
      result = Snapshot.diff([known(1)], blob(%{structures: [seen(1)]}))

      assert result.missing == []
    end
  end

  describe "gone?/5 - promotion needs two distinct visits, or an expired unanchor" do
    test "one absence is not enough" do
      refute Snapshot.gone?(1, at(0), at(60), "NoFuel", nil)
    end

    test "two absences seconds apart are one observation, not two" do
      refute Snapshot.gone?(2, at(0), at(3), "NoFuel", nil)
    end

    test "two absences past the window promote" do
      assert Snapshot.gone?(2, at(0), at(Snapshot.gone_after_seconds()), "NoFuel", nil)
    end

    test "one absence promotes when an unanchoring timer has already run out" do
      assert Snapshot.gone?(1, at(60), at(60), "Unanchoring", at(0))
    end

    test "an unanchoring structure whose timer is still running does not promote" do
      refute Snapshot.gone?(1, at(60), at(60), "Unanchoring", at(10_000))
    end

    test "an expired timer on a structure that is not unanchoring does not promote" do
      refute Snapshot.gone?(1, at(60), at(60), "ArmorReinforced", at(0))
    end
  end

  describe "normalize/1 - what counts as an observation" do
    defp wire(attrs \\ %{}) do
      Map.merge(
        %{
          "solar_system_id" => "30000142",
          "observed_at" => "1759574400",
          "observer_x" => "0",
          "observer_y" => "0",
          "observer_z" => "0",
          "horizon_m" => "820000000",
          "structures" => [],
          "steady_ids" => ["1047987654321"],
          "complete" => true
        },
        attrs
      )
    end

    test "every value may arrive as a JSON string" do
      assert {:ok, blob} = Snapshot.normalize(wire())
      assert blob.solar_system_id == 30_000_142
      assert blob.horizon_m == 820_000_000.0
      assert blob.steady_ids == [1_047_987_654_321]
    end

    test "a blob that saw nothing at all is refused" do
      assert {:error, :no_observation} =
               Snapshot.normalize(wire(%{"structures" => [], "steady_ids" => []}))
    end

    test "a zero horizon is refused -- it describes no sphere" do
      assert {:error, _reason} = Snapshot.normalize(wire(%{"horizon_m" => "0"}))
    end

    test "a missing observer is refused -- a horizon needs a centre" do
      assert {:error, _reason} = Snapshot.normalize(wire(%{"observer_y" => ""}))
    end

    test "the client's own complete:false survives normalization" do
      assert {:ok, blob} = Snapshot.normalize(wire(%{"complete" => false}))
      refute blob.complete?
    end

    test "a malformed structure row vetoes completeness without failing the blob" do
      assert {:ok, blob} = Snapshot.normalize(wire(%{"structures" => [%{"type_id" => "35832"}]}))
      refute blob.complete?
      assert blob.skipped == 1
    end

    test "a structure with a partial position stores no position at all" do
      row = %{"structure_id" => "1", "pos_x" => "10", "pos_y" => "20"}

      assert {:ok, blob} = Snapshot.normalize(wire(%{"structures" => [row]}))
      assert [%{pos_x: nil, pos_y: nil, pos_z: nil}] = blob.structures
    end

    test "timer_seconds is turned into an absolute expiry against observed_at" do
      row = %{"structure_id" => "1", "timer_seconds" => "600"}

      assert {:ok, blob} = Snapshot.normalize(wire(%{"structures" => [row]}))
      assert [%{timer_expires_at: expires}] = blob.structures
      assert DateTime.diff(expires, at(0), :second) == 600
    end

    test "the no-timer sentinel leaves no expiry" do
      row = %{"structure_id" => "1", "timer_seconds" => "-1"}

      assert {:ok, blob} = Snapshot.normalize(wire(%{"structures" => [row]}))
      assert [%{timer_expires_at: nil}] = blob.structures
    end

    test "an oversized blob is refused rather than truncated" do
      too_many = Enum.map(1..1001, &to_string/1)

      assert {:error, {:batch_too_large, _cap}} =
               Snapshot.normalize(wire(%{"steady_ids" => too_many}))
    end
  end
end
