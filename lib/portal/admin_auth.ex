defmodule Portal.AdminAuth do
  @moduledoc """
  Phoenix LiveView `on_mount` hook that re-checks admin authorisation on
  every LiveView mount, socket reconnect, and `live_patch` navigation.

  Stage 6 Cluster A fix. The router-level `:admin_authorization` plug
  only fires on the initial HTTP GET that establishes the LiveView. The
  Stage 2 #11 finding (and the 24 Stage 6 findings that build on it)
  showed that without a `live_session`/`on_mount` hook, a demoted admin's
  socket survives the role downgrade and retains every `handle_event`
  mutation primitive until the tab closes or the JWT expires.

  Wire this from `lib/portal/router.ex` by wrapping every admin LiveView
  in `live_session :admin, on_mount: {Portal.AdminAuth, :ensure_admin}`
  and by passing `on_mount: [{Portal.AdminAuth, :ensure_admin}]` to the
  Phoenix LiveDashboard call.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias RC.Accounts.Account

  @doc """
  Resolves the calling account from the session and admits the mount
  only when `role == :admin` AND `status == :active`. On any other
  outcome (no session, bad token, demoted, banned, deleted), halts and
  redirects to `/`.

  The account is assigned as `:current_user` so existing LiveView code
  (which already reads that key) needs no further changes.
  """
  def on_mount(:ensure_admin, _params, session, socket) do
    case account_from_session(session) do
      %Account{role: :admin, status: :active} = account ->
        # The LiveView WebSocket runs in a separate process from the
        # initial HTTP render, so the locale set by Portal.Plug.AdminLocale
        # does not carry over. Re-apply it here so gettext/1 calls in
        # admin .leex templates respect the user's preference.
        Gettext.put_locale(Portal.Gettext, locale_for(account))
        {:cont, assign(socket, :current_user, account)}

      _ ->
        {:halt, redirect(socket, to: "/")}
    end
  end

  defp locale_for(%Account{lang: lang}) when lang in ["en", "fr"], do: lang
  defp locale_for(_), do: "en"

  defp account_from_session(session) do
    # RC.Guardian.resource_from_session was made defensive in Stage 1 —
    # it returns `nil` on missing / bad / banned-status tokens — but we
    # add belt-and-suspenders pattern matching here so a future change
    # to that helper cannot silently re-open the bypass.
    case session do
      %{"guardian_default_token" => token} when is_binary(token) ->
        RC.Guardian.resource_from_session(session)

      _ ->
        nil
    end
  end
end
