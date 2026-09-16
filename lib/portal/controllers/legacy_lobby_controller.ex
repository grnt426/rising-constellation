defmodule Portal.LegacyLobbyController do
  @moduledoc """
  Official-match extras for the Legacy lobby (RC.LegacyLobby).

      GET /legacy/lobby            latest official result + next official start
      PUT /legacy/next-official    admin: %{date, starts_at} (blank date clears)
  """
  use Portal, :controller

  alias RC.LegacyLobby

  def show(conn, _params) do
    admin? = conn.private.guardian_default_resource.role == :admin

    json(conn, %{
      latest_result: LegacyLobby.latest_official_result(admin?),
      official_active: LegacyLobby.official_active?(),
      next_official: LegacyLobby.next_official()
    })
  end

  def update_next_official(conn, params) do
    case LegacyLobby.put_next_official(params) do
      {:ok, value} -> json(conn, %{next_official: value})
      {:error, reason} -> conn |> put_status(422) |> json(%{message: reason})
    end
  end
end
