defmodule WandererApp.ScoutAssetSafetyTest do
  @moduledoc """
  The asset-safety trigger: an ESI `StructureItemsMovedToSafety`
  notification is the only signal this app can get that a specific
  structure has FINISHED unanchoring, at the instant it happens.

  What each case protects is a way the trigger silently stops firing,
  which is the only failure mode that matters here — a board that stays
  empty looks exactly like a quiet week:

    * the wire shape (ticks, not unix; `structureID` case; a `text` body
      whose `structureLink` value contains colons and HTML),
    * the dedupe, because ESI re-serves the same ~50 notifications on
      every single poll, forever,
    * the fold, because every character that had an item in the hull
      gets its own notification about the same structure, and
    * the opt-in filter, because EVE only grants scopes that were asked
      for at login and polling a character that never consented spends
      ESI's error budget every cadence.

  See `WandererApp.Scout.AssetSafety` and
  `WandererApp.Sync.Feeds.AssetSafetyFeed`.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.ScoutAssetSafety
  alias WandererApp.Scout.AssetSafety

  @system 30_002_543
  @structure_id 1_035_466_617_946
  @other_structure_id 1_035_466_617_999

  # A real notification body, copied from live ESI: lowerCamelCase keys,
  # FILETIME ticks, a colon-bearing HTML value, a YAML list this parser
  # must ignore — and the YAML ANCHOR on `structureID` that this fixture
  # did NOT have until 2026-10-11, which is why every test passed while
  # the feature parsed nothing in production.
  defp text(structure_id \\ @structure_id, system_id \\ @system) do
    """
    assetSafetyDurationFull: 1728000
    assetSafetyDurationMinimum: 432000
    assetSafetyFullTimestamp: 133147182000000000
    assetSafetyMinimumTimestamp: 133142862000000000
    isCorpOwned: true
    newStationID: 60014707
    solarSystemID: #{system_id}
    structureID: &id001 #{structure_id}
    structureLink: <a href="showinfo:35832//#{structure_id}">Some Astrahus</a>
    structureShowInfoData:
    - showinfo
    - 35832
    - *id001
    structureTypeID: 35832
    """
  end

  # The default timestamp is RELATIVE, not the wire sample's own
  # `2026-10-09T18:22:00Z`: `recent/1` has a 7-day horizon, so a fixed
  # date silently falls out of it a week after it is written and four
  # tests here start failing on a calendar, not on a change. A case that
  # cares about an exact instant passes `timestamp:` itself.
  defp notification(id, opts \\ []) do
    default_at =
      DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:second)

    %{
      "notification_id" => id,
      "type" => Keyword.get(opts, :type, "StructureItemsMovedToSafety"),
      "sender_id" => 1_000_132,
      "sender_type" => "corporation",
      "is_read" => false,
      "timestamp" => Keyword.get(opts, :timestamp, DateTime.to_iso8601(default_at)),
      "text" =>
        Keyword.get(opts, :text, text(Keyword.get(opts, :structure_id, @structure_id), @system))
    }
  end

  defp character(overrides \\ %{}) do
    Map.merge(%{eve_id: "2112625428", name: "Fatloard"}, overrides)
  end

  describe "parse/1" do
    test "reads the structure, the system and both asset-safety deadlines" do
      # This case is ABOUT the wire instant, so it pins one rather than
      # taking the fixture's relative default.
      assert {:ok, attrs} = AssetSafety.parse(notification(1, timestamp: "2026-10-09T18:22:00Z"))

      assert attrs.notification_id == 1
      assert attrs.type == "StructureItemsMovedToSafety"
      assert attrs.structure_id == @structure_id
      assert attrs.solar_system_id == @system
      assert attrs.structure_type_id == 35_832
      assert attrs.new_station_id == 60_014_707
      assert attrs.is_corp_owned == true
      # The notification's OWN timestamp is ordinary ISO8601 ...
      assert attrs.notified_at == ~U[2026-10-09 18:22:00Z]
      # ... while the two in its body are Windows FILETIME ticks (epoch
      # 1601-01-01), NOT unix seconds and NOT .NET year-1 ticks: read
      # either of those other two ways this value lands in the year 423
      # or the year 4-billion, and the trigger parses to nothing.
      assert attrs.asset_safety_full_at == ~U[2022-12-05 12:50:00Z]
      assert attrs.asset_safety_min_at == ~U[2022-11-30 12:50:00Z]
      assert DateTime.compare(attrs.asset_safety_min_at, attrs.asset_safety_full_at) == :lt
    end

    test "ignores every other notification type" do
      assert :skip == AssetSafety.parse(notification(2, type: "StructureUnderAttack"))
      assert :skip == AssetSafety.parse(notification(3, type: "MiningLedger"))
    end

    test "skips a body with no structure rather than storing half a row" do
      assert :skip == AssetSafety.parse(notification(4, text: "solarSystemID: 30002543\n"))
    end

    test "matches keys case-insensitively" do
      body = "StructureID: 99\nSolarSystemID: 30000142\n"

      assert {:ok, %{structure_id: 99, solar_system_id: 30_000_142}} =
               AssetSafety.parse(notification(5, text: body))
    end

    test "keeps colons inside a value and drops YAML list items" do
      fields = AssetSafety.parse_text(text())

      assert fields["structurelink"] =~ "showinfo:35832"
      refute Map.has_key?(fields, "showinfo")
    end

    # 2026-10-11: the one defect that made this feature never fire.
    # EVE anchors the structure id (`&id001`) and refers back to it
    # (`*id001`); read literally the value is "&id001 1042709327956",
    # which is not an integer, so all 36 live notifications were
    # skipped — silently, because a skip is also how 48 mining-ledger
    # rows are dropped.
    test "resolves the YAML anchor EVE puts on structureID" do
      fields = AssetSafety.parse_text(text())

      assert fields["structureid"] == to_string(@structure_id)
      refute fields["structureid"] =~ "&"

      assert {:ok, %{structure_id: @structure_id}} = AssetSafety.parse(notification(6))
    end

    test "a bare alias value resolves to the anchor it names" do
      body = """
      structureID: &id001 4242
      solarSystemID: 30000142
      otherID: *id001
      """

      assert %{"structureid" => "4242", "otherid" => "4242"} = AssetSafety.parse_text(body)
    end

    test "to_datetime/1 takes ticks or unix seconds and refuses nonsense" do
      assert {:ok, ~U[2022-12-05 12:50:00Z]} = AssetSafety.to_datetime(133_147_182_000_000_000)
      assert {:ok, %DateTime{year: 2026}} = AssetSafety.to_datetime(1_791_000_000)
      assert :error == AssetSafety.to_datetime(0)
      assert :error == AssetSafety.to_datetime("not a date")
    end
  end

  describe "store/2" do
    test "stores a trigger once, however many times ESI re-serves it" do
      assert 1 == AssetSafety.store([notification(10)], character())
      assert 0 == AssetSafety.store([notification(10)], character())
      assert 0 == AssetSafety.store([notification(10), notification(10)], character())

      assert {:ok, row} = ScoutAssetSafety.by_notification_id(10, authorize?: false)
      assert row.structure_id == @structure_id
      assert row.character_eve_id == 2_112_625_428
      assert row.character_name == "Fatloard"
    end

    test "counts only the triggers in a mixed notification page" do
      page = [
        notification(20),
        notification(21, type: "StructureUnderAttack"),
        notification(22, structure_id: @other_structure_id),
        notification(23, type: "CorpAppNewMsg")
      ]

      assert 2 == AssetSafety.store(page, character())
    end
  end

  describe "recent/1" do
    test "folds two characters' notifications about one structure into one row" do
      assert 1 == AssetSafety.store([notification(30)], character())

      assert 1 ==
               AssetSafety.store(
                 [notification(31)],
                 character(%{eve_id: "95465499", name: "Alt Pilot"})
               )

      rows = AssetSafety.recent()

      assert [%{structure_id: @structure_id}] = rows
    end

    test "lists one row per structure, newest first" do
      now = DateTime.utc_now()
      older = now |> DateTime.add(-2, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      newer = now |> DateTime.add(-1, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      # Both instants are relative: the order is the point, and the
      # 7-day horizon of `recent/1` is what a fixed date falls out of.
      assert 1 == AssetSafety.store([notification(40, timestamp: older)], character())

      assert 1 ==
               AssetSafety.store(
                 [notification(41, structure_id: @other_structure_id, timestamp: newer)],
                 character()
               )

      assert [@other_structure_id, @structure_id] ==
               AssetSafety.recent() |> Enum.map(& &1.structure_id)
    end

    test "drops a trigger older than the horizon" do
      old = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.to_iso8601()

      assert 1 == AssetSafety.store([notification(50, timestamp: old)], character())
      assert [] == AssetSafety.recent()
    end

    test "narrows by system and by the page's search box" do
      assert 1 == AssetSafety.store([notification(60)], character())

      assert [_one] = AssetSafety.recent(system_id: @system)
      assert [] == AssetSafety.recent(system_id: 30_000_142)

      # `character_name` is one of the four columns the search covers.
      assert [_also] = AssetSafety.recent(q: "Fatloard")
      assert [] == AssetSafety.recent(q: "nobody by that name")
    end
  end

  describe "dismiss/2" do
    test "takes the structure off the board and puts it on the undo list" do
      assert 1 == AssetSafety.store([notification(70)], character())
      assert [_on_board] = AssetSafety.recent()

      assert 1 == AssetSafety.dismiss(@structure_id)

      assert [] == AssetSafety.recent()
      assert [%{structure_id: @structure_id}] = AssetSafety.dismissed()

      assert 1 == AssetSafety.restore(@structure_id)
      assert [_back] = AssetSafety.recent()
      assert [] == AssetSafety.dismissed()
    end

    # The whole reason dismissal is keyed on the structure: the board
    # folds `DISTINCT ON (structure_id)`, so dismissing only the folded
    # row would promote its sibling and the hull would never leave.
    test "covers every alt's notification about the same hull" do
      assert 1 == AssetSafety.store([notification(80)], character())

      assert 1 ==
               AssetSafety.store(
                 [notification(81)],
                 character(%{eve_id: "95465499", name: "Alt Pilot"})
               )

      assert 2 == AssetSafety.dismiss(@structure_id)
      assert [] == AssetSafety.recent()
    end

    test "a dismissal is never bounded by the window the board uses" do
      old = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.to_iso8601()

      assert 1 == AssetSafety.store([notification(90, timestamp: old)], character())
      assert 1 == AssetSafety.dismiss(@structure_id)

      # Off the board for BOTH reasons, but still reachable to undo.
      assert [] == AssetSafety.recent()
      assert [_undoable] = AssetSafety.dismissed()
    end
  end

  describe "watching_characters/0" do
    test "only ever returns characters whose stored token carries the scope" do
      {:ok, consented} =
        WandererApp.Api.Character.create(
          %{
            eve_id: "90000001",
            name: "Consented",
            access_token: "token",
            scopes:
              "esi-location.read_location.v1 esi-characters.read_notifications.v1 esi-ui.write_waypoint.v1"
          },
          authorize?: false
        )

      {:ok, _plain} =
        WandererApp.Api.Character.create(
          %{
            eve_id: "90000002",
            name: "Never Asked",
            access_token: "token",
            scopes: "esi-location.read_location.v1 esi-ui.write_waypoint.v1"
          },
          authorize?: false
        )

      ids = AssetSafety.watching_characters() |> Enum.map(& &1.id)

      assert consented.id in ids
      assert length(ids) == 1
    end
  end

  describe "Seeding — is the trigger armed" do
    alias WandererApp.Scout.Seeding

    defp pilot(name, eve_id, scopes) do
      {:ok, character} =
        WandererApp.Api.Character.create(
          %{eve_id: eve_id, name: name, access_token: "token", scopes: scopes},
          authorize?: false
        )

      character
    end

    test "an item in a structure arms it, and hauling it out disarms it" do
      character = pilot("Seeder", "90000010", "esi-assets.read_assets.v1")

      assert 1 == Seeding.replace(character, [@structure_id])
      assert %{@structure_id => ["Seeder"]} = Seeding.armed_by([@structure_id])

      # The item leaves. The row MUST go with it -- an "armed" that
      # outlives the item is the one answer worse than no answer.
      assert 0 == Seeding.replace(character, [])
      assert %{} == Seeding.armed_by([@structure_id])
    end

    test "stations and solar systems are not structures and are never stored" do
      character = pilot("Hauler", "90000011", "esi-assets.read_assets.v1")

      assert 1 == Seeding.replace(character, [60_003_760, 30_000_142, @structure_id])

      assert Map.keys(Seeding.armed_by([60_003_760, 30_000_142, @structure_id])) == [
               @structure_id
             ]
    end

    test "split/1 keeps board order and separates the hulls that need an item" do
      character = pilot("Seeder", "90000012", "esi-assets.read_assets.v1")
      Seeding.replace(character, [@structure_id])

      rows = [%{structure_id: @structure_id}, %{structure_id: @other_structure_id}]

      assert {[%{structure_id: @structure_id}], [%{structure_id: @other_structure_id}]} =
               Seeding.split(rows)
    end

    test "only characters that consented to the assets scope are polled" do
      armed = pilot("Consented", "90000013", "esi-assets.read_assets.v1")
      _other = pilot("Notifications only", "90000014", "esi-characters.read_notifications.v1")

      assert [%{id: id}] = Seeding.asset_characters()
      assert id == armed.id
    end

    test "the assets feed is registered beside the notification feed" do
      Application.put_env(:wanderer_app, :scout_asset_safety_enabled, true)
      on_exit(fn -> Application.delete_env(:wanderer_app, :scout_asset_safety_enabled) end)

      modules = Enum.map(WandererApp.Sync.Registry.feeds(), fn {module, _} -> module end)

      assert WandererApp.Sync.Feeds.AssetSafetyFeed in modules
      assert WandererApp.Sync.Feeds.AssetLocationsFeed in modules
    end
  end

  describe "root_locations/1 — assets are a tree" do
    alias WandererApp.Sync.Feeds.AssetLocationsFeed

    @structure 1_055_339_465_036
    @station 60_003_760

    # The defect this exists for, measured on live data 2026-10-10: only
    # an item dropped LOOSE in a structure's hangar reports that
    # structure as its `location_id`. Put it in a container, or leave it
    # in a ship parked there, and `location_id` is that container's or
    # ship's `item_id` — the structure never appears at all, and a hull
    # that IS seeded reads as "seed it" on the page. 228 stored
    # locations matched 4 of 27 unanchoring structures.
    test "an item nested in a container in a ship still names the structure" do
      rows = [
        %{"item_id" => 1, "location_id" => @structure},
        %{"item_id" => 2, "location_id" => 1},
        %{"item_id" => 3, "location_id" => 2},
        %{"item_id" => 4, "location_id" => @station}
      ]

      roots = AssetLocationsFeed.root_locations(rows)

      assert @structure in roots
      assert @station in roots
      # Nothing the character OWNS is a location in its own right.
      refute 1 in roots
      refute 2 in roots
    end

    test "a cycle cannot hang the sync task" do
      rows = [
        %{"item_id" => 1, "location_id" => 2},
        %{"item_id" => 2, "location_id" => 1}
      ]

      assert AssetLocationsFeed.root_locations(rows) != nil
    end

    test "string ids off the wire are coerced, and incomplete rows dropped" do
      rows = [
        %{"item_id" => "1", "location_id" => to_string(@structure)},
        %{"location_id" => 999_999_999_999_999}
      ]

      assert AssetLocationsFeed.root_locations(rows) == [@structure]
    end
  end

  describe "the feed, as the scheduler drives it" do
    setup do
      {:ok, character} =
        WandererApp.Api.Character.create(
          %{
            eve_id: "2112625428",
            name: "Fatloard",
            access_token: "token",
            scopes: "esi-location.read_location.v1 esi-characters.read_notifications.v1"
          },
          authorize?: false
        )

      on_exit(fn -> Application.delete_env(:wanderer_app, :scout_asset_safety_enabled) end)

      %{character: character}
    end

    test "the registry only offers the feed when the flag is on", %{character: character} do
      Application.put_env(:wanderer_app, :scout_asset_safety_enabled, false)

      refute Enum.any?(
               WandererApp.Sync.Registry.feeds(),
               fn {module, _scopes} -> module == WandererApp.Sync.Feeds.AssetSafetyFeed end
             )

      Application.put_env(:wanderer_app, :scout_asset_safety_enabled, true)

      assert {_module, resolver} =
               Enum.find(
                 WandererApp.Sync.Registry.feeds(),
                 fn {module, _scopes} -> module == WandererApp.Sync.Feeds.AssetSafetyFeed end
               )

      # One scope per character, keyed on the eve id — that key is what
      # gives each character its own ETag and its own `:stalled`.
      assert [{scope, "2112625428"}] = resolver.()
      assert scope.id == character.id
    end

    test "upsert stores a page of notifications and tells open pages", %{character: character} do
      Phoenix.PubSub.subscribe(WandererApp.PubSub, "scout_intel")

      :ok =
        WandererApp.Sync.Feeds.AssetSafetyFeed.upsert(character, [
          notification(70),
          notification(71, type: "StructureUnderAttack")
        ])

      assert {:ok, row} = ScoutAssetSafety.by_notification_id(70, authorize?: false)
      assert row.character_name == "Fatloard"
      assert_received {:scout_intel_ingested, :structures}

      # A poll that finds nothing new is silent: re-serving the same page
      # must not re-render every open /scout every ten minutes.
      :ok = WandererApp.Sync.Feeds.AssetSafetyFeed.upsert(character, [notification(70)])
      refute_received {:scout_intel_ingested, :structures}
    end
  end
end
