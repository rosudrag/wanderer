defmodule WandererApp.Scout.AssetSafety do
  @moduledoc """
  CHEWY PATCH: the parse, the reads and the counters behind `/scout`'s
  asset-safety trigger. The poller itself is
  `WandererApp.Sync.Feeds.AssetSafetyFeed`.

  ## The mechanic

  Put one item in a structure that is unanchoring. The moment the
  decommission completes, EVE moves that item to asset safety and sends
  the item's owner a `StructureItemsMovedToSafety` notification naming
  the structure and the system. The hull is now floating, unanchored,
  and anyone can scoop it. That notification is therefore the earliest
  possible signal that a specific structure is loot RIGHT NOW — hours
  ahead of the next sweep that happens to fly through, and days ahead of
  `WandererApp.Scout.Unanchor`'s 7-day upper bound, which is all this
  app could say before.

  ## The wire

  `GET /characters/{id}/notifications/` (scope
  `esi-characters.read_notifications.v1`, ESI-cached 600s) returns the
  most recent ~50 notifications as

      %{"notification_id" => 123, "type" => "StructureItemsMovedToSafety",
        "timestamp" => "2026-10-09T18:22:00Z", "text" => "<yaml>"}

  and `text` is a flat YAML document:

      assetSafetyDurationFull: 1728000
      assetSafetyFullTimestamp: 133147182000000000
      isCorpOwned: true
      newStationID: 60014707
      solarSystemID: 30002543
      structureID: 1035466617946
      structureLink: <a href="showinfo:35832//1035466617946">...</a>
      structureShowInfoData:
      - showinfo
      - 35832
      structureTypeID: 35832

  Two things about it are load-bearing:

    * **It is parsed line-wise, not with a YAML library.** This app has
      no YAML dependency and a notification body is not worth one. Only
      scalar `key: value` lines are read; list items (`- showinfo`) and
      the HTML in `structureLink` are ignored by construction, so the
      one value that can contain a colon never reaches a parser.

    * **Keys are matched case-insensitively.** Published field lists for
      these notifications disagree about case (`StructureID` in the Go
      bindings' struct names, `structureID` on the wire), and a trigger
      that silently stops firing because CCP changed a capital is the
      worst failure this feature has. Every key is downcased on both
      sides of the comparison.

    * **Timestamps are .NET ticks**, 100-nanosecond intervals since
      0001-01-01 — `133147182000000000`, not a unix epoch. The notification's
      own `timestamp` field is ordinary ISO8601; only the in-text
      asset-safety deadlines are ticks. `to_datetime/1` accepts either,
      and rejects anything that lands outside 2003..2100 rather than
      storing a year-1 date.

  ## The horizon

  Seven days, matching `WandererApp.Scout.Alerts.horizon_days/0` and for
  the same reason: a hull that came out of the ground last spring is not
  a thing to undock for, and "did you pick 24 hours or 90 days" is the
  wrong question to ask about an alert. The page's window selector does
  not apply to this board, deliberately — every other filter does.
  """

  require Ash.Query
  require Logger

  alias WandererApp.Api.{Character, ScoutAssetSafety, ScoutStructure, SyncRun}

  # The ESI notification types that mean "a structure finished
  # unanchoring and its contents went to asset safety". One today;
  # `WandererApp.Api.ScoutAssetSafety` stores the type so a second one
  # costs no migration.
  @types ["StructureItemsMovedToSafety"]

  # The ESI scope the feed needs. Mirrored as a literal in
  # config/runtime.exs's scope strings (which are evaluated before this
  # module is necessarily loaded), so the two are kept in step by
  # `test/integration/scout_asset_safety_test.exs`.
  @scope "esi-characters.read_notifications.v1"

  @horizon_days 7

  # EVE's in-notification timestamps are Windows FILETIME: 100-nanosecond
  # intervals since 1601-01-01, not since the unix epoch and NOT since
  # year 1 (which is the .NET `DateTime.Ticks` epoch the field is often
  # mislabelled with — reading a real value that way lands in the year
  # 423 and the whole trigger silently parses to nothing).
  @ticks_per_second 10_000_000
  @ticks_epoch_offset 11_644_473_600

  # Anything outside this is a parse failure, not a date.
  @min_unix 1_041_379_200
  @max_unix 4_102_444_800

  @watchers_cache_key "scout:asset_safety:watchers"
  @watchers_cache_ttl :timer.minutes(1)

  @doc "The ESI notification types this feature acts on."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The ESI scope a character must have consented to."
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc "How far back a trigger still counts as actionable."
  @spec horizon_days() :: pos_integer()
  def horizon_days, do: @horizon_days

  @doc "The cutoff `horizon_days/0` implies."
  @spec since(DateTime.t()) :: DateTime.t()
  def since(now \\ DateTime.utc_now()), do: DateTime.add(now, -@horizon_days, :day)

  # -------------------------------------------------------------------
  # Parse
  # -------------------------------------------------------------------

  @doc """
  Turns one ESI notification into row attributes, or `:skip`.

  `:skip` covers every uninteresting shape — the wrong type, a body with
  no `structureID`, a timestamp that will not parse — because a feed
  reading 50 notifications of which 48 are mining-ledger spam must not
  treat 48 skips as 48 errors.
  """
  @spec parse(map()) :: {:ok, map()} | :skip
  def parse(%{"type" => type} = notification) when type in @types do
    fields = parse_text(Map.get(notification, "text"))

    required = [
      {:notification_id, integer(Map.get(notification, "notification_id")),
       Map.get(notification, "notification_id")},
      {:notified_at, iso8601(Map.get(notification, "timestamp")),
       Map.get(notification, "timestamp")},
      {:structure_id, integer(fields["structureid"]), fields["structureid"]},
      {:solar_system_id, integer(fields["solarsystemid"]), fields["solarsystemid"]}
    ]

    case Enum.filter(required, fn {_name, result, _raw} -> result == :error end) do
      [] ->
        values = Map.new(required, fn {name, {:ok, value}, _raw} -> {name, value} end)

        {:ok,
         %{
           notification_id: values.notification_id,
           type: type,
           notified_at: values.notified_at,
           structure_id: values.structure_id,
           solar_system_id: values.solar_system_id,
           structure_type_id: optional_integer(fields["structuretypeid"]),
           new_station_id: optional_integer(fields["newstationid"]),
           is_corp_owned: boolean(fields["iscorpowned"]),
           asset_safety_min_at: optional_datetime(fields["assetsafetyminimumtimestamp"]),
           asset_safety_full_at: optional_datetime(fields["assetsafetyfulltimestamp"])
         }}

      failed ->
        # A notification of a type we ACT on that did not parse is the
        # one silent failure this feature cannot afford — it is
        # indistinguishable, on every board, from the hull never coming
        # out of the ground. The wrong type stays silent (48 of 50
        # notifications are mining-ledger spam); this does not, and it
        # names the FIELD and the raw value, because "did not parse"
        # over a ten-key body is a second investigation.
        Logger.warning(
          "[Scout.AssetSafety] #{type} #{inspect(Map.get(notification, "notification_id"))} " <>
            "did not parse: " <>
            Enum.map_join(failed, ", ", fn {name, _result, raw} ->
              "#{name}=#{inspect(raw)}"
            end)
        )

        :skip
    end
  end

  def parse(_notification), do: :skip

  @doc """
  How many notifications arrived and which `Structure*` types were among
  them.

  Logged on every changed fetch (a 304 carries no body, so this only
  runs when EVE actually sent something new). It is the only thing that
  can tell "the feed is reading and EVE sent no structure notification"
  apart from "the feed is broken" — which is exactly the question the
  Eurgrana miss raised and nothing could answer.
  """
  @spec type_histogram([map()]) :: %{String.t() => pos_integer()}
  def type_histogram(notifications) when is_list(notifications) do
    notifications
    |> Enum.map(&Map.get(&1, "type"))
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(String.downcase(&1), "structure")))
    |> Enum.frequencies()
  end

  def type_histogram(_notifications), do: %{}

  @doc """
  The scalar `key: value` pairs of a notification body, keys downcased.

  List items, blank lines and anything without a colon are dropped. The
  value keeps its own colons (`structureLink`'s HTML), which is why the
  split is on the FIRST colon only.
  """
  @spec parse_text(String.t() | nil) :: %{String.t() => String.t()}
  def parse_text(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      trimmed = String.trim(line)

      case String.starts_with?(trimmed, "-") do
        true ->
          acc

        false ->
          case String.split(trimmed, ":", parts: 2) do
            [key, value] ->
              key = key |> String.trim() |> String.downcase()
              value = String.trim(value)

              if key == "" or value == "", do: acc, else: Map.put_new(acc, key, value)

            _no_colon ->
              acc
          end
      end
    end)
  end

  def parse_text(_text), do: %{}

  @doc """
  An EVE FILETIME-ticks or unix-seconds integer as a `DateTime`.

  Both appear in EVE data and they are eight orders of magnitude apart,
  so the magnitude is the discriminator. Anything that does not land in
  2003..2100 is `:error`.
  """
  @spec to_datetime(term()) :: {:ok, DateTime.t()} | :error
  def to_datetime(value) do
    with {:ok, number} <- integer(value) do
      unix =
        if number > @max_unix do
          div(number, @ticks_per_second) - @ticks_epoch_offset
        else
          number
        end

      if unix >= @min_unix and unix <= @max_unix do
        {:ok, unix |> DateTime.from_unix!() |> DateTime.truncate(:second)}
      else
        :error
      end
    end
  end

  # -------------------------------------------------------------------
  # Write
  # -------------------------------------------------------------------

  @doc """
  Stores the triggers in a character's notification list.

  Idempotent on `notification_id`: ESI re-serves the same ~50 rows on
  every poll, so "already stored" is the normal case, not an error.
  Returns how many rows were new, which is what the feed logs and what
  decides whether anything needs invalidating.
  """
  @spec store([map()], map()) :: non_neg_integer()
  def store(notifications, character) when is_list(notifications) do
    notifications
    |> Enum.map(&parse/1)
    |> Enum.reduce(0, fn
      {:ok, attrs}, stored -> stored + insert(attrs, character)
      :skip, stored -> stored
    end)
  end

  defp insert(attrs, character) do
    case ScoutAssetSafety.by_notification_id(attrs.notification_id, authorize?: false) do
      {:ok, _already_stored} ->
        0

      _not_found ->
        attrs
        |> Map.merge(known_structure(attrs.structure_id))
        |> Map.put_new_lazy(:group_name, fn -> type_name(attrs.structure_type_id) end)
        |> Map.put(:character_eve_id, optional_integer(character.eve_id))
        |> Map.put(:character_name, character.name)
        |> ScoutAssetSafety.create(authorize?: false)
        |> case do
          {:ok, _row} ->
            1

          {:error, reason} ->
            Logger.warning("[Scout.AssetSafety] could not store trigger: #{inspect(reason)}")
            0
        end
    end
  end

  # What the sweep feed already knows about this structure, if anything.
  # Absent is the interesting case and must stay cheap: a structure
  # nobody ever flew past has no row, and the notification is then the
  # ONLY thing that has ever mentioned it.
  defp known_structure(structure_id) do
    case ScoutStructure.by_structure_id(structure_id, authorize?: false) do
      {:ok, row} ->
        %{
          structure_name: row.structure_name,
          group_name: row.group_name,
          owner_name: row.owner_name,
          nearest_celestial: row.nearest_celestial
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _unknown ->
        %{}
    end
  end

  # The badge of last resort: "Astrahus" beats a 13-digit id on a board.
  # One cached ESI call per structure type, shared with the rest of the
  # app through `:api_cache`.
  defp type_name(nil), do: nil

  defp type_name(type_id) do
    case WandererApp.Esi.get_type_info(type_id) do
      {:ok, %{"name" => name}} when is_binary(name) -> name
      _unresolved -> nil
    end
  end

  # -------------------------------------------------------------------
  # Read
  # -------------------------------------------------------------------

  @doc """
  The board: triggers inside `horizon_days/0`, newest first, one row per
  structure.

  Options are the page's own filters — `:system_id`, `:q`, `:space` —
  and every one of them applies, including on the alert banner, which is
  the rule every other filter on `/scout` follows.
  """
  @spec recent(keyword()) :: [ScoutAssetSafety.t()]
  def recent(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    ScoutAssetSafety
    |> Ash.Query.for_read(:recent, %{
      since: since(now) |> DateTime.truncate(:second),
      system_id: Keyword.get(opts, :system_id),
      q: Keyword.get(opts, :q)
    })
    |> WandererApp.Scout.Space.filter(Keyword.get(opts, :space, WandererApp.Scout.Space.all()))
    |> fold()
    |> Ash.Query.limit(Keyword.get(opts, :limit, 250))
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  @doc """
  `DISTINCT ON (structure_id) ORDER BY notified_at DESC` — the newest
  trigger per structure.

  Two of your characters with an item in the same hull is the expected
  case, not an edge one, and three rows that say "this Astrahus came out
  of the ground" are one finding.
  """
  @spec fold(Ash.Query.t()) :: Ash.Query.t()
  def fold(query) do
    query
    |> Ash.Query.distinct([:structure_id])
    |> Ash.Query.distinct_sort(notified_at: :desc)
  end

  @doc """
  How many distinct structures are inside the horizon. Feeds the sidebar
  badge through `WandererApp.Scout.Alerts.count_cached/0`, so it is
  bounded rather than counted: the badge reads "9+" past that.
  """
  @spec count(pos_integer()) :: non_neg_integer()
  def count(cap \\ 10), do: recent(limit: cap) |> length()

  @doc """
  Who is actually being polled, and whether their feed is healthy.

  `/scout` renders this beside the board: a board that is empty because
  nobody has consented and a board that is empty because nothing has
  unanchored look identical, and the first one is a bug the reader can
  fix in two clicks. `stalled` is the scheduler's own verdict (5
  consecutive failures) — a character who consented and later revoked
  the scope shows up there rather than silently never reporting.
  """
  @spec watchers() :: %{count: non_neg_integer(), stalled: non_neg_integer()}
  def watchers do
    case WandererApp.Cache.get(@watchers_cache_key) do
      nil ->
        value = %{count: length(watching_characters()), stalled: stalled_count()}
        WandererApp.Cache.put(@watchers_cache_key, value, ttl: @watchers_cache_ttl)
        value

      cached ->
        cached
    end
  end

  @doc "Drops the cached watcher summary. Called whenever a character's consent may have changed."
  @spec invalidate_watchers() :: any()
  def invalidate_watchers, do: WandererApp.Cache.delete(@watchers_cache_key)

  @doc """
  Every character whose stored token actually carries the notifications
  scope.

  This is the whole opt-in model, and it is a FILTER rather than a
  try-and-see: EVE SSO only ever grants what was requested, so a
  character who logged in before this feature existed has a perfectly
  valid token that 403s on this one endpoint. Polling them all would
  burn ESI's error budget every ten minutes for every pre-existing
  character on the deployment.
  """
  @spec watching_characters() :: [Character.t()]
  def watching_characters do
    scope = @scope

    # `scopes` only. `access_token` is NOT in this filter even though an
    # unauthenticated character is useless here: AshCloak encrypts that
    # column at rest (see `cloak do` in `WandererApp.Api.Character`), so
    # a SQL predicate on it matches nothing and the read fails silently
    # — which it did, and every character looked un-consented. A dead or
    # missing token is the feed's own problem: `token_holder/1` re-reads
    # the row and the scheduler reports the failure as `:stalled`, which
    # /scout renders next to the board.
    Character
    |> Ash.Query.filter(deleted == false and contains(scopes, ^scope))
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, characters} -> characters
      {:error, _reason} -> []
    end
  end

  defp stalled_count do
    name = inspect(WandererApp.Sync.Feeds.AssetSafetyFeed)

    SyncRun
    |> Ash.Query.filter(feed_name == ^name and status == :stalled)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, runs} -> length(runs)
      {:error, _reason} -> 0
    end
  end

  # -------------------------------------------------------------------
  # Coercion
  # -------------------------------------------------------------------

  defp integer(value) when is_integer(value), do: {:ok, value}

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _rest} -> {:ok, number}
      :error -> :error
    end
  end

  defp integer(_value), do: :error

  defp optional_integer(value) do
    case integer(value) do
      {:ok, number} -> number
      :error -> nil
    end
  end

  defp optional_datetime(value) do
    case to_datetime(value) do
      {:ok, at} -> at
      :error -> nil
    end
  end

  defp boolean(value) when is_boolean(value), do: value

  defp boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> true
      "false" -> false
      _other -> nil
    end
  end

  defp boolean(_value), do: nil

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, DateTime.truncate(at, :second)}
      _error -> :error
    end
  end

  defp iso8601(_value), do: :error
end
