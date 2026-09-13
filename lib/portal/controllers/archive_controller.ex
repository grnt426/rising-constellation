defmodule Portal.ArchiveController do
  @moduledoc """
  Legacy match archive.

      GET /archive/matches           published matches, newest first (paginated)
      GET /archive/matches/:id       one match with all series
      GET /archive/matches/:id/export    .xlsx download (1/min, 10/hour per account)
      PUT /archive/matches/:id/publish   admin: %{published: bool}

  Admins also see unpublished imports in the reads and are exempt from the
  export limit.
  """
  use Portal, :controller

  alias RC.Archive
  alias RC.Archive.{Export, ExportLimiter}

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

  # The match is looked up before the limiter so a bad id or an unpublished
  # match doesn't use up the player's export allowance.
  def export(conn, %{"id" => id}) do
    actor = conn.private.guardian_default_resource
    admin? = actor.role == :admin

    with match when not is_nil(match) <- Archive.get_match(id, admin?),
         :ok <- if(admin?, do: :ok, else: ExportLimiter.check(actor.id)) do
      conn
      |> put_resp_header("content-type", Export.content_type())
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{Export.filename(match)}"))
      |> send_resp(200, Export.to_xlsx(match))
    else
      nil ->
        {:error, :not_found}

      {:error, retry_after} ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> json(%{message: :rate_limited, retry_after: retry_after, limits: ExportLimiter.limits()})
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
