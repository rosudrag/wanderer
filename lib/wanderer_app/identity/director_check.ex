defmodule WandererApp.Identity.DirectorCheck do
  @moduledoc """
  Live-checked, short-TTL-cached "does this character hold the Director
  role in their corporation right now" — never a stored boolean, never a
  manually-editable row. See docs/chewy/corp-suite-plan.md §2.4.

  Staleness window: up to 15 minutes between a director being kicked/
  demoted in-game and this cache reflecting it, for app-level UI gating
  only. Every ESI call subsequently made with that character's token is
  independently re-checked by CCP at call time — a demoted director's
  cached `true` cannot pull real ESI data, only mask a stale UI affordance
  for up to 15 minutes.
  """

  @director_role_scope "esi-characters.read_corporation_roles.v1"
  @cache_ttl :timer.minutes(15)

  @doc """
  `true` only if `character` currently holds the Director role in
  `corporation_id`. Never raises — a character lacking the scope, a
  corporation mismatch, or an ESI error all resolve to `false`.
  """
  def esi_director?(character, corporation_id)

  def esi_director?(%{corporation_id: char_corp_id}, corporation_id)
      when char_corp_id != corporation_id,
      do: false

  def esi_director?(%{scopes: scopes} = character, _corporation_id)
      when is_binary(scopes) do
    if String.contains?(scopes, @director_role_scope) do
      cache_key = "director_v1:#{character.id}"

      case Cachex.get(:esi_auth_cache, cache_key) do
        {:ok, nil} -> fetch_and_cache(character, cache_key)
        {:ok, cached} when is_boolean(cached) -> cached
        _ -> fetch_and_cache(character, cache_key)
      end
    else
      false
    end
  end

  def esi_director?(_character, _corporation_id), do: false

  defp fetch_and_cache(character, cache_key) do
    result =
      case WandererApp.Esi.get_character_roles(character.eve_id,
             access_token: character.access_token
           ) do
        {:ok, %{"roles" => roles}} when is_list(roles) -> "Director" in roles
        _ -> false
      end

    Cachex.put(:esi_auth_cache, cache_key, result, ttl: @cache_ttl)
    result
  end
end
