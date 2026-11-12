defmodule Instance.Rand.Agent do
  use Core.TickServer

  # @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  # Returns a random element of the 'enumerable'.
  def on_call({:random, enumerable}, _, state) do
    {rand_state, result} = REnum.random(live_rand(state), enumerable)
    {:reply, result, %{state | data: %{rand_state: rand_state}}}
  end

  # Takes 'count' random elements from 'enumerable'.
  def on_call({:take_random, enumerable, count}, _, state) when is_integer(count) do
    {rand_state, result} = REnum.take_random(live_rand(state), enumerable, count)
    {:reply, result, %{state | data: %{rand_state: rand_state}}}
  end

  # Returns a random float uniformly distributed in the value range `0.0 =< X < 1.0`
  def on_call({:uniform}, _, state) do
    {result, rand_state} = :rand.uniform_s(live_rand(state))
    {:reply, result, %{state | data: %{rand_state: rand_state}}}
  end

  # Returns, for a specified integer `N >= 1`, a random integer uniformly distributed in the value range `1 =< X =< N`.
  def on_call({:uniform, n}, _, state) when is_integer(n) do
    {result, rand_state} = :rand.uniform_s(n, live_rand(state))
    {:reply, result, %{state | data: %{rand_state: rand_state}}}
  end

  # Returns a random float uniformly distributed in the value range `min =< X =< max`.
  def on_call({:uniform, min, max}, _, state) do
    {result, rand_state} = :rand.uniform_s(live_rand(state))
    {:reply, result * (max - min) + min, %{state | data: %{rand_state: rand_state}}}
  end

  # A :rand state carries funs from the :rand module that built it. One
  # restored from a snapshot written under another OTP release holds stale
  # funs: every draw raised BadFunctionError after the OTP 27 -> 28 deploy
  # (2026-11-12), crashing systems, characters and markets on each roll.
  # Re-seeding from the exported state rebuilds the funs for the running
  # OTP and continues the same sequence. It reads only the algorithm name
  # and its state, never the funs, and costs less than the draw itself.
  defp live_rand(state), do: :rand.seed_s(:rand.export_seed_s(state.data.rand_state))

  # @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  defp do_next_tick(state, _elapsed_time) do
    {state, Instance.Rand.Rand}
  end
end
