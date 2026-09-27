# dev/seed_identity.exs
#
# Seeds the fixtures the identity suite tests and `check.ps1 -Routes` need:
# one `WandererApp.Api.OwnedCorporation`, and one `WandererApp.Api.User`
# with two characters — one whose `corporation_id` matches that corp
# (eligible to become the account's "main"), one that does not (guest-only).
#
# New seeding lives HERE, not in `lib/wanderer_app/dev/seed.ex` — that
# module seeds an unrelated 15-system map fixture for the map-canvas smoke
# flow documented in `dev/README.md` and has nothing to do with the
# identity suite.
#
# Idempotent: re-running finds existing rows by their identity keys
# (`eve_corporation_id`, `hash`, `eve_id`) and updates them in place rather
# than duplicating.
#
# Run with the full application started (Repo pool, Ash, PubSub, etc.) but
# WITHOUT the HTTP listener or the npm/esbuild watcher. `mix run` leaves
# `config :wanderer_app, WandererAppWeb.Endpoint, server: false` (Phoenix
# only starts watchers when `server?` is true or `force_watchers` is set —
# see `Phoenix.Endpoint.Supervisor.watcher_children/3`), so this is safe on
# a checkout with no local `npm install`:
#
#   mix run dev/seed_identity.exs
#
alias WandererApp.Api.{Character, OwnedCorporation, User}

corp_eve_id = 98_765_432
user_hash = "dev-check-identity-seed"
in_corp_eve_id = "3100000101"
out_corp_eve_id = "3100000102"
fake_token = "dev-check-fake-token"
# Year 3000 — matches WandererAppWeb.DevAuthController's convention so
# nothing here ever attempts a real ESI token refresh.
far_future = 32_503_680_000

corp =
  case OwnedCorporation.by_corporation_id(corp_eve_id) do
    {:ok, corp} ->
      corp

    {:error, _not_found} ->
      {:ok, corp} =
        OwnedCorporation.create(%{
          eve_corporation_id: corp_eve_id,
          name: "Dev Check Corp",
          ticker: "DVCK",
          enabled: true
        })

      corp
  end

user =
  case User.by_hash(user_hash) do
    {:ok, user} ->
      user

    {:error, _not_found} ->
      {:ok, user} =
        WandererApp.Api.User
        |> Ash.Changeset.for_create(:create, %{name: "Dev Check Identity Seed", hash: user_hash})
        |> Ash.create()

      user
  end

upsert_character = fn eve_id, name, corporation_id ->
  character =
    case Character.by_eve_id(eve_id) do
      {:ok, character} ->
        character

      {:error, _not_found} ->
        {:ok, character} =
          Character.create(%{
            eve_id: eve_id,
            name: name,
            access_token: fake_token,
            refresh_token: fake_token,
            expires_at: far_future,
            scopes: ""
          })

        character
    end

  character =
    if character.user_id == user.id do
      character
    else
      Character.assign_user!(character, %{user_id: user.id})
    end

  in_corp? = corporation_id == corp.eve_corporation_id

  {:ok, character} =
    Character.update_corporation(character, %{
      corporation_id: corporation_id,
      corporation_name: if(in_corp?, do: corp.name, else: "Some Other Corp"),
      corporation_ticker: if(in_corp?, do: corp.ticker, else: "OTHR")
    })

  character
end

in_corp_character =
  upsert_character.(in_corp_eve_id, "Dev Check In Corp", corp.eve_corporation_id)

out_corp_character = upsert_character.(out_corp_eve_id, "Dev Check Out Of Corp", 111_111_111)

IO.puts("OwnedCorporation: #{corp.name} (#{corp.eve_corporation_id})")
IO.puts("User: #{user.name} (#{user.id})")

IO.puts(
  "Character in corp: #{in_corp_character.name} (corporation_id=#{in_corp_character.corporation_id})"
)

IO.puts(
  "Character out of corp: #{out_corp_character.name} (corporation_id=#{out_corp_character.corporation_id})"
)
