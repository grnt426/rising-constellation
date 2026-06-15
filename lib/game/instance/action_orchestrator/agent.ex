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

            Logger.error(
              "orchestrator exec #{inspect(hook_type)} #{inspect(action)} raised #{inspect(exception)} #{inspect(__STACKTRACE__)}"
            )

            {:ok, rollback_on_failure(hook_type, character, action)}
        catch
          # `catch` matches throws and exits. `try/rescue` alone does not —
          # the orchestrator used to crash with the queue still locked when
          # a downstream `Game.call` timed out (exit) or an ActionImpl raised
          # an unhandled throw. Without :done firing the character agent
          # stays at `[:locked, half-stamped action]` indefinitely (Kika &
          # Fugiko 2026-06-15). Treat both like a rescued failure: log and
          # roll back so the next tick can retry cleanly.
          kind, payload ->
            Logger.error(
              "orchestrator exec #{inspect(hook_type)} #{inspect(action)} #{inspect(kind)} #{inspect(payload)}"
            )

            {:ok, rollback_on_failure(hook_type, character, action)}
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
          # Game.call timeout to the character agent shows up as an exit,
          # not an exception. Same deal — survive it; the next tick will
          # find the rolled-back action and re-run :start.
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

  # Restore the queue head to the original (unstamped) action so the next
  # tick re-enters process_next_action's `is_nil(started_at)` branch and
  # re-attempts the :start hook. Without this, the half-stamped action wedges
  # process_next_action's catch-all error forever (the Challor 2026-06-14
  # incident: Infiltration.start raised on a nil system, action stayed in
  # the queue with started_at set but remaining_time = :unknown_yet, and the
  # character was permanently un-tickable).
  #
  # :finish hooks don't get a rollback here because process_next_action
  # pops the action before the cast (see action_queue.ex's :to_finish
  # branch). Re-inserting at the front would re-run finish on a state that
  # finish has already mutated (e.g. Jump.finish's leave_system happened on
  # :start and is irreversible). A correct retry needs a per-ActionImpl
  # rollback contract; out of scope.
  defp rollback_on_failure(:start, %Character{} = character, %Action{} = action) do
    %{character | actions: ActionQueue.replace_front(character.actions, action)}
  end

  defp rollback_on_failure(_hook_type, %Character{} = character, _action), do: character
end
