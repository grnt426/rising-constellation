defmodule Portal.LiveCsrf do
  @moduledoc """
  CSRF token for classic HTML forms rendered inside LiveViews.

  The public login forms do a plain HTTP POST (password managers need a
  real submit-then-navigate sequence to offer saving credentials), so the
  hidden `_csrf_token` input must carry a token that is valid for the
  browser session on both render paths:

    * dead render — we are still in the request process, where Plug's own
      CSRF state is in scope, so `Plug.CSRFProtection.get_csrf_token/0` is
      correct;
    * connected render — the LiveView process has no CSRF state (a token
      minted here would fail `protect_from_forgery`), but the client sent
      the root layout's meta-tag token as the `_csrf_token` connect param,
      and any masked token for the session validates.
  """

  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1]

  @doc "Must be called during mount (connect params are only readable there)."
  def html_form_token(socket) do
    if connected?(socket) do
      get_connect_params(socket)["_csrf_token"]
    else
      Plug.CSRFProtection.get_csrf_token()
    end
  end
end
