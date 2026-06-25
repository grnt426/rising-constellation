defmodule Instance.ActionOrchestrator.Agent do
  use Core.TickServer

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character

  require Logger
  require TimeLog

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def on_cast({hook_type, %Character{} = character, %Action{} = action}, state) do
    character = %{character | actions: ActionQueue.unlock(character.actions)}

    result =
      TimeLog.execute "orchestrator: #{inspect(action)} executed #{inspect(hook_type)}" do
        try do
          Instance.Character.Agent.orchestrated(hook_type, action, character)
        rescue
          exception ->
            Appsignal.Instrumentation.set_error(exception, __STACKTRACE__)

            # Include character id + system so a recurring failure is
            # diagnosable without guessing. A :finish failing here with the
            # character's system already nil is the Layer-1 signature: a jump
            # arrival (Jump.finish's hard `{:ok, _} = push_character` match)
            # failed because the target system was unready, leaving the
            # character stranded in transit.
            Logger.error(
              "orchestrator exec #{inspect(hook_type)} for char #{character.id} (system=#{inspect(character.system)}) " <>
                "action=#{inspect(action.type)} target=#{inspect(action.data["target"])} raised #{inspect(exception)} " <>
                "#{inspect(__STACKTRACE__)}"
            )

            {:ok, recover_from_hook_failure(hook_type, character, action)}
        catch
          # `catch` matches throws and exits; `try/rescue` alone catches
          # neither. A downstream Game.call timing out (exit) or an ActionImpl
          # raising an unhandled throw used to crash the orchestrator with the
          # queue still locked, wedging the character. Treat both like a
          # rescued failure so the queue is recovered (see
          # recover_from_hook_failure/3).
          kind, payload ->
            Logger.error(
              "orchestrator exec #{inspect(hook_type)} for char #{character.id} (system=#{inspect(character.system)}) " <>
                "action=#{inspect(action.type)} target=#{inspect(action.data["target"])} #{inspect(kind)} #{inspect(payload)}"
            )

            {:ok, recover_from_hook_failure(hook_type, character, action)}
        end
      end

    case result do
      {:ok, %Character{} = character} ->
        try do
          Game.call(character.instance_id, :character, character.id, {:done, hook_type, character})
        rescue
          exception ->
            Appsignal.Instrumentation.set_error(exception, __STACKTRACE__)
            Logger.error("orchestrator cannot reach the character (he is probably dead)")
        catch
          # A {:done} timeout shows up as an exit, not an exception. Survive it
          # so one unreachable character can't crash the orchestrator and drop
          # the rest of its mailbox. (If {:done} is genuinely lost the character
          # keeps the orchestrate lock; that abandoned-lock case is handled by
          # the stale-lock self-heal in ActionQueue/Character, not here.)
          kind, payload ->
            Logger.error(
              "orchestrator :done call to character #{character.id} #{inspect(kind)} #{inspect(payload)}"
            )
        end

      {:ok, something} ->
        Logger.warning("orchestrator did not get a character #{inspect(something)}")

      something_else ->
        Logger.warning("orchestrator did not succeed #{inspect(something_else)}")
    end

    {:noreply, state}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  defp do_next_tick(state, _elapsed_time) do
    {state, Instance.ActionOrchestrator.ActionOrchestrator}
  end

  # When a hook raises/throws/exits, recover the character rather than leaving
  # the queue wedged or — worse — re-queuing the failed action.
  #
  # :start — ABORT the action (drop it, idle the character). The original
  # a7cd535 behavior re-queued it (replace_front), which turned a start that
  # can NEVER succeed into an infinite retry loop: e.g. Infiltrate.start does
  # `{:ok, system} = Game.call(:stellar_system, character.system, :get_state)`,
  # and for a `system: nil` agent that returns `:process_not_found` → MatchError
  # every time. Each retry sleeps 200ms inside Game.get_pid, so a handful of
  # such agents pegged the single orchestrator master (~5 casts/sec) and
  # starved every other agent's round-trip — the 2026-06-16 instance-wide
  # instability. Dropping the action is the safe terminal outcome; the player
  # re-issues. (Verified RCA: 25/25 orchestrator stack samples sat in
  # Infiltrate.start → get_pid → Process.sleep.)
  #
  # :finish — no-op. process_next_action already popped the action before the
  # cast (action_queue.ex's :to_finish branch), and a partially-applied finish
  # (notifs sent, dominion claimed) must not be re-run. Unlocking (top of
  # on_cast) plus delivering {:done} is the recovery.
  defp recover_from_hook_failure(:start, %Character{} = character, _action) do
    character
    |> Character.abort_action()
    |> Character.idle()
  end

  defp recover_from_hook_failure(_hook_type, %Character{} = character, _action), do: character
end
