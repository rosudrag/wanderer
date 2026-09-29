defmodule WandererAppWeb.CorpManagementLive do
  @moduledoc """
  `/corp` — the alliance management page. Merges what were two separate
  pages (a hub of links and a roster) into one, because the hub only ever
  held three links and the roster is the thing anyone actually opens
  `/corp` for: a hub whose only job is to point at one real page is a
  click, not a feature.

  What lives here:

    * the roster itself (`WandererApp.Api.CorpRosterSnapshot`, maintained
      by `WandererApp.Sync.Feeds.CorpRosterFeed`), sorted
      least-recently-seen first — the "who hasn't logged on in N days"
      report — with departed members trailing;
    * the director-access consent entry point, which any member can use;
    * the admin-only director-token/sync panel, one row per
      `WandererApp.Api.OwnedCorporation`;
    * links out to the two pages that are genuinely separate: per-user
      identity (`/corp/identity`) and map access grants
      (`/corp/map-grants`, admin only).

  Gated on `WANDERER_IDENTITY_SUITE` for the route itself
  (`WandererAppWeb.Plugs.CheckIdentitySuiteDisabled`); the roster section
  additionally requires `WANDERER_CORP_ROSTER` and simply isn't rendered
  without it — the page is still useful as the suite's landing page.
  Admin surfaces use `WandererApp.Identity.PermissionCache.corp_admin?/2`
  (upstream's `current_user_role == :admin`, or the `:corp_suite_admin`
  group permission), the same check `WandererAppWeb.GroupMapGrantsLive`
  uses. See docs/chewy/corp-suite-plan.md §9 Phase 3.
  """

  use WandererAppWeb, :live_view

  alias WandererApp.Api.{Character, CorpRosterSnapshot, OwnedCorporation}
  alias WandererApp.Sync.Feeds.CorpRosterFeed

  @impl true
  def mount(_params, _session, socket) do
    is_corp_admin? =
      WandererApp.Identity.PermissionCache.corp_admin?(
        socket.assigns.current_user_role,
        socket.assigns.current_user.id
      )

    # Only worth the read when the feature is on: this is the suite's
    # landing page and it already does one permission round trip.
    can_view_scout_log? =
      WandererApp.Env.scout_intel_enabled?() and
        WandererApp.Identity.ScoutAccess.can_view?(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(
       active_tab: :corp,
       page_title: "Management",
       is_corp_admin?: is_corp_admin?,
       can_view_scout_log?: can_view_scout_log?
     )
     |> load()}
  end

  @impl true
  def handle_event("request_director_access", _params, socket) do
    # `/auth/eve` is invite-gated whenever WANDERER_INVITES is on: with no
    # `invite` param, WandererApp.Ueberauth.Strategy.Eve.check_invite_valid/1
    # returns `{not invites(), :user}` and handle_request!/1 redirects to
    # /welcome BEFORE ever reaching EVE SSO -- session or no session. A plain
    # link to /auth/eve?director=true is therefore dead on any invite-only
    # instance, which is what this deployment is. Mint the same short-lived
    # cache token upstream's own "authorize" flow mints
    # (characters_live.ex:62-76) and pass it through.
    active_pool = WandererApp.Character.TrackingConfigUtils.get_active_pool!()

    {:ok, esi_config} = Cachex.get(:esi_auth_cache, "config_#{active_pool}")

    WandererApp.Cache.put("invite_#{esi_config.uuid}", true, ttl: :timer.minutes(30))

    {:noreply,
     socket
     |> push_navigate(to: ~p"/auth/eve?invite=#{esi_config.uuid}&director=true")}
  end

  def handle_event(
        "set_director",
        %{"corporation_id" => corporation_id, "character_id" => character_id},
        %{assigns: %{is_corp_admin?: true}} = socket
      ) do
    with {:ok, corp} <- OwnedCorporation.by_id(corporation_id, authorize?: false),
         {:ok, _updated} <-
           OwnedCorporation.update(corp, %{director_character_id: nilify(character_id)},
             authorize?: false
           ) do
      {:noreply, socket |> put_flash(:info, "Director token holder updated") |> load()}
    else
      _error ->
        {:noreply, socket |> put_flash(:error, "Could not update director token holder")}
    end
  end

  def handle_event("set_director", _params, socket) do
    {:noreply, socket |> put_flash(:error, "Not authorized")}
  end

  def handle_event(
        "toggle_enabled",
        %{"corporation_id" => corporation_id},
        %{assigns: %{is_corp_admin?: true}} = socket
      ) do
    with {:ok, corp} <- OwnedCorporation.by_id(corporation_id, authorize?: false),
         {:ok, _updated} <-
           OwnedCorporation.update(corp, %{enabled: not corp.enabled}, authorize?: false) do
      {:noreply, socket |> load()}
    else
      _error ->
        {:noreply, socket |> put_flash(:error, "Could not toggle roster sync")}
    end
  end

  def handle_event("toggle_enabled", _params, socket) do
    {:noreply, socket |> put_flash(:error, "Not authorized")}
  end

  defp nilify(""), do: nil
  defp nilify(value), do: value

  defp load(socket) do
    if socket.assigns.corp_flags[:corp_roster_enabled?] do
      {:ok, corps} = OwnedCorporation.read(authorize?: false)
      {:ok, characters} = Character.read(authorize?: false)
      {:ok, roster} = CorpRosterSnapshot.read(authorize?: false)

      now = DateTime.utc_now()

      roster_rows =
        roster
        |> Enum.map(fn row -> Map.put(row, :days_since_logon, days_since(row.logon_at, now)) end)
        |> Enum.sort_by(fn row ->
          # Active members first, then longest-since-last-logon first
          # (never-logged-on-record rows treated as maximally stale) --
          # the "who hasn't logged on in N days" report a corp actually
          # uses. Departed members trail at the bottom either way.
          {row.status == :departed, -(row.days_since_logon || 999_999)}
        end)

      active_count = Enum.count(roster_rows, &(&1.status == :active))

      socket
      |> assign(
        corps: Enum.sort_by(corps, & &1.name),
        characters_by_corp: Enum.group_by(characters, & &1.corporation_id),
        roster_rows: roster_rows,
        token_status_by_corp: Map.new(corps, &{&1.id, token_status(&1)}),
        # get_corp_membertracking/2 fetches page 1 only (100 rows/page,
        # see its own comment) -- flag when this roster is close enough
        # to that boundary that members may already be silently missing.
        near_page_limit?: active_count >= 90
      )
    else
      socket
      |> assign(
        corps: [],
        characters_by_corp: %{},
        roster_rows: [],
        token_status_by_corp: %{},
        near_page_limit?: false
      )
    end
  end

  # The only caller of WandererApp.Sync.Feed's token_holder/1 callback --
  # WandererApp.Sync.Scheduler never calls it (a feed's own fetch/2 is
  # responsible for resolving its own token internally); this admin
  # panel is where "which token will the next poll use, and does it
  # still resolve" actually needs answering for a human. Also catches a
  # dangling director_character_id (FK set, but the Character row it
  # points at is gone) that a bare `corp.director_character_id != nil`
  # check in the template would miss.
  defp token_status(corp) do
    case CorpRosterFeed.token_holder(corp) do
      {:character, character} -> {:ok, character.name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp days_since(nil, _now), do: nil
  defp days_since(dt, now), do: DateTime.diff(now, dt, :day)
end
