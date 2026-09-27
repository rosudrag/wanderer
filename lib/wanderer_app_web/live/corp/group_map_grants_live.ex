defmodule WandererAppWeb.GroupMapGrantsLive do
  @moduledoc """
  Admin page: create/list/destroy `WandererApp.Api.GroupMapAccessGrant`
  rows, the headline feature of docs/chewy/corp-suite-plan.md §2.5 —
  `WandererApp.Identity.MapAclSync` does the actual `AccessListMember`
  materialization, triggered by this page's writes, not by any code here.
  Gated two ways: `WANDERER_GROUP_MAP_SYNC` (redirect to `/corp` if off,
  checked in `mount/3` since a LiveView route can't return a plain HTTP
  404 the way `WandererAppWeb.Plugs.CheckIdentitySuiteDisabled` does for
  `/corp/*` as a whole) and `current_user_role == :admin` (the existing
  upstream admin concept, reused rather than inventing a parallel one).
  See docs/chewy/corp-suite-plan.md §9 Phase 1.
  """

  use WandererAppWeb, :live_view

  alias WandererApp.Api.{AccessList, Group, GroupMapAccessGrant}

  @roles [:admin, :manager, :member, :viewer, :blocked]

  @impl true
  def mount(_params, _session, socket) do
    cond do
      not socket.assigns.corp_flags[:group_map_sync_enabled?] ->
        {:ok, socket |> push_navigate(to: ~p"/corp")}

      socket.assigns.current_user_role != :admin and not WandererApp.Identity.PermissionCache.has_permission?(socket.assigns.current_user.id, :corp_suite_admin) ->
        {:ok, socket |> push_navigate(to: ~p"/corp")}

      true ->
        {:ok, socket |> assign(active_tab: :corp, page_title: "Map Access Grants") |> load()}
    end
  end

  @impl true
  def handle_event(
        "create_grant",
        %{"group_id" => group_id, "access_list_id" => access_list_id, "role" => role},
        socket
      )
      when group_id != "" and access_list_id != "" do
    case GroupMapAccessGrant.create(
           %{
             group_id: group_id,
             access_list_id: access_list_id,
             role: String.to_existing_atom(role)
           },
           authorize?: false
         ) do
      {:ok, _grant} ->
        {:noreply, socket |> put_flash(:info, "Grant created") |> load()}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Could not create grant: #{inspect(error)}")}
    end
  end

  def handle_event("create_grant", _params, socket) do
    {:noreply, socket |> put_flash(:error, "Pick both a group and a map access list")}
  end

  def handle_event("destroy_grant", %{"grant_id" => grant_id}, socket) do
    case GroupMapAccessGrant.by_id(grant_id, authorize?: false) do
      {:ok, grant} ->
        {:ok, _} = GroupMapAccessGrant.destroy(grant, authorize?: false)
        {:noreply, socket |> put_flash(:info, "Grant removed") |> load()}

      _not_found ->
        {:noreply, socket |> put_flash(:error, "Grant not found")}
    end
  end

  defp load(socket) do
    {:ok, groups} = Group.read(authorize?: false)
    {:ok, access_lists} = AccessList.read(authorize?: false)
    {:ok, grants} = GroupMapAccessGrant.read(authorize?: false)

    groups_by_id = Map.new(groups, &{&1.id, &1})
    access_lists_by_id = Map.new(access_lists, &{&1.id, &1})

    grant_rows =
      grants
      |> Enum.map(fn grant ->
        %{
          grant: grant,
          group: Map.get(groups_by_id, grant.group_id),
          access_list: Map.get(access_lists_by_id, grant.access_list_id)
        }
      end)
      |> Enum.sort_by(fn %{group: group, access_list: al} ->
        {(group && group.name) || "", (al && al.name) || ""}
      end)

    socket
    |> assign(
      groups: Enum.sort_by(groups, & &1.name),
      access_lists: Enum.sort_by(access_lists, & &1.name),
      roles: @roles,
      grant_rows: grant_rows
    )
  end
end
