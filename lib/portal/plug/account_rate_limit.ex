defmodule Portal.Plug.AccountRateLimit do
  @moduledoc """
  Per-account rate limit plug for authenticated endpoints. Same shape as
  `Portal.Plug.RateLimit` but keyed on the authenticated account id
  instead of the client IP — the threat model here is a single account
  hammering a CPU- or storage-heavy endpoint, which an IP key would let
  a botnet trivially route around (and which NAT would over-punish).

  Must run after the Guardian pipeline (`:authenticated_api`) so the
  resource is present. Admins are exempt: bulk imports and official-map
  tooling legitimately exceed player-shaped limits.

  Usage:

      plug Portal.Plug.AccountRateLimit,
        [bucket: "map_create", limit: 10, window_ms: 3_600_000]
        when action == :create
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    actor = conn.private.guardian_default_resource

    if actor.role == :admin do
      conn
    else
      bucket = Keyword.fetch!(opts, :bucket)
      limit = Keyword.fetch!(opts, :limit)
      window_ms = Keyword.fetch!(opts, :window_ms)
      key = "#{bucket}:#{actor.id}"

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
  end
end
