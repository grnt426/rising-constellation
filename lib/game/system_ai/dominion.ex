defmodule SystemAI do
  alias BehaviorTree, as: BT
  alias Instance.StellarSystem.StellarSystem

  @doc """
    Evaluate the Behavior tree based on state and the initial dominions params.

    Dominion parameters:
    - `system_value`: determines how developed is the system.
    - `state.ai_profile`: determines the dominion profile.
  """
  def do_action(%StellarSystem{} = state, system_value) do
    {:ok, bt} = Game.call(state.instance_id, :galaxy, :master, :get_behavior_tree)
    run(bt, state, system_value)
  end

  @doc """
  Evaluate a named tree. `:dominion` is the vanilla tree served by the galaxy
  agent (identical to `do_action/2`); any other key comes from
  `SystemAI.Trees` — e.g. `:rebel_dominion` for Wave Defense rebel systems.
  """
  def do_action(%StellarSystem{} = state, system_value, :dominion), do: do_action(state, system_value)

  def do_action(%StellarSystem{} = state, system_value, tree_key) do
    run(SystemAI.Trees.get(tree_key), state, system_value)
  end

  defp run(bt, state, system_value) do
    context = %{bt: BT.start(bt), system_value: system_value}
    step({context, state})
  end

  # A behavior tree whose root exhausts every child restarts from the leftmost
  # leaf forever (the library restarts at the root and `step/1` recurses
  # unconditionally). Every shipped tree guards against that with terminal
  # `{:done, state}` actions, but a mistake in a new tree would silently hang
  # the stellar system agent. Cap the number of node evaluations so a runaway
  # becomes a logged error instead.
  @max_steps 1_000

  def step(action_context), do: step(action_context, @max_steps)

  defp step({_context, state}, 0) do
    require Logger
    Logger.error("[system_ai] behavior tree exceeded #{@max_steps} steps on system #{inspect(state.id)} — aborting")
    {:error, :bt_runaway}
  end

  defp step({context, state} = action_context, budget) do
    bt = context.bt

    action_mfa = BT.value(bt)
    {action_module, action_fun_atom, args} = action_mfa

    # context and state added in args
    result = apply(action_module, action_fun_atom, [action_context | args])

    case result do
      :succeed ->
        bt = BT.succeed(bt)
        step({%{context | bt: bt}, state}, budget - 1)

      :fail ->
        bt = BT.fail(bt)
        step({%{context | bt: bt}, state}, budget - 1)

      # value is for context
      {:succeed, value} ->
        bt = BT.succeed(bt)
        context = Map.merge(context, value)
        step({%{context | bt: bt}, state}, budget - 1)

      # when done we update the state
      {:done, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
