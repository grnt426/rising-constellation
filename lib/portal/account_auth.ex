defmodule Portal.AccountAuth do
  @moduledoc """
  `on_mount` hook for LiveViews that any logged-in player may open (the
  `/reports/*` pages). The router's `Portal.Plug.RequireAccount` only runs
  on the first HTTP GET; this re-resolves the account from the session on
  every mount and socket reconnect, the same way `Portal.AdminAuth` does
  for the admin pages.

  `RC.Guardian.resource_from_session/1` admits active and unverified
  (`:registered`) accounts with a current token version and returns nil
  for everything else, so a logged-out, banned or deleted account is sent
  to `/login`.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias RC.Accounts.Account

  def on_mount(:ensure_account, _params, session, socket) do
    case account_from_session(session) do
      %Account{} = account -> {:cont, assign(socket, :current_user, account)}
      _ -> {:halt, redirect(socket, to: "/login")}
    end
  end

  defp account_from_session(%{"guardian_default_token" => token} = session) when is_binary(token),
    do: RC.Guardian.resource_from_session(session)

  defp account_from_session(_session), do: nil
end
