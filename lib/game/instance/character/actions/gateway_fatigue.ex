defmodule Instance.Character.Actions.GatewayFatigue do
  @moduledoc """
  Phase 3 of the portal transit: 2h of portal fatigue at the arrival
  system. The agent is present and fully targetable, but starts no
  actions (fatigue IS the running action, so nothing behind it starts)
  and cannot be recalled (recall requires `:idle`). Fleet stance
  changes stay open — `{:update_reaction}` never gated on
  `action_status`, deliberately left that way.

  The gateway pair's wind-down runs on the government's own clock for
  the same duration — killing the fatigued traveler does NOT free the
  gateway early.

  Engine-injected only — a client can never queue this directly.
  """

  alias Instance.Character.Action
  alias Instance.Character.Character

  def pre_validate(_character, _action), do: throw(:not_queueable)

  def start(%Character{} = character, %Action{} = _action) do
    {MapSet.new([:player_update]), [], Character.start_action(character, :gateway_fatigue)}
  end

  def finish(%Character{} = character, %Action{} = _action) do
    {MapSet.new([:player_update]), [], Character.finish_action(character)}
  end
end
