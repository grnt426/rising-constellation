defmodule Portal.Plug.DeletionLock do
  @moduledoc """
  Hard lockout for deletion-pending accounts (see `RC.Accounts.Deletion`).

  Sits in the `:authenticated_api` pipeline. While `deletion_requested_at`
  is set, every authenticated API call 403s with `deletion_pending` except
  the exact three routes the SPA's lockout page needs: read own account,
  read deletion status, cancel deletion. Logout lives outside
  `:authenticated_api` and stays reachable. The game socket refuses
  deletion-pending connects separately (`Portal.Socket.connect/2`).
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    account = conn.private[:guardian_default_resource]

    if account && account.deletion_requested_at && not allowed?(conn) do
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{
        error: "deletion_pending",
        days_left: RC.Accounts.Deletion.days_until_purge(account)
      })
      |> halt()
    else
      conn
    end
  end

  defp allowed?(%Plug.Conn{method: "GET", path_info: ["api", "account"]}), do: true
  defp allowed?(%Plug.Conn{method: "GET", path_info: ["api", "account", "deletion"]}), do: true
  defp allowed?(%Plug.Conn{method: "POST", path_info: ["api", "account", "deletion", "cancel"]}), do: true
  defp allowed?(_conn), do: false
end
