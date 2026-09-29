defmodule Instance.Time.Agent do
  use Core.TickServer

  alias Instance.Time.Time
  alias Portal.Controllers.GlobalChannel

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, Time.with_clock(state.data)}, state}
  end

  # Pause/resume (every autosave, admin pause, deploy) re-sends the global
  # time, which the client stores wholesale — so it must carry the clock
  # too. Without it `now_monotonic` went null on every connected client and
  # every live agent ETA fell back to the owner's frozen snapshot of
  # `remaining_time` until the next refresh.
  def on_call({:start, cumulated_pauses}, _from, state) do
    data = Time.start(state.data)
    GlobalChannel.broadcast_change(state.channel, %{global_time: Time.with_clock(data)})

    {:reply, :ok, %{state | tick: Core.Tick.start(%{state.tick | cumulated_pauses: cumulated_pauses}), data: data}}
  end

  def on_call(:stop, _from, state) do
    data = Time.stop(state.data)
    GlobalChannel.broadcast_change(state.channel, %{global_time: Time.with_clock(data)})

    {:reply, :ok, %{state | tick: Core.Tick.stop(state.tick), data: data}}
  end

  def on_call(:get_cumulated_pauses, _from, state) do
    {:reply, state.cumulated_pauses, state}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  defp do_next_tick(state, elapsed_time) do
    {_change, data} = Time.next_tick(state.data, elapsed_time)
    {%{state | data: data}, Time}
  end
end
