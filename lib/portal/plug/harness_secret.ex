defmodule Portal.Plug.HarnessSecret do
  @moduledoc """
  Authenticates the bot harness via a shared secret in the
  `X-Harness-Secret` header. The harness is a system, not a user, so we
  use a static secret (set at deploy time via `RC_BOT_HARNESS_SECRET`)
  rather than JWT.

  Returns 401 with `{"error": "unauthorized"}` if:
    - The server has no secret configured (deny by default — fail
      closed, never silently accept all requests).
    - The header is missing.
    - The header value doesn't match (constant-time compared).

  Configure via `config :rc, :bot_harness_secret, ...` (typically read
  from env in `runtime.exs`).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "x-harness-secret") do
      [presented] ->
        case expected_secret() do
          nil -> deny(conn, "no_server_secret_configured")
          expected when is_binary(expected) ->
            if Plug.Crypto.secure_compare(presented, expected) do
              conn
            else
              deny(conn, "bad_secret")
            end
        end

      _ ->
        deny(conn, "missing_secret_header")
    end
  end

  defp expected_secret do
    Application.get_env(:rc, :bot_harness_secret)
  end

  defp deny(conn, _reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
