defmodule Portal.Plug.MaybeCorsica do
  @moduledoc """
  Runtime-configurable Corsica wrapper.

  Plug options are evaluated at the host module's compile time, so a bare
  `plug Corsica, origins: ...` bakes the origin list into the endpoint at
  release-build time. That fights our runtime-env-var design (RC_HOST set
  at boot from /etc/rc/env). It also means there's no clean way to use
  the documented `:self` value: that's only honored inside
  `Corsica.Router` macros, not as a plain plug option — passing it raises
  `FunctionClauseError` in `Corsica.matching_origin?/3` once an actual
  Origin header arrives.

  This wrapper builds Corsica's opts per request from `:rc, :rc_domain`
  (driven by RC_DOMAIN / RC_HOST in runtime.exs), then delegates to
  `Corsica.call/2`. The init is a few microseconds — negligible compared
  to the request itself.
  """
  @behaviour Plug

  @impl true
  def init(_opts), do: nil

  @impl true
  def call(conn, _opts) do
    Corsica.call(conn, opts())
  end

  defp opts do
    Corsica.init(
      allow_credentials: true,
      allow_headers: :all,
      origins: allowed_origins()
    )
  end

  defp allowed_origins do
    case Application.get_env(:rc, :rc_domain) do
      nil ->
        # No domain configured — fall back to wide-open. Should only hit
        # in dev or a misconfigured prod; runtime.exs sets rc_domain
        # from RC_HOST in prod.
        "*"

      url when is_binary(url) ->
        # Browsers send Origin without a trailing slash; our rc_domain is
        # canonically stored with one ("https://host/"). Strip it.
        [String.trim_trailing(url, "/")]
    end
  end
end
