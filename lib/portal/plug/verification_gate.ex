defmodule Portal.Plug.VerificationGate do
  @moduledoc """
  Read-only mode for accounts whose email is not yet verified
  (`status: :registered` — the open-signup starting state).

  Sits in `:authenticated_api` after `DeletionLock`. Reads pass; writes
  403 with `email_unverified` except the profile-setup surface: an
  unverified player may create and edit their own character profile and
  save account settings, nothing else — no joining games, no maps, no
  votes, no messages. Row-level ownership stays enforced by the
  authorization plugs; this list only narrows the write lockout.

  Verified accounts (`:active`) pass untouched, which also grandfathers
  every pre-open-signup account. Steam accounts (when Steam auth
  returns) never enter `:registered` and will bypass this gate.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    account = conn.private[:guardian_default_resource]

    if account && account.status == :registered && write?(conn) && not allowed_write?(conn) do
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{error: "email_unverified", message: :email_unverified})
      |> halt()
    else
      conn
    end
  end

  defp write?(%Plug.Conn{method: method}), do: method not in ["GET", "HEAD", "OPTIONS"]

  defp allowed_write?(%Plug.Conn{method: "POST", path_info: ["api", "accounts", _aid, "profiles"]}), do: true

  defp allowed_write?(%Plug.Conn{method: method, path_info: ["api", "profiles", _pid]})
       when method in ["PUT", "PATCH", "DELETE"],
       do: true

  defp allowed_write?(%Plug.Conn{method: "POST", path_info: ["api", "accounts", "settings"]}), do: true

  defp allowed_write?(_conn), do: false
end
