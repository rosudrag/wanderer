defmodule WandererApp.Map.Operations.SignatureSyncTest do
  @moduledoc """
  The reconciliation half of the scanner-client sync endpoint.

  `diff/3` decides what gets written to somebody's live map from an unattended
  client's payload, and `normalize/1` decides what counts as a signature at all.
  Both are pure, so they are gated here rather than behind HTTP.
  """

  use ExUnit.Case, async: true

  alias WandererApp.Map.Operations.SignatureSync

  defp existing(eve_id, attrs \\ %{}) do
    Map.merge(
      %{
        eve_id: eve_id,
        name: nil,
        description: nil,
        temporary_name: nil,
        kind: "Cosmic Signature",
        group: "Cosmic Signature",
        type: nil,
        custom_info: nil,
        linked_system_id: nil
      },
      attrs
    )
  end

  describe "diff/3 - additions" do
    test "a signature the map has never seen is an addition" do
      incoming = [%{"eve_id" => "ABC-123", "group" => "Relic Site"}]

      assert %{added: [added], updated: [], removed: []} =
               SignatureSync.diff([], incoming, true)

      assert added["eve_id"] == "ABC-123"
    end
  end

  describe "diff/3 - updates" do
    test "an unchanged signature produces no write at all" do
      rows = [existing("ABC-123", %{group: "Relic Site", name: "Ruined Quarry"})]
      incoming = [%{"eve_id" => "ABC-123", "group" => "Relic Site", "name" => "Ruined Quarry"}]

      assert %{added: [], updated: [], removed: []} = SignatureSync.diff(rows, incoming, true)
    end

    test "a resolved name upgrades an already-known signature" do
      rows = [existing("ABC-123", %{group: "Cosmic Signature"})]
      incoming = [%{"eve_id" => "ABC-123", "group" => "Relic Site", "name" => "Ruined Quarry"}]

      assert %{added: [], updated: [update], removed: []} =
               SignatureSync.diff(rows, incoming, true)

      assert update["group"] == "Relic Site"
      assert update["name"] == "Ruined Quarry"
    end

    test "fields the client never sent keep their stored value" do
      # The batch applier builds its DTO from whatever map it is handed and a
      # missing key lands as nil, so an update carrying only `name` would erase
      # a human's `description`. The merge is what stops that.
      rows = [existing("ABC-123", %{description: "watch the rats", group: "Relic Site"})]
      incoming = [%{"eve_id" => "ABC-123", "name" => "Ruined Quarry"}]

      assert %{updated: [update]} = SignatureSync.diff(rows, incoming, true)
      assert update["description"] == "watch the rats"
      assert update["group"] == "Relic Site"
    end

    test "empty string and nil are the same absence" do
      # The scanner reports an unresolved site name as "", the map stores nil.
      # Treating those as different would mark every row dirty on every sweep.
      rows = [existing("ABC-123", %{name: nil})]
      incoming = [%{"eve_id" => "ABC-123", "name" => ""}]

      assert %{updated: []} = SignatureSync.diff(rows, incoming, true)
    end
  end

  describe "diff/3 - removals" do
    test "authoritative payload removes what it does not mention" do
      rows = [existing("ABC-123"), existing("DEF-456")]
      incoming = [%{"eve_id" => "ABC-123"}]

      assert %{removed: [removed]} = SignatureSync.diff(rows, incoming, true)
      assert removed["eve_id"] == "DEF-456"
    end

    test "a non-authoritative payload never removes anything" do
      rows = [existing("ABC-123"), existing("DEF-456")]
      incoming = [%{"eve_id" => "ABC-123"}]

      assert %{removed: []} = SignatureSync.diff(rows, incoming, false)
    end

    test "an empty authoritative payload clears the system" do
      # Refusing this is the CONTROLLER's guard (:empty_authoritative_payload);
      # the diff itself must still report the truth it was asked for.
      rows = [existing("ABC-123")]

      assert %{added: [], updated: [], removed: [%{"eve_id" => "ABC-123"}]} =
               SignatureSync.diff(rows, [], true)
    end
  end

  describe "normalize/1" do
    test "entries without a usable eve_id are skipped, not written" do
      {kept, skipped} =
        SignatureSync.normalize([
          %{"eve_id" => "ABC-123"},
          %{"eve_id" => ""},
          %{"eve_id" => "   "},
          %{"name" => "no id at all"},
          %{"eve_id" => nil}
        ])

      assert Enum.map(kept, & &1["eve_id"]) == ["ABC-123"]
      assert skipped == 4
    end

    test "eve_id is trimmed and duplicates collapse to the first" do
      {kept, skipped} =
        SignatureSync.normalize([
          %{"eve_id" => " ABC-123 ", "name" => "first"},
          %{"eve_id" => "ABC-123", "name" => "second"}
        ])

      assert [%{"eve_id" => "ABC-123", "name" => "first"}] = kept
      assert skipped == 1
    end
  end
end
