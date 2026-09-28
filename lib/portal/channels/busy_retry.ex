defmodule Portal.Channels.BusyRetry do
  @moduledoc """
  Retries a player order while the target agent answers `{:error,
  :agent_busy}`.

  A character's action queue is locked while the action orchestrator runs
  the head action's start/finish hook (usually a few milliseconds; a fight
  on arrival or a backed-up orchestrator can take longer). Edits are
  refused during that window rather than applied and then overwritten, and
  the channel — never the player agent, which the hook itself may need to
  call — waits it out here.

  After `timeout_ms` the busy error is returned to the client, which tells
  the player nothing was changed.
  """

  @default_timeout_ms 3_000
  @initial_sleep_ms 25
  @max_sleep_ms 250

  def run(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout
    attempt(fun, deadline, @initial_sleep_ms)
  end

  defp attempt(fun, deadline, sleep_ms) do
    case fun.() do
      {:error, :agent_busy} = busy ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          busy
        else
          Process.sleep(min(sleep_ms, remaining))
          attempt(fun, deadline, min(sleep_ms * 2, @max_sleep_ms))
        end

      other ->
        other
    end
  end
end
