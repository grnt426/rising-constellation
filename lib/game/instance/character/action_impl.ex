defmodule Instance.Character.ActionImpl do
  @moduledoc """
  Implementations of all `Instance.Character` action
  """
  require Logger

  alias Instance.Character.Character
  alias Instance.Character.Actions

  @actions %{
    jump: Actions.Jump,
    colonization: Actions.Colonization,
    fight: Actions.Fight,
    conquest: Actions.Conquest,
    raid: Actions.Raid,
    loot: Actions.Loot,
    infiltrate: Actions.Infiltrate,
    sabotage: Actions.Sabotage,
    assassination: Actions.Assassination,
    make_dominion: Actions.MakeDominion,
    encourage_hate: Actions.EncourageHate,
    conversion: Actions.Conversion,
    gateway_charge: Actions.GatewayCharge,
    gateway_jump: Actions.GatewayJump,
    gateway_fatigue: Actions.GatewayFatigue
  }

  # Client payloads name their action with a string. Looking it up here,
  # instead of String.to_existing_atom/1, keeps an unknown or missing
  # type from raising.
  @actions_by_type Map.new(@actions, fn {type, module} -> {Atom.to_string(type), module} end)

  @doc """
  Pre-validates one client action (`%{"type" => _, "data" => %{}}`)
  against `character`, right before it joins the
  `Instance.Character.Agent`'s `Instance.Character.ActionQueue`.

  Returns `{:ok, queue}`, the character's queue with the action
  appended, or `{:error, reason}` with the atom the action's
  `pre_validate/2` threw (`:invalid_jump`, `:invalid_position`, …),
  which the client shows as a toast.

  Never raises. The payload is untrusted client data, and a raise here
  would crash the character agent, which then restarts from the last
  snapshot. A malformed payload gets `{:error, :bad_data}`.
  """
  def validate_action(%Character{} = character, action) do
    try do
      {:ok, action_module(action).pre_validate(character, action)}
    rescue
      exception ->
        Logger.error(
          "pre_validate raised on #{inspect(action)}: " <> Exception.format(:error, exception, __STACKTRACE__)
        )

        {:error, :bad_data}
    catch
      reason when is_atom(reason) ->
        {:error, reason}

      reason ->
        Logger.error("pre_validate threw a non-atom reason: #{inspect(reason)}")
        {:error, :bad_data}
    end
  end

  defp action_module(%{"type" => type, "data" => data}) when is_map(data) do
    case Map.fetch(@actions_by_type, type) do
      {:ok, module} -> module
      :error -> throw(:action_not_found)
    end
  end

  defp action_module(_action), do: throw(:bad_data)

  @doc """
  Called by `Instance.Character.Agent.orchestrated/3`, validates and starts an action.
  """
  def on_start(%Character{} = character, action) do
    trace_action(character, action, "action_started")

    try do
      case Map.fetch(@actions, action.type) do
        {:ok, module} -> module.start(character, action)
        :error -> throw({:action_not_found, []})
      end
    catch
      {reason, notifs} ->
        trace_action(character, action, "action_aborted", %{reason: inspect(reason)})
        character = Character.abort_action(character)
        {MapSet.new([:player_update]), notifs, character}

      err ->
        Logger.error(inspect(err))
    end
  end

  @doc """
  Called by `Instance.Character.Agent.orchestrated/3`, finishes an action
  """
  def on_finish(%Character{} = character, action) do
    trace_action(character, action, "action_finished")

    case Map.fetch(@actions, action.type) do
      {:ok, module} ->
        module.finish(character, action)

      :error ->
        Logger.error(Atom.to_string(:action_not_found))
        {MapSet.new([:player_update]), [], character}
    end
  end

  # Action-trace hook. No-op unless RC.DebugFlags.action_trace?/0 is on,
  # so the hot path pays only a flag read when tracing is off. Writes go
  # to instance_event_log (DB), never the operator log — see
  # RC.Instances.InstanceEventLog.
  defp trace_action(%Character{} = character, action, kind, extra \\ %{}) do
    if RC.DebugFlags.action_trace?() do
      payload = Map.merge(%{type: action.type, target: action.data["target"]}, extra)

      RC.Instances.InstanceEventLog.emit(character.instance_id, kind, %{
        character_id: character.id,
        system_id: character.system,
        payload: payload
      })
    end

    :ok
  end
end
