defmodule Portal.Plug.RequireAccount do
  @moduledoc """
  Gate for public-layout pages that only logged-in players may read
  (the `/reports/*` pages). Runs after `Portal.Plug.AuthAccessPipeline`,
  which has already loaded the account from the session (and rejected
  banned, deleted or revoked ones).

  An anonymous visit is sent to `/login` with the requested path kept in
  the session as `:return_to`; `Portal.LoginController` sends the player
  back there after a successful login. The LiveView socket is re-checked
  by `Portal.AccountAuth`, since this plug only sees the first HTTP GET.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias RC.Accounts.Account

  def init(opts), do: opts

  def call(conn, _opts) do
    case RC.Guardian.Plug.current_resource(conn) do
      %Account{} ->
        conn

      _ ->
        conn
        |> put_session(:return_to, conn.request_path)
        |> put_flash(:info, "Log in to read this page.")
        |> redirect(to: "/login")
        |> halt()
    end
  end
end
