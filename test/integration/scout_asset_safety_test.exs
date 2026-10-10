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

  # A real notification body: lowerCamelCase keys, .NET ticks, a
  # colon-bearing HTML value, and a YAML list this parser must ignore.
  defp text(structure_id \\ @structure_id, system_id \\ @system) do
    """
    assetSafetyDurationFull: 1728000
    assetSafetyDurationMinimum: 432000
    assetSafetyFullTimestamp: 133147182000000000
    assetSafetyMinimumTimestamp: 133142862000000000
    isCorpOwned: true
    newStationID: 60014707
    solarSystemID: #{system_id}
    structureID: #{structure_id}
    structureLink: <a href="showinfo:35832//#{structure_id}">Some Astrahus</a>
    structureShowInfoData:
    - showinfo
    - 35832
    - #{structure_id}
    structureTypeID: 35832
    """
  end

  defp notification(id, opts \\ []) do
    %{
      "notification_id" => id,
      "type" => Keyword.get(opts, :type, "StructureItemsMovedToSafety"),
      "sender_id" => 1_000_132,
      "sender_type" => "corporation",
      "is_read" => false,
      "timestamp" => Keyword.get(opts, :timestamp, "2026-10-09T18:22:00Z"),
      "text" =>
        Keyword.get(opts, :text, text(Keyword.get(opts, :structure_id, @structure_id), @system))
    }
  end

  defp character(overrides \\ %{}) do
    Map.merge(%{eve_id: "2112625428", name: "Fatloard"}, overrides)
  end

  describe "parse/1" do
    test "reads the structure, the system and both asset-safety deadlines" do
      assert {:ok, attrs} = AssetSafety.parse(notification(1))

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
      assert 1 == AssetSafety.store([notification(40)], character())

      assert 1 ==
               AssetSafety.store(
                 [
                   notification(41,
                     structure_id: @other_structure_id,
                     timestamp: "2026-10-10T09:00:00Z"
                   )
                 ],
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
      assert Map.keys(Seeding.armed_by([60_003_760, 30_000_142, @structure_id])) == [@structure_id]
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
