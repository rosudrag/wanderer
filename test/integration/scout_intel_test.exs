defmodule WandererApp.ScoutIntelTest do
  @moduledoc """
  Covers the two parts of the scout intel feature that would be
  consumer-visible if they broke:

    * `WandererApp.Scout.Ingest` — the client is a LavishScript bot that
      sends every value as a string and re-sends rows it already sent, so
      the coercion rules and the upsert identity ARE the contract. A
      regression here shows up as duplicated log rows or dropped
      observations, neither of which is loud.

    * `WandererApp.Identity.ScoutAccess` — the permission tier. The whole
      point of `:scout_intel_view` is that a `:corp_suite_admin` cannot
      grant it; if that check regresses, the feature silently becomes
      "any admin can read the fleet's intel", which is exactly what it
      was built not to be.

  See `docs/chewy/scout-intel.md`.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{ScoutSpawnSighting, ScoutStructureSighting}
  alias WandererApp.Identity.{PermissionCache, ScoutAccess}
  alias WandererApp.Scout.Ingest

  setup do
    on_exit(fn ->
      Application.delete_env(:wanderer_app, :bootstrap_admin_character)
    end)

    :ok
  end

  # A structures.tsv row exactly as the client sends it: every value a
  # string, booleans as "TRUE"/"FALSE", and `type_name` carrying the
  # player-set structure name.
  defp structure_row(overrides \\ %{}) do
    Map.merge(
      %{
        "utc_timestamp" => "2026-09-27 17:38:15",
        "character" => "Quillestra Acvestra",
        "event" => "CHANGE",
        "system_id" => "30002099",
        "system_name" => "Egmar",
        "system_truesec" => "0.25287",
        "structure_id" => "1055680805214",
        "type_id" => "35832",
        "type_name" => "Egmar - Test Citadel",
        "group_name" => "Citadel",
        "owner_id" => "98790508",
        "owner_name" => "Moonlight Mouse Hole",
        "alliance_id" => "99014050",
        "upkeep_state" => "1",
        "structure_state" => "112",
        "status" => "ArmorVulnerable",
        "vulnerable" => "TRUE",
        "anchoring" => "FALSE",
        "unanchoring" => "FALSE",
        "timer_seconds" => "896",
        "shield_pct" => "0",
        "armor_pct" => "100",
        "hull_pct" => "100",
        "distance_m" => "225354"
      },
      overrides
    )
  end

  defp spawn_row(overrides \\ %{}) do
    Map.merge(
      %{
        "utc_timestamp" => "2026-09-29 10:12:41",
        "character" => "Dracliras Loot Goblin",
        "system_id" => "30002698",
        "system_name" => "Aliette",
        "system_truesec" => "0.37128",
        "location_type" => "belt",
        "location_name" => "Aliette IV - Asteroid Belt 1",
        "spawn_name" => "Serpentis Clone Soldier Trainer",
        "spawn_category" => "faction",
        "players_in_local" => "4",
        "action_taken" => "scouted",
        "outcome" => "scouted",
        "entity_id" => "9002310729000024265",
        "minutes_since_downtime" => "1392",
        "isk_value" => "1000000.000000"
      },
      overrides
    )
  end

  describe "ingest coercion" do
    test "string values become typed columns, and type_name lands in structure_name" do
      assert {:ok, %{stored: 1, failed: 0}} = Ingest.ingest_structures([structure_row()], nil)

      assert {:ok, [row]} = ScoutStructureSighting.read()

      assert row.structure_id == 1_055_680_805_214
      assert row.solar_system_id == 30_002_099
      assert row.type_id == 35_832
      # The source column is misnamed; this is the player-set name.
      assert row.structure_name == "Egmar - Test Citadel"
      assert row.event == :change
      assert row.vulnerable == true
      assert row.anchoring == false
      assert row.system_truesec == 0.25287
      assert row.distance_m == 225_354
      assert row.observed_at == ~U[2026-09-27 17:38:15Z]
      assert row.upkeep_state == 1
      assert row.structure_state == 112
      assert row.status == "ArmorVulnerable"
      refute Map.has_key?(row, :character_name)
    end

    test "a relative timer becomes an absolute expiry" do
      assert {:ok, %{stored: 1}} = Ingest.ingest_structures([structure_row()], nil)
      assert {:ok, [row]} = ScoutStructureSighting.read()

      assert row.timer_seconds == 896
      # 17:38:15 + 896s
      assert row.timer_expires_at == ~U[2026-09-27 17:53:11Z]
    end

    test "the -1 no-timer sentinel does not become a timer in the past" do
      row = structure_row(%{"timer_seconds" => "-1"})

      assert {:ok, %{stored: 1}} = Ingest.ingest_structures([row], nil)
      assert {:ok, [stored]} = ScoutStructureSighting.read()

      assert is_nil(stored.timer_seconds)
      assert is_nil(stored.timer_expires_at)
    end

    test "an int64 entity id survives, and isk is kept exact" do
      assert {:ok, %{stored: 1}} = Ingest.ingest_spawns([spawn_row()], nil)
      assert {:ok, [row]} = ScoutSpawnSighting.read()

      assert row.entity_id == 9_002_310_729_000_024_265
      assert Decimal.equal?(row.isk_value, Decimal.new("1000000.000000"))
      assert row.players_in_local == 4
    end

    test "a row missing its timestamp fails alone; the rest of the batch stores" do
      rows = [
        %{"character" => "No Timestamp"},
        spawn_row(),
        spawn_row(%{"spawn_name" => "Dark Blood Phantom"})
      ]

      assert {:ok, result} = Ingest.ingest_spawns(rows, nil)

      assert result.received == 3
      assert result.stored == 2
      assert result.failed == 1
      assert [%{index: 0, error: error}] = result.errors
      assert error =~ "utc_timestamp"
    end

    test "an unknown event is refused rather than silently filed as :seen" do
      rows = [structure_row(%{"event" => "DESTROYED"})]

      assert {:ok, %{stored: 0, failed: 1, errors: [%{error: error}]}} =
               Ingest.ingest_structures(rows, nil)

      assert error =~ "unknown event"
    end

    test "status is stored verbatim, never re-derived from upkeep_state/structure_state" do
      # upkeep_state 1 + structure_state 110 is row 15 of the precedence
      # table ("FullPower") -- if this server ever re-derived status
      # instead of trusting the bot, this row would come back FullPower.
      # It must not: eveknob is authoritative.
      row =
        structure_row(%{
          "upkeep_state" => "1",
          "structure_state" => "110",
          "status" => "Onlining"
        })

      assert {:ok, %{stored: 1}} = Ingest.ingest_structures([row], nil)
      assert {:ok, [stored]} = ScoutStructureSighting.read()

      assert stored.upkeep_state == 1
      assert stored.structure_state == 110
      assert stored.status == "Onlining"
    end
  end

  describe "ingest idempotence" do
    test "re-sending the same rows does not duplicate them" do
      rows = [spawn_row(), spawn_row(%{"spawn_name" => "Dark Blood Phantom"})]

      assert {:ok, %{stored: 2}} = Ingest.ingest_spawns(rows, nil)
      assert {:ok, %{stored: 2, failed: 0}} = Ingest.ingest_spawns(rows, nil)

      assert {:ok, stored} = ScoutSpawnSighting.read()
      assert length(stored) == 2
    end

    test "two pilots reporting one spawn store one row, and the reporter is not kept" do
      # The rows differ ONLY by who saw it. Before attribution was dropped
      # these were two distinct identities and produced two rows.
      assert {:ok, %{stored: 1}} = Ingest.ingest_spawns([spawn_row()], nil)

      assert {:ok, %{stored: 1, failed: 0}} =
               Ingest.ingest_spawns([spawn_row(%{"character" => "Someone Else"})], nil)

      assert {:ok, [row]} = ScoutSpawnSighting.read()
      refute Map.has_key?(row, :character_name)
    end

    test "the same structure observed again later is a new row, not an overwrite" do
      first = structure_row()
      later = structure_row(%{"utc_timestamp" => "2026-09-27 19:38:15"})

      assert {:ok, %{stored: 1}} = Ingest.ingest_structures([first], nil)
      assert {:ok, %{stored: 1}} = Ingest.ingest_structures([later], nil)

      assert {:ok, rows} = ScoutStructureSighting.read()
      assert length(rows) == 2
    end
  end

  describe "repeat observations are merged, not appended" do
    # The client re-reports every structure on grid on every pass. Before
    # WandererApp.Scout.Merge that was one row per pass: three identical
    # lines in the page's timer table, and a history drill-down of 200
    # rows where three things happened.
    defp seen_row(overrides \\ %{}) do
      structure_row(Map.merge(%{"event" => "SEEN", "timer_seconds" => "-1"}, overrides))
    end

    test "an unchanged SEEN moves the stored row forward instead of adding one" do
      assert {:ok, %{stored: 1}} = Ingest.ingest_structures([seen_row()], nil)

      assert {:ok, %{stored: 1, failed: 0}} =
               Ingest.ingest_structures(
                 [seen_row(%{"utc_timestamp" => "2026-09-27 19:38:15"})],
                 nil
               )

      assert {:ok, [row]} = ScoutStructureSighting.read()
      assert row.observed_at == ~U[2026-09-27 19:38:15Z]
    end

    test "a changed status is news and keeps both rows" do
      assert {:ok, %{stored: 1}} = Ingest.ingest_structures([seen_row()], nil)

      assert {:ok, %{stored: 1}} =
               Ingest.ingest_structures(
                 [
                   seen_row(%{
                     "utc_timestamp" => "2026-09-27 19:38:15",
                     "status" => "ArmorReinforced"
                   })
                 ],
                 nil
               )

      assert {:ok, rows} = ScoutStructureSighting.read()
      assert length(rows) == 2
    end

    test "a CHANGE is never merged, in either direction" do
      assert {:ok, %{stored: 1}} = Ingest.ingest_structures([seen_row()], nil)

      assert {:ok, %{stored: 1}} =
               Ingest.ingest_structures(
                 [seen_row(%{"utc_timestamp" => "2026-09-27 19:38:15", "event" => "CHANGE"})],
                 nil
               )

      assert {:ok, rows} = ScoutStructureSighting.read()
      assert length(rows) == 2
    end

    test "the same running timer read a minute apart is the same timer" do
      # timer_seconds is re-read every pass, so a running reinforcement
      # drifts by seconds between observations. Comparing expiries for
      # equality would make every pass "news" and defeat the merge.
      assert {:ok, %{stored: 1}} =
               Ingest.ingest_structures(
                 [
                   seen_row(%{"utc_timestamp" => "2026-09-27 17:00:00", "timer_seconds" => "3600"})
                 ],
                 nil
               )

      assert {:ok, %{stored: 1}} =
               Ingest.ingest_structures(
                 [
                   seen_row(%{"utc_timestamp" => "2026-09-27 17:01:00", "timer_seconds" => "3545"})
                 ],
                 nil
               )

      assert {:ok, [row]} = ScoutStructureSighting.read()
      assert row.observed_at == ~U[2026-09-27 17:01:00Z]
    end

    test "a replayed older row never drags the stored sighting backwards" do
      assert {:ok, %{stored: 1}} =
               Ingest.ingest_structures(
                 [seen_row(%{"utc_timestamp" => "2026-09-27 19:38:15"})],
                 nil
               )

      assert {:ok, %{stored: 1}} =
               Ingest.ingest_structures(
                 [seen_row(%{"utc_timestamp" => "2026-09-27 17:38:15"})],
                 nil
               )

      assert {:ok, rows} = ScoutStructureSighting.read()
      assert Enum.map(rows, & &1.observed_at) |> Enum.max() == ~U[2026-09-27 19:38:15Z]
    end
  end

  describe "the :anchoring / :unanchoring read actions" do
    test ":anchoring returns only the anchoring family, latest row per structure" do
      earlier =
        structure_row(%{
          "structure_id" => "1111",
          "status" => "Anchoring",
          "utc_timestamp" => "2026-09-27 10:00:00"
        })

      later =
        structure_row(%{
          "structure_id" => "1111",
          "status" => "Onlining",
          "utc_timestamp" => "2026-09-27 11:00:00"
        })

      not_anchoring =
        structure_row(%{
          "structure_id" => "2222",
          "status" => "FullPower",
          "utc_timestamp" => "2026-09-27 10:30:00"
        })

      assert {:ok, %{stored: 3}} =
               Ingest.ingest_structures([earlier, later, not_anchoring], nil)

      assert {:ok, [row]} =
               ScoutStructureSighting
               |> Ash.Query.for_read(:anchoring, %{since: ~U[2026-01-01 00:00:00Z]})
               |> Ash.Query.distinct([:structure_id])
               |> Ash.Query.distinct_sort(observed_at: :desc)
               |> Ash.read(authorize?: false)

      # Only the anchoring-family structure, folded to its latest row.
      assert row.structure_id == 1_111
      assert row.status == "Onlining"
    end

    test ":unanchoring returns only status == Unanchoring, latest row per structure" do
      anchoring =
        structure_row(%{"structure_id" => "3333", "status" => "Anchoring"})

      unanchoring_early =
        structure_row(%{
          "structure_id" => "4444",
          "status" => "Unanchoring",
          "unanchoring" => "TRUE",
          "utc_timestamp" => "2026-09-27 10:00:00"
        })

      unanchoring_late =
        structure_row(%{
          "structure_id" => "4444",
          "status" => "Unanchoring",
          "unanchoring" => "TRUE",
          "utc_timestamp" => "2026-09-27 12:00:00"
        })

      assert {:ok, %{stored: 3}} =
               Ingest.ingest_structures([anchoring, unanchoring_early, unanchoring_late], nil)

      assert {:ok, [row]} =
               ScoutStructureSighting
               |> Ash.Query.for_read(:unanchoring, %{since: ~U[2026-01-01 00:00:00Z]})
               |> Ash.Query.distinct([:structure_id])
               |> Ash.Query.distinct_sort(observed_at: :desc)
               |> Ash.read(authorize?: false)

      assert row.structure_id == 4_444
      assert row.status == "Unanchoring"
      assert row.observed_at == ~U[2026-09-27 12:00:00Z]
    end
  end

  describe "the scout_intel_view permission tier" do
    setup do
      superadmin = create_user()

      superadmin_character =
        create_character(%{user_id: superadmin.id, name: "Scout Superadmin"})

      grantee = create_user()
      grantee_character = create_character(%{user_id: grantee.id, name: "Scout Grantee"})

      Application.put_env(:wanderer_app, :bootstrap_admin_character, superadmin_character.name)

      %{
        superadmin: superadmin,
        grantee: grantee,
        grantee_character: grantee_character
      }
    end

    test "the superadmin can read the log without holding an explicit grant", ctx do
      assert ScoutAccess.superadmin?(ctx.superadmin.id)
      assert ScoutAccess.can_view?(ctx.superadmin.id)
      # ...and is not listed as a revokable grant.
      assert ScoutAccess.members() == []
    end

    test "granting makes a real, PermissionCache-visible permission", ctx do
      refute ScoutAccess.can_view?(ctx.grantee.id)

      assert {:ok, user} =
               ScoutAccess.grant_by_character_name(
                 ctx.grantee_character.name,
                 ctx.superadmin.id
               )

      assert user.id == ctx.grantee.id
      assert ScoutAccess.can_view?(ctx.grantee.id)
      assert PermissionCache.has_permission?(ctx.grantee.id, :scout_intel_view)
    end

    test "the grant confers scout access and nothing else", ctx do
      assert {:ok, _} =
               ScoutAccess.grant_by_character_name(
                 ctx.grantee_character.name,
                 ctx.superadmin.id
               )

      refute PermissionCache.has_permission?(ctx.grantee.id, :corp_suite_admin)
      refute PermissionCache.corp_admin?(:none, ctx.grantee.id)
    end

    test "a corp_suite_admin cannot grant it, not even to themselves", ctx do
      # Make the grantee a full corp suite admin first: this is the exact
      # privilege level the feature must NOT be reachable from.
      {:ok, group} = WandererApp.Api.Group.create(%{name: "Admins", kind: :manual})

      {:ok, _} =
        WandererApp.Api.GroupPermission.create(%{
          group_id: group.id,
          permission: :corp_suite_admin
        })

      {:ok, _} =
        WandererApp.Api.GroupMembership.create(%{
          group_id: group.id,
          user_id: ctx.grantee.id,
          source: :manual_grant,
          status: :active
        })

      assert PermissionCache.corp_admin?(:none, ctx.grantee.id)

      assert {:error, :forbidden} =
               ScoutAccess.grant_by_character_name(ctx.grantee_character.name, ctx.grantee.id)

      refute ScoutAccess.can_view?(ctx.grantee.id)
    end

    test "granting twice leaves one member row", ctx do
      assert {:ok, _} =
               ScoutAccess.grant_by_character_name(
                 ctx.grantee_character.name,
                 ctx.superadmin.id
               )

      assert {:ok, _} =
               ScoutAccess.grant_by_character_name(
                 ctx.grantee_character.name,
                 ctx.superadmin.id
               )

      assert length(ScoutAccess.members()) == 1
    end

    test "only the superadmin can revoke", ctx do
      assert {:ok, _} =
               ScoutAccess.grant_by_character_name(
                 ctx.grantee_character.name,
                 ctx.superadmin.id
               )

      assert {:error, :forbidden} = ScoutAccess.revoke(ctx.grantee.id, ctx.grantee.id)
      assert ScoutAccess.can_view?(ctx.grantee.id)

      assert :ok = ScoutAccess.revoke(ctx.grantee.id, ctx.superadmin.id)
      refute ScoutAccess.can_view?(ctx.grantee.id)
      assert ScoutAccess.members() == []
    end

    # The sidebar icon is drawn from can_view_cached?/1 on every LiveView
    # mount. If a grant or a revoke did not invalidate it, a revoked user
    # would keep the icon (and a freshly granted one would not get it)
    # until the TTL expired.
    test "the cached answer follows a grant and a revoke immediately", ctx do
      refute ScoutAccess.can_view_cached?(ctx.grantee.id)

      assert {:ok, _} =
               ScoutAccess.grant_by_character_name(
                 ctx.grantee_character.name,
                 ctx.superadmin.id
               )

      assert ScoutAccess.can_view_cached?(ctx.grantee.id)

      assert :ok = ScoutAccess.revoke(ctx.grantee.id, ctx.superadmin.id)
      refute ScoutAccess.can_view_cached?(ctx.grantee.id)
    end

    test "a refused grant does not poison the cache", ctx do
      refute ScoutAccess.can_view_cached?(ctx.grantee.id)

      assert {:error, :forbidden} =
               ScoutAccess.grant_by_character_name(ctx.grantee_character.name, ctx.grantee.id)

      refute ScoutAccess.can_view_cached?(ctx.grantee.id)
    end

    test "with no bootstrap character configured there is no superadmin at all", ctx do
      Application.put_env(:wanderer_app, :bootstrap_admin_character, "")

      refute ScoutAccess.superadmin?(ctx.superadmin.id)

      assert {:error, :forbidden} =
               ScoutAccess.grant_by_character_name(
                 ctx.grantee_character.name,
                 ctx.superadmin.id
               )
    end

    test "granting to a character nobody has ever logged in as is refused", ctx do
      assert {:error, :character_not_found} =
               ScoutAccess.grant_by_character_name("No Such Pilot", ctx.superadmin.id)
    end
  end
end
