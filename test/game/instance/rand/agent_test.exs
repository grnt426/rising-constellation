defmodule Instance.Rand.AgentTest do
  use ExUnit.Case, async: true

  alias Instance.Rand.Agent

  defp state(rand_state), do: %{data: %{rand_state: rand_state}}

  # A snapshot written under an older OTP restores :rand funs that no longer
  # run. Funs that raise stand in for them: the agent must never call them.
  defp stale(rand_state) do
    {handler, alg_state} = rand_state
    broken = fn _ -> raise BadFunctionError, term: :stale end
    broken2 = fn _, _ -> raise BadFunctionError, term: :stale end

    handler =
      Map.new(handler, fn
        {k, f} when is_function(f, 1) -> {k, broken}
        {k, f} when is_function(f, 2) -> {k, broken2}
        other -> other
      end)

    {handler, alg_state}
  end

  test "draws from a restored state with stale funs, continuing the same sequence" do
    seed = :rand.seed_s(:exrop, {1, 2, 3})

    draws = fn st ->
      Enum.map_reduce([{:uniform, 6}, {:uniform}, {:random, [:a, :b, :c]}, {:take_random, [1, 2, 3, 4], 2}, {:uniform, 1, 3}], st, fn call, st ->
        {:reply, result, st} = Agent.on_call(call, nil, st)
        {result, st}
      end)
    end

    {fresh, _} = draws.(state(seed))
    {restored, after_restore} = draws.(state(stale(seed)))

    assert restored == fresh
    assert {_, _} = :rand.uniform_s(after_restore.data.rand_state)
  end
end
