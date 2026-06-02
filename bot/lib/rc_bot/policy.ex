defmodule RcBot.Policy do
  @moduledoc """
  Behaviour for bot decision logic. Sessions delegate per-burst action
  selection to a policy module so we can swap strategies (random, dumb,
  imitation-trained) without touching the harness.

  ## The action tuple

  `decide_actions/1` returns a list of `{event_name, payload, channel}`
  tuples. Sessions push each one verbatim on the named channel
  (`:player` or `:cheat`). Order is preserved.

      [
        {"hire_character", %{"character" => %{"id" => 26}}, :player},
        {"order_building", %{...}, :player}
      ]

  ## The player view

  The input to `decide_actions/1` is the most recent `player_player`
  broadcast (the same map the server pushes after every state change).
  Keys are strings — it has already round-tripped through JSON.

  A nil view means we haven't received any state yet; policies should
  return `[]` in that case so the session sits tight until a broadcast
  arrives.
  """

  @type player_view :: map() | nil
  @type channel :: :player | :cheat
  @type action :: {event_name :: String.t(), payload :: map(), channel}

  @callback decide_actions(player_view) :: [action]
end
