defmodule RcBot.Telemetry do
  @moduledoc """
  Best-effort lifecycle reporter. Bots POST to `/api/bot-events` so the
  admin dashboard can see what's happening on the client side — login
  attempts, channel joins, burst boundaries, disconnect reasons.

  All sends are fire-and-forget. A failed report logs at debug and
  returns — it must never break the bot's main flow.
  """

  require Logger

  @doc """
  Report a lifecycle event. `opts` may include `:status` (default "ok"),
  `:reason`, `:instance_id`, `:profile_id`, `:channel` (default
  "lifecycle"). Returns `:ok` regardless of outcome.

  No-op if JWT is nil — useful for pre-auth events where we don't yet
  have a token (login failures, etc.). Define the nil clause first so
  the more-specific pattern wins.
  """
  def report(jwt, event_name, opts \\ [])

  def report(nil, _event_name, _opts), do: :ok

  def report(jwt, event_name, opts) when is_binary(jwt) and is_binary(event_name) do
    body = %{
      event_name: event_name,
      status: Keyword.get(opts, :status, "ok"),
      reason: opts[:reason] && to_string(opts[:reason]),
      instance_id: opts[:instance_id],
      profile_id: opts[:profile_id],
      channel: Keyword.get(opts, :channel, "lifecycle")
    }

    url = base_http() <> "/api/bot-events"

    Task.start(fn ->
      try do
        Req.post(url,
          json: body,
          auth: {:bearer, jwt},
          retry: false,
          receive_timeout: 2_000
        )
      rescue
        e -> Logger.debug("telemetry report failed: #{Exception.message(e)}")
      catch
        kind, value -> Logger.debug("telemetry report #{kind}: #{inspect(value)}")
      end
    end)

    :ok
  end

  defp base_http, do: Application.fetch_env!(:rc_bot, :target_http)
end
