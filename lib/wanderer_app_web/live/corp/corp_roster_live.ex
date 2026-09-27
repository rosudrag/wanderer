defmodule WandererAppWeb.CorpRosterLive do
  @moduledoc """
  Renders `WandererApp.Api.CorpRosterSnapshot` -- the live current-state
  roster `WandererApp.Sync.Feeds.CorpRosterFeed` maintains -- sorted by
  least-recently-seen first (the "who hasn't logged on in N days" report
  a corp actually uses), distinguishing active from departed members.
  Viewable by any authenticated user (gated on `WANDERER_CORP_ROSTER`
  the same way as every other `/corp/*` page); assigning which character
  holds an owned corp's director token uses `WandererApp.Identity.
  PermissionCache.corp_admin?/2` (the existing upstream
  `current_user_role == :admin` concept, or the `:corp_suite_admin`
  group permission), the same shared check as
  `WandererAppWeb.GroupMapGrantsLive` and `WandererAppWeb.CorpShellLive`'s
  "Map access grants" link. See docs/chewy/corp-suite-plan.md §9 Phase 3.
  """

  use WandererAppWeb, :live_view

  alias WandererApp.Api.{Character, CorpRosterSnapshot, OwnedCorporation}
  alias WandererApp.Sync.Feeds.CorpRosterFeed

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.corp_flags[:corp_roster_enabled?] do
      is_corp_admin? =
        WandererApp.Identity.PermissionCache.corp_admin?(
          socket.assigns.current_user_role,
          socket.assigns.current_user.id
        )

      {:ok,
       socket
       |> assign(active_tab: :corp, page_title: "Corp Roster", is_corp_admin?: is_corp_admin?)
       |> load()}
    else
      {:ok, socket |> push_navigate(to: ~p"/corp")}
    end
  end

  @impl true
  def handle_event(
        "set_director",
        %{"corporation_id" => corporation_id, "character_id" => character_id},
        %{assigns: %{is_corp_admin?: true}} = socket
      ) do
    with {:ok, corp} <- OwnedCorporation.by_id(corporation_id, authorize?: false),
         {:ok, _updated} <-
           OwnedCorporation.update(corp, %{director_character_id: character_id},
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

  defp load(socket) do
    {:ok, corps} = OwnedCorporation.read(authorize?: false)
    {:ok, characters} = Character.read(authorize?: false)

    characters_by_corp =
      Enum.group_by(characters, & &1.corporation_id)

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
      characters_by_corp: characters_by_corp,
      roster_rows: roster_rows,
      token_status_by_corp: Map.new(corps, &{&1.id, token_status(&1)}),
      # get_corp_membertracking/2 fetches page 1 only (100 rows/page,
      # see its own comment) -- flag when this roster is close enough
      # to that boundary that members may already be silently missing.
      near_page_limit?: active_count >= 90
    )
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
