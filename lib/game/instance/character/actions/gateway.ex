defmodule Instance.Character.Actions.Gateway do
  @moduledoc """
  Shared plumbing for the portal-transit action chain
  (docs/faction-buildings.md): `gateway_charge` (6h, locked but fully
  targetable in-system) → `gateway_jump` (2h, out of every system,
  untargetable) → `gateway_fatigue` (2h, present and targetable, no new
  actions start; fleets may still change stance).

  The faction government holds the transit lock for the gateway pair;
  every path that interrupts a traveler must release it. The engine
  only frees a `:charging` lock (a jump lands no matter what, and a
  wind-down runs out its own clock even if the arrived traveler dies),
  so over-calling `release_if_interrupted/1` is always safe — mirror of
  `MakeDominion.unmark_if_interrupted/1`, same call-site discipline.
  """

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character

  @transit_actions [:gateway_charge, :gateway_jump, :gateway_fatigue]

  def transit_actions(), do: @transit_actions

  @doc "Engine-injected phase chaining: push the next phase to the queue FRONT, keeping any orders queued for after arrival."
  def inject(%Character{} = character, type, data, time) do
    %{character | actions: ActionQueue.inject_front(character.actions, Action.new({type, data, time}))}
  end

  @doc """
  Interruption hook: if the character's running action is part of a
  gateway transit, tell its faction to free the lock. Call from every
  abort path (kill, assassination/seduction, orders cleared, flee).
  """
  def release_if_interrupted(%Character{} = character) do
    with %{queue: queue} <- character.actions,
         %Action{type: type, started_at: started_at} when not is_nil(started_at) <- Queue.peek(queue),
         true <- type in @transit_actions do
      Game.cast(character.instance_id, :faction, character.owner.faction_id, {:gateway_release, character.id})
    else
      _ -> :ok
    end
  end

  @doc """
  True when the running head is a started portal jump. Clearing it
  would strand the traveler at `system: nil` forever — the jump must
  land before any queue surgery.
  """
  def jump_in_progress?(%Character{} = character) do
    case character.actions && Queue.peek(character.actions.queue) do
      %Action{type: :gateway_jump, started_at: started_at} -> started_at != nil
      _ -> false
    end
  end

  @doc """
  Abort a RUNNING charge in place (government-driven link teardown, or
  an assassinated admiral whose fleet survives under a default agent).
  No-op for anything else, including the `:locked` orchestrator
  sentinel — a missed abort is backstopped by the charge-finish
  `{:gateway_begin_jump}` permission check.
  """
  def abort_charge(%Character{} = character) do
    case character.actions && Queue.peek(character.actions.queue) do
      %Action{type: :gateway_charge, started_at: started_at} when started_at != nil ->
        {:aborted, character |> Character.abort_action() |> Character.idle()}

      _ ->
        {:noop, character}
    end
  end
end
