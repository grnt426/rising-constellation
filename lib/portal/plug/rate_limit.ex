defmodule Portal.Plug.RateLimit do
  @moduledoc """
  Per-IP rate limit plug. Used at controller level to throttle sensitive
  endpoints (login, password-reset trigger).

  Usage:

      plug Portal.Plug.RateLimit,
        [bucket: "auth_login", limit: 10, window_ms: 900_000]
        when action in [:identity_callback]

  Honours `x-forwarded-for` when present so the limit keys off the real
  client IP behind our TLS-terminating proxy.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    limit = Keyword.fetch!(opts, :limit)
    window_ms = Keyword.fetch!(opts, :window_ms)
    key = "#{bucket}:#{client_ip(conn)}"

    case Hammer.check_rate(key, window_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", Integer.to_string(div(window_ms, 1000)))
        |> Phoenix.Controller.json(%{message: :rate_limited})
        |> halt()
    end
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
