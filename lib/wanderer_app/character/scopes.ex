defmodule WandererApp.Character.Scopes do
  @moduledoc """
  CHEWY PATCH: which ESI permissions this deployment asks for TODAY,
  versus the ones a character actually granted when it logged in.

  ## Why this has to be visible

  EVE SSO grants exactly what was requested at login, and a refresh
  never widens a token. So the day a feature needs a new scope, every
  character that already exists keeps a perfectly valid token that
  simply 403s on the new call — forever, silently, until a human happens
  to log that character in again. Nothing in the app said so: the
  Characters page only ever flagged `access_token == nil` ("invalid
  token"), which is a DIFFERENT failure, and a character missing a scope
  looks completely healthy next to it.

  That is not hypothetical — `WANDERER_SCOUT_ASSET_SAFETY` added
  `esi-characters.read_notifications.v1` and `esi-assets.read_assets.v1`
  to the login request, and every character on the deployment was
  instantly behind, with no way to find out except reading the feature's
  own board and noticing it was empty.

  ## `default_scope` is the baseline, and nothing else is

  The required set is read from the RUNNING ueberauth config
  (`config/runtime.exs`'s `default_scope`), not from a list hard-coded
  here, so a scope added to that string is reported the same day with no
  second edit — which is the entire point of this module.

  The wallet/admin/director tiers are deliberately NOT part of it: they
  are opt-in grants a user may legitimately never have wanted, and
  flagging their absence would mark every ordinary character as stale
  forever. `wallet?/1` answers that question separately, for the one
  place it matters: a re-authorisation must not silently DOWNGRADE a
  character that already had wallet access.
  """

  @wallet_scope "esi-wallet.read_character_wallet.v1"

  # The human half of the badge. A reader deciding whether to re-log a
  # character needs to know what it buys, not a scope URN.
  @labels %{
    "esi-location.read_location.v1" => "where the character is",
    "esi-location.read_ship_type.v1" => "what it is flying",
    "esi-location.read_online.v1" => "whether it is logged in",
    "esi-ui.write_waypoint.v1" => "setting its autopilot",
    "esi-search.search_structures.v1" => "structure search",
    "esi-characters.read_notifications.v1" => "asset-safety alerts on /scout",
    "esi-assets.read_assets.v1" => "which structures it has seeded",
    @wallet_scope => "wallet balance"
  }

  @doc """
  The scopes an ordinary login asks EVE for right now.

  Read from the running ueberauth config rather than duplicated here —
  see @moduledoc. Empty list when that config is absent, which makes
  this module inert rather than noisy on a half-configured instance.
  """
  @spec required() :: [String.t()]
  def required do
    :ueberauth
    |> Application.get_env(Ueberauth, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(:eve)
    |> case do
      {_strategy, opts} -> Keyword.get(opts, :default_scope, "")
      _not_configured -> ""
    end
    |> split()
  end

  @doc "The scopes a character actually holds."
  @spec granted(map()) :: [String.t()]
  def granted(%{scopes: scopes}), do: split(scopes)
  def granted(_character), do: []

  @doc """
  The required scopes this character does not hold, in the order they
  appear in the request string.
  """
  @spec missing(map()) :: [String.t()]
  def missing(character) do
    held = MapSet.new(granted(character))

    Enum.reject(required(), &MapSet.member?(held, &1))
  end

  @doc """
  True when the character would 403 on something this deployment now
  expects to work.

  A character with NO stored scopes at all is reported as stale rather
  than as fine: an empty `scopes` column means nothing is known about
  what it granted, and guessing "everything" is the one answer that
  hides the problem.
  """
  @spec stale?(map()) :: boolean()
  def stale?(character), do: missing(character) != []

  @doc "Whether this character already granted wallet access."
  @spec wallet?(map()) :: boolean()
  def wallet?(character), do: @wallet_scope in granted(character)

  @doc "What a scope buys, in a reader's words. Falls back to the scope itself."
  @spec label(String.t()) :: String.t()
  def label(scope), do: Map.get(@labels, scope, scope)

  @doc "`missing/1` as one sentence for a tooltip."
  @spec summary(map()) :: String.t()
  def summary(character) do
    character
    |> missing()
    |> Enum.map(&label/1)
    |> Enum.join(", ")
  end

  defp split(scopes) when is_binary(scopes), do: String.split(scopes, " ", trim: true)
  defp split(_scopes), do: []
end
