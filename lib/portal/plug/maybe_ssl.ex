defmodule Portal.Plug.MaybeSSL do
  @moduledoc """
  Conditional wrapper around `Plug.SSL`, gated by runtime config.

  `Plug.SSL` is a compile-time plug — once it's wired into the endpoint it
  always runs. That's fine for canonical prod (behind a TLS-terminating
  ALB), but for HTTP-only test/staging deploys it emits HSTS and forces
  `secure` cookies, which breaks the session over plain HTTP and locks
  the host into HSTS for a year in any browser that visits it.

  This wrapper reads `:rc, :force_ssl` at request time. Default is `true`
  (safe for prod). Set `RC_FORCE_SSL=false` in `/etc/rc/env` to disable
  for a no-TLS deploy.
  """
  @behaviour Plug

  # Plug.SSL options are baked in at compile time. The only runtime
  # decision is whether to invoke them at all.
  @ssl_opts Plug.SSL.init(
              rewrite_on: [:x_forwarded_proto],
              hsts: true,
              expires: 31_536_000,
              subdomains: true
            )

  @impl true
  def init(_opts), do: nil

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:rc, :force_ssl, true) do
      Plug.SSL.call(conn, @ssl_opts)
    else
      conn
    end
  end
end
