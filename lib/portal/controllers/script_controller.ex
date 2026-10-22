defmodule Portal.ScriptController do
  @moduledoc """
  Scenario scripts saved to an account (`RC.Scripts`).

      GET    /edict/scripts                 the caller's scripts (with sources)
      GET    /edict/scripts/published       published scripts (?search=), no sources
      GET    /edict/scripts/:id             one script: the caller's, or a published one
      POST   /edict/scripts                 %{program | source, layout}
      PUT    /edict/scripts/:id             the same, for one of the caller's scripts
      DELETE /edict/scripts/:id
      PUT    /edict/scripts/:id/publish     publish (it must check clean)
      DELETE /edict/scripts/:id/publish     unpublish

  Refusals answer `%{message: code}`: `script_limit` (422, with `limit`),
  `script_has_errors` (422), `script_duplicate` (409, with the published
  `script` it copies), `script_invalid` (422, with `detail`).
  """
  use Portal, :controller

  alias RC.Scripts
  alias RC.Scripts.Script

  action_fallback(Portal.FallbackController)

  def index(conn, _params) do
    scripts = Scripts.list_mine(account_id(conn))
    json(conn, %{scripts: Enum.map(scripts, &full(&1, conn)), limit: Scripts.max_per_account()})
  end

  def published(conn, params) do
    scripts = Scripts.list_published(search: params["search"])
    json(conn, %{scripts: Enum.map(scripts, &summary(&1, conn))})
  end

  def show(conn, %{"id" => id}) do
    case Scripts.get_visible(id, account_id(conn)) do
      %Script{} = script -> json(conn, %{script: full(script, conn)})
      nil -> {:error, :not_found}
    end
  end

  def create(conn, params) do
    conn |> reply(Scripts.create(account_id(conn), params), 201)
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, script} <- own(conn, id) do
      reply(conn, Scripts.update(script, params))
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, script} <- own(conn, id),
         {:ok, _} <- Scripts.delete(script) do
      send_resp(conn, 204, "")
    end
  end

  def publish(conn, %{"id" => id}) do
    with {:ok, script} <- own(conn, id) do
      reply(conn, Scripts.publish(script))
    end
  end

  def unpublish(conn, %{"id" => id}) do
    with {:ok, script} <- own(conn, id) do
      reply(conn, Scripts.unpublish(script))
    end
  end

  defp own(conn, id) do
    case Scripts.get(id) do
      %Script{author_id: author} = script ->
        if author == account_id(conn), do: {:ok, script}, else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp reply(conn, result, status \\ 200)

  defp reply(conn, {:ok, script}, status), do: conn |> put_status(status) |> json(%{script: full(script, conn)})

  defp reply(conn, {:error, :limit}, _status),
    do: refuse(conn, 422, %{message: "script_limit", limit: Scripts.max_per_account()})

  defp reply(conn, {:error, :has_errors}, _status), do: refuse(conn, 422, %{message: "script_has_errors"})

  defp reply(conn, {:error, {:duplicate, other}}, _status),
    do: refuse(conn, 409, %{message: "script_duplicate", script: summary(other, conn)})

  defp reply(conn, {:error, {:invalid, detail}}, _status),
    do: refuse(conn, 422, %{message: "script_invalid", detail: detail})

  defp reply(_conn, {:error, _} = error, _status), do: error

  defp refuse(conn, status, body), do: conn |> put_status(status) |> json(body)

  defp summary(%Script{} = s, conn) do
    %{
      id: s.id,
      name: s.name,
      description: s.description,
      digest: s.digest,
      error_count: s.error_count,
      published_at: s.published_at,
      updated_at: s.updated_at,
      author: author(s.author),
      mine: s.author_id == account_id(conn)
    }
  end

  defp full(%Script{} = s, conn) do
    Map.merge(summary(s, conn), %{source: s.source, program: s.program, layout: s.layout})
  end

  defp author(%RC.Accounts.Account{id: id, name: name}), do: %{id: id, name: name}
  defp author(_), do: nil

  defp account_id(conn), do: Guardian.Plug.current_resource(conn).id
end
