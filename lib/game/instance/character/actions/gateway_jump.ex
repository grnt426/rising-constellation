defmodule Instance.Character.Actions.GatewayJump do
  @moduledoc """
  Phase 2 of the portal transit: 2h in the wormhole. The traveler left
  its system at charge-finish (`system: nil`, removed from
  `system.characters`), which is what makes it untargetable — every
  hostile action validates `target.system` — and it cannot be recalled
  or have its queue cleared (see the guard in
  `Instance.Character.Agent.{:clear_actions}`).

  Engine-injected only — a client can never queue this directly.
  """

  alias Instance.Character.Action
  alias Instance.Character.Character
  alias Instance.Character.Actions.Gateway

  def pre_validate(_character, _action), do: throw(:not_queueable)

  def start(%Character{} = character, %Action{} = _action) do
    # physical departure happened at charge finish; nothing to do
    {MapSet.new(), [], character}
  end

  def finish(%Character{instance_id: instance_id} = character, %Action{} = action) do
    target = action.data["target"]

    {:ok, position} = Game.call(instance_id, :stellar_system, target, :get_position)
    {:ok, _system} = Game.call(instance_id, :stellar_system, target, {:push_character, character, :on_board})

    character = Character.enter_system(character, target, position)

    # The gateway pair stays locked for the wind-down window regardless
    # of what the arrival runs into below — the transit happened. A link
    # torn down mid-jump (endpoint captured) simply has no record left;
    # the traveler still lands, so ignore the result.
    _ = Game.call(instance_id, :faction, character.owner.faction_id, {:gateway_begin_wind_down, character.id})

    # Arrival interception: exactly the usual system-entry mechanics —
    # the SAME decision function a normal jump finish uses (admirals
    # only; the defender-stance filter keys off the arriver's stance).
    # A picket camping the exit gateway catches the arrival.
    {character, interception_notifs, leaving_or_dead?} =
      Instance.Character.Actions.Jump.arrival_interception(character, action)

    # A traveler that died (or fled) in the arrival battle takes no
    # fatigue — there is nobody left standing at the gateway to tire.
    character =
      if leaving_or_dead? do
        character
      else
        c = Data.Querier.one(Data.Game.Constant, instance_id, :main)

        character
        |> Gateway.inject(:gateway_fatigue, action.data, c.gateway_fatigue_time)
        |> Character.start_action(:gateway_fatigue)
      end

    {MapSet.new([:player_update]), interception_notifs, character}
  end
end
