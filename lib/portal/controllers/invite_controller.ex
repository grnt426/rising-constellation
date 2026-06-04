defmodule Portal.InviteController do
  @moduledoc """
  Generates 24-hour invite links the caller can share.

  Authenticated; rate-limited per-account (not per-IP -- the threat is a
  compromised account being used as a link firehose, which a botnet would
  trivially work around if we keyed on IP). Refuses to mint when
  `accounts.can_create_account_invites` is false.

  The endpoint deliberately returns a fresh token on every call. Each
  token is reusable by an unbounded number of new signups within its
  window, so there's no "one link per friend" UX trap.
  """
  use Portal, :controller

  alias RC.Accounts.InviteToken

  # Two windows. The hour cap covers bursts (compromised account script);
  # the day cap covers slow drips. Sized loosely for human use -- a player
  # legitimately blasting 100 invites a day is fine; 101 will wait.
  @hour_limit 10
  @hour_window_ms 3_600_000
  @day_limit 100
  @day_window_ms 86_400_000

  def create(conn, _params) do
    actor = conn.private.guardian_default_resource

    cond do
      not actor.can_create_account_invites ->
        conn
        |> put_status(:forbidden)
        |> json(%{message: :invite_generation_disabled})

      not rate_ok?(actor.id) ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", "3600")
        |> json(%{message: :rate_limited})

      true ->
        token = InviteToken.encode(Portal.Endpoint, actor.id)
        url = Routes.live_url(Portal.Endpoint, Portal.LandingLive) <> "?invite=" <> token

        conn
        |> put_status(:created)
        |> json(%{token: token, url: url, expires_in: 86_400})
    end
  end

  defp rate_ok?(account_id) do
    hour_key = "invite_create_hour:#{account_id}"
    day_key = "invite_create_day:#{account_id}"

    with {:allow, _} <- Hammer.check_rate(hour_key, @hour_window_ms, @hour_limit),
         {:allow, _} <- Hammer.check_rate(day_key, @day_window_ms, @day_limit) do
      true
    else
      {:deny, _} -> false
    end
  end
end
