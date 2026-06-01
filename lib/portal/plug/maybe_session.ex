defmodule Portal.Plug.MaybeSession do
  @moduledoc """
  Drop-in replacement for `plug Plug.Session, @session_options` that flips
  the `secure` cookie flag based on runtime `:rc, :force_ssl` config
  (driven by the RC_FORCE_SSL env var).

  Why: a release built once should be deployable both behind a TLS-
  terminating ALB (cookies should be secure) and for an HTTP-only test
  host (cookies must NOT be secure or the browser will refuse to store
  them). Plug.Session takes its options at compile time of the endpoint
  via the `plug/2` macro, so we initialize both variants up front and
  pick which one to run per request.

  Static options come from the endpoint module's `session_options/0`
  callback (or any module that exports it). Pass the module name as the
  plug option:

      plug Portal.Plug.MaybeSession, opts: @session_options
  """
  @behaviour Plug

  @impl true
  def init(opts) do
    base = Keyword.fetch!(opts, :opts)
    %{
      secure: Plug.Session.init(Keyword.put(base, :secure, true)),
      insecure: Plug.Session.init(Keyword.put(base, :secure, false))
    }
  end

  @impl true
  def call(conn, %{secure: secure_opts, insecure: insecure_opts}) do
    opts =
      if Application.get_env(:rc, :force_ssl, true),
        do: secure_opts,
        else: insecure_opts

    Plug.Session.call(conn, opts)
  end
end
