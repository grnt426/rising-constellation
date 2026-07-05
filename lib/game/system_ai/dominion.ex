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
    # The galaxy master is a single hot callee hit by EVERY AI system's
    # tick — one transient failure (restart, timeout under load) must skip
    # this AI step, not crash the stellar-system agent. Hard-matching here
    # caused agent-death epidemics: each dead system fed :callee_crashed to
    # its callers, whose own hard matches killed them in turn.
    case Game.call(state.instance_id, :galaxy, :master, :get_behavior_tree) do
      {:ok, bt} ->
        context = %{bt: BT.start(bt), system_value: system_value}
        step({context, state})

      _error ->
        {:error, :behavior_tree_unavailable}
    end
  end

  def step({context, state} = action_context) do
    bt = context.bt

    action_mfa = BT.value(bt)
    {action_module, action_fun_atom, args} = action_mfa

    # context and state added in args
    result = apply(action_module, action_fun_atom, [action_context | args])

    case result do
      :succeed ->
        bt = BT.succeed(bt)
        step({%{context | bt: bt}, state})

      :fail ->
        bt = BT.fail(bt)
        step({%{context | bt: bt}, state})

      # value is for context
      {:succeed, value} ->
        bt = BT.succeed(bt)
        context = Map.merge(context, value)
        step({%{context | bt: bt}, state})

      # when done we update the state
      {:done, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
