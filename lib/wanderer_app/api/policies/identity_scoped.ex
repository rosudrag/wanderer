defmodule WandererApp.Api.Policies.IdentityScoped do
  @moduledoc """
  Ash.Policy.Authorizer checks for the identity/group system. Mirrors
  `WandererApp.Api.Policies.MapScoped`/`AclScoped`'s bypass-then-check
  shape (`lib/wanderer_app/api/policies/map_scoped.ex:31-56`,
  `acl_scoped.ex:21-39`).

  Every check here uses `is_struct/2`, never a `%User{}` struct pattern —
  `MapScoped.Trusted` documents why (`map_scoped.ex:36-42`): a
  compile-time struct pattern on `WandererApp.Api.User` would close a
  cycle back through `User`'s own policy referencing this module, and
  `mix compile --force` deadlocks on it. Every future policy check added
  to this identity system must follow the same rule.

  Not attached to any resource as of Phase 0 — `Group`/`GroupMembership`/
  `GroupAutoRule`/`GroupPermission`/`StandingGrant`/`UserIdentity`/
  `OwnedCorporation`/`AuditLog` all follow the un-policed internal-resource
  pattern `WandererApp.Api.Character` already uses (no `authorizers:`, no
  `policies do`, no `json_api do` — unreachable from JSON:API, so a policy
  there would only gate internal callers, which this repo's own `User`
  resource documents as unnecessary for a route-less resource). This
  module exists ready for whichever future resource needs write-gating
  via a LiveView-driven session actor (Phase 1's `GroupMapAccessGrant` and
  later).
  """

  def trusted, do: {__MODULE__.Trusted, []}
  def has_permission(perm), do: {__MODULE__.HasPermission, permission: perm}
  def in_state(state), do: {__MODULE__.InState, state: state}

  defmodule Trusted do
    @moduledoc false
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(_), do: "actor is a session User"

    @impl true
    def match?(actor, _ctx, _opts) when is_struct(actor, WandererApp.Api.User), do: true
    def match?(_actor, _ctx, _opts), do: false
  end

  defmodule HasPermission do
    @moduledoc false
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(opts), do: "actor's user holds permission #{opts[:permission]}"

    @impl true
    def match?(actor, _ctx, permission: perm) when is_struct(actor, WandererApp.Api.User) do
      WandererApp.Identity.PermissionCache.has_permission?(actor.id, perm)
    end

    def match?(_actor, _ctx, _opts), do: false
  end

  defmodule InState do
    @moduledoc false
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(opts), do: "actor's user is in state #{opts[:state]}"

    @impl true
    def match?(actor, _ctx, state: state) when is_struct(actor, WandererApp.Api.User) do
      WandererApp.Identity.StateEngine.state_of(actor) == state
    end

    def match?(_actor, _ctx, _opts), do: false
  end
end
