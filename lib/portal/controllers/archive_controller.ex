defmodule Portal.ArchiveController do
  @moduledoc """
  Legacy match archive.

      GET /archive/matches           published matches, newest first (paginated)
      GET /archive/matches/:id       one match with all series
      PUT /archive/matches/:id/publish   admin: %{published: bool}

  Admins also see unpublished imports in both reads.
  """
  use Portal, :controller

  alias RC.Archive

  action_fallback(Portal.FallbackController)

  def index(conn, params) do
    matches = Archive.list_matches(params, admin?(conn))

    conn
    |> Scrivener.Headers.paginate(matches)
    |> render("index.json", matches: matches)
  end

  def show(conn, %{"id" => id}) do
    case Archive.get_match(id, admin?(conn)) do
      nil -> {:error, :not_found}
      match -> render(conn, "show.json", match: match)
    end
  end

  def publish(conn, %{"id" => id} = params) do
    published = params["published"] in [true, "true"]

    with {:ok, match} <- Archive.set_published(id, published) do
      json(conn, %{id: match.id, published: match.published})
    end
  end

  defp admin?(conn), do: conn.private.guardian_default_resource.role == :admin
end
