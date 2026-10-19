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
  alias Instance.Character.Actions.Jump

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

    # The transit happened, so the pair is free for the next traveler
    # whatever the arrival runs into below. A link torn down mid-jump
    # (endpoint captured) simply has no record left; the traveler still
    # lands, so ignore the result.
    _ = Game.call(instance_id, :faction, character.owner.faction_id, {:gateway_arrived, character.id})

    # An armada lands together: its attached members materialize at the
    # exit gateway before the interception pass, as on a jump arrival, so
    # the whole armada fights the one arrival battle.
    companions = Jump.materialize_armada_members(character, target, position)

    # Arrival interception: exactly the usual system-entry mechanics —
    # the SAME decision function a normal jump finish uses (admirals
    # only; the defender-stance filter keys off the arriving armada's
    # most aggressive stance). A picket camping the exit gateway catches
    # the arrival.
    {character, interception_notifs, leaving_or_dead?} =
      Jump.arrival_interception(character, action, companions)

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
