defmodule WandererAppWeb.BlogController do
  use WandererAppWeb, :controller

  alias WandererApp.Blog
  # CHEWY PATCH: private ChewyTech branding — SSO-only landing, no public news.
  alias WandererApp.Branding
  require Logger

  def index(conn, _params) do
    invite_token = conn.query_params["invite"]

    invite_token_valid =
      case WandererApp.Env.invites() do
        true ->
          case invite_token do
            nil -> false
            token -> WandererApp.Cache.lookup!("invite_#{token}", false)
          end

        _ ->
          true
      end

    # CHEWY PATCH: private instances never fetch/display the public posts
    # grid; the landing page is SSO login only.
    if Branding.private?() do
      render(conn, "private_index.html",
        invite_token: invite_token || "",
        invite_token_valid: invite_token_valid
      )
    else
      posts = Blog.all_posts()

      render(conn, "index.html",
        posts: posts,
        invite_token: invite_token || "",
        invite_token_valid: invite_token_valid
      )
    end
  end

  # CHEWY PATCH: no public news board on a private instance.
  def list(conn, params) do
    if Branding.private?() do
      render_not_found(conn)
    else
      tags = Blog.all_tags()

      {posts, selected_tag} =
        params
        |> case do
          %{"tag" => tag} -> {Blog.get_by_tag(tag), tag}
          _ -> {Blog.all_posts(), nil}
        end

      render(conn, "list.html",
        posts: posts,
        tags: tags,
        selected_tag: selected_tag
      )
    end
  end

  # CHEWY PATCH: no public news board on a private instance.
  def show(conn, %{"slug" => slug}) do
    if Branding.private?() do
      render_not_found(conn)
    else
      post = Blog.get_by_id!(slug)

      if post do
        render(conn, "show.html", post: post)
      else
        conn
        |> put_status(:not_found)
      end
    end
  end

  # CHEWY PATCH: no public contact page on a private instance.
  def contacts(conn, _params) do
    if Branding.private?() do
      render_not_found(conn)
    else
      render(conn, "contacts.html")
    end
  end

  def changelog(conn, _params) do
    [file] = WandererApp.Changelog.all_files()
    render(conn, "changelog.html", file: file)
  end

  def license(conn, _params) do
    render(conn, "license.html")
  end

  # CHEWY PATCH: renders the standard error view as a real 404 page instead
  # of an empty conn, for routes killed on a private instance.
  defp render_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: WandererAppWeb.ErrorHTML)
    |> render(:"404")
  end
end
