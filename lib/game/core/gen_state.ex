defmodule Core.GenState do
  use TypedStruct

  typedstruct enforce: true do
    field(:type, atom())
    field(:instance_id, integer())
    field(:speed, atom())
    field(:agent_id, integer())
    field(:data, any())
    field(:channel, String.t(), enforce: false)
    field(:tick, %Core.Tick{})
    field(:kill, boolean())
  end

  def new(type, instance_id, agent_id, state, channel) do
    metadata = Data.Querier.get_metadata(instance_id)
    speed = Data.Querier.one(Data.Game.Speed, instance_id, metadata[:speed])

    # Fold in the runtime speed-cheat multiplier (1 when unset) so agents
    # created after a speed change (new players, hired characters) tick at
    # the same rate as the rest of the instance.
    cheat_speedup =
      case metadata[:cheat_speedup] do
        multiplier when is_number(multiplier) and multiplier > 0 -> multiplier
        _ -> 1
      end

    %Core.GenState{
      type: type,
      instance_id: instance_id,
      speed: metadata[:speed],
      agent_id: agent_id,
      data: state,
      channel: channel,
      tick: Core.Tick.new(speed.factor * cheat_speedup),
      kill: false
    }
  end

  def registry_name(state) do
    {state.instance_id, state.type, state.agent_id}
  end
end
