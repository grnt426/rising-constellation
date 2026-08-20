defmodule Instance.Character.Actions.GatewayCharge do
  @moduledoc """
  Phase 1 of the portal transit: 6h locked into "charging gateway" at
  the source system. The agent stays in `system.characters` with a
  non-idle `action_status`, so it is excluded from interception pools
  but remains a valid target for fight / sabotage / assassination /
  seduction — exactly the spec's vulnerability window.

  The transit lock (both gateways, either side) is taken at START via
  the faction agent — never in `pre_validate`, which runs inside the
  character agent process (a faction call there would deadlock against
  the government's faction→character orphan sweep).
  """

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character
  alias Instance.Character.Actions.Gateway
  alias Instance.Character.Spy

  def pre_validate(character, %{"data" => data}) do
    unless Map.has_key?(data, "source") and Map.has_key?(data, "target"),
      do: throw(:bad_data)

    if character.type == :spy and Spy.discovered?(character.spy.cover.value, character.instance_id),
      do: throw(:unable_to_move)

    if character.action_status == :docking, do: throw(:unable_to_move)
    if data["source"] == data["target"], do: throw(:same_position)
    if character.actions.virtual_position != data["source"], do: throw(:invalid_position)

    c = Data.Querier.one(Data.Game.Constant, character.instance_id, :main)
    ActionQueue.add(character.actions, {:gateway_charge, data, c.gateway_charge_time}, data["target"])
  end

  def start(%Character{instance_id: instance_id} = character, %Action{} = action) do
    if character.system != action.data["source"], do: throw({:invalid_position, []})

    case Game.call(
           instance_id,
           :faction,
           character.owner.faction_id,
           {:gateway_reserve, action.data["source"], character.id}
         ) do
      {:ok, target} ->
        if target == action.data["target"] do
          {MapSet.new([:player_update]), [], Character.start_action(character, :gateway_charging)}
        else
          # the pair was re-linked to a different system between queue
          # time and now — give the lock back and stand down
          Game.cast(instance_id, :faction, character.owner.faction_id, {:gateway_release, character.id})
          {MapSet.new([:player_update]), [], stand_down(character)}
        end

      {:error, _reason} ->
        # busy / unlinked / unpowered — stand down in place. Not a throw:
        # the generic abort keeps queue virtual_position at the charge's
        # target, which silently poisons every later order from here
        # (the flee-path comment in character.ex describes the trap).
        {MapSet.new([:player_update]), [], stand_down(character)}
    end
  end

  # Clear the queue — everything behind the charge was premised on
  # arriving at the target — and repin the itinerary to where the agent
  # actually stands, so fresh orders validate again.
  defp stand_down(%Character{} = character) do
    character
    |> Character.clear_actions()
    |> Character.set_virtual_position(character.system)
    |> Character.idle()
  end

  def finish(%Character{instance_id: instance_id} = character, %Action{} = action) do
    # permission gate doubles as the capture-race backstop: if the link
    # (and our reservation) died while we charged, stand down in place
    case Game.call(instance_id, :faction, character.owner.faction_id, {:gateway_begin_jump, character.id}) do
      :ok ->
        {:ok, _system} =
          Game.call(instance_id, :stellar_system, action.data["source"], {:remove_character, character, :on_board})

        c = Data.Querier.one(Data.Game.Constant, instance_id, :main)

        character =
          character
          |> Character.leave_system()
          # :gateway_jumping, not :moving — no radar blip (Spatial only
          # tracks :moving), no interception, get_position falls back to
          # the last known (source) position
          |> Map.put(:action_status, :gateway_jumping)
          |> Gateway.inject(:gateway_jump, action.data, c.gateway_jump_time)

        {MapSet.new([:player_update]), [], character}

      {:error, _reason} ->
        # reservation gone (capture race) — stand down where we are;
        # queued follow-ups were premised on arriving and go with it
        character =
          character
          |> Character.finish_action()
          |> Character.clear_actions()
          |> Character.set_virtual_position(character.system)

        {MapSet.new([:player_update]), [], character}
    end
  end
end
