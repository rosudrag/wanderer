defmodule WandererApp.Api do
  @moduledoc false

  use Ash.Domain,
    extensions: [AshJsonApi.Domain]

  authorization do
    authorize :when_requested
  end

  json_api do
    prefix "/api/v1"
    log_errors?(true)
  end

  resources do
    resource WandererApp.Api.AccessList
    resource WandererApp.Api.AccessListMember
    resource WandererApp.Api.Character
    resource WandererApp.Api.Map
    resource WandererApp.Api.MapAccessList
    resource WandererApp.Api.MapSolarSystem
    resource WandererApp.Api.MapSolarSystemJumps
    resource WandererApp.Api.MapChainPassages
    resource WandererApp.Api.MapConnection
    resource WandererApp.Api.MapState
    resource WandererApp.Api.MapSystem
    resource WandererApp.Api.MapSystemComment
    resource WandererApp.Api.MapSystemSignature
    resource WandererApp.Api.MapSystemStructure
    resource WandererApp.Api.MapCharacterSettings
    resource WandererApp.Api.MapSubscription
    resource WandererApp.Api.MapTransaction
    resource WandererApp.Api.MapUserSettings
    resource WandererApp.Api.MapDefaultSettings
    resource WandererApp.Api.User
    resource WandererApp.Api.ShipTypeInfo
    resource WandererApp.Api.UserActivity
    resource WandererApp.Api.UserTransaction
    resource WandererApp.Api.CorpWalletTransaction
    resource WandererApp.Api.License
    resource WandererApp.Api.MapPing
    resource WandererApp.Api.MapInvite
    resource WandererApp.Api.MapWebhookSubscription
    resource WandererApp.Api.OwnedCorporation
    resource WandererApp.Api.Group
    resource WandererApp.Api.GroupMembership
    resource WandererApp.Api.GroupAutoRule
    resource WandererApp.Api.GroupPermission
    resource WandererApp.Api.StandingGrant
    resource WandererApp.Api.UserIdentity
    resource WandererApp.Api.AuditLog
    resource WandererApp.Api.GroupMapAccessGrant
    resource WandererApp.Api.GroupMapSyncedMember
    resource WandererApp.Api.SyncRun
    resource WandererApp.Api.CorpRosterSnapshot
    # CHEWY PATCH: scout intel log. See WandererApp.Scout.Ingest.
    resource WandererApp.Api.ScoutSpawnSighting
    resource WandererApp.Api.ScoutStructureSighting
    # CHEWY PATCH: scout coverage ledger. See WandererApp.Scout.Coverage.
    resource WandererApp.Api.ScoutSystemCoverage
  end
end
