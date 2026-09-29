defmodule Instance.Time.ClockBroadcastTest do
  @moduledoc """
  Clients extrapolate every live agent ETA (and the map's moving agents)
  from `global_time.now_monotonic`: the server's action clock — the frame
  each action's `started_at` lives in — plus the wall time since the
  payload arrived.

  The client stores each `global_time` it receives wholesale, and the Time
  agent re-sends it on every pause and resume — every autosave (about every
  15 wall-clock minutes), admin pause, and deploy. Those broadcasts used to
  carry `now_monotonic: nil`, so after the first autosave every agent ETA
  fell back to the owner's frozen `remaining_time` snapshot (usually the
  whole action's duration) until the page was reloaded.
  """
  use ExUnit.Case, async: true

  alias Instance.Time.Agent, as: TimeAgent
  alias Instance.Time.Time

  defp running_state do
    channel = "instance:global:clock-test-#{System.unique_integer([:positive])}"
    Portal.Endpoint.subscribe(channel)

    %Core.GenState{
      type: :time,
      instance_id: -1,
      speed: :slow,
      agent_id: :master,
      data: %Time{Time.new(0, 1, :slow, -1) | is_running: true},
      channel: channel,
      tick: %Core.Tick{time: Time.now(0), factor: 1, cumulated_pauses: 0, running?: true},
      kill: false
    }
  end

  defp broadcast_time do
    assert_receive %Phoenix.Socket.Broadcast{event: "broadcast", payload: %{global_time: %Time{} = time}}
    time
  end

  test "pause and resume broadcasts carry the clock, continuous across the pause" do
    state = running_state()

    {:reply, :ok, stopped} = TimeAgent.on_call(:stop, nil, state)
    paused = broadcast_time()
    refute paused.is_running
    assert is_integer(paused.now_monotonic)

    Process.sleep(200)

    {:reply, :ok, _started} = TimeAgent.on_call({:start, Time.compute_cumulated_pauses(stopped.data)}, nil, stopped)
    resumed = broadcast_time()
    assert resumed.is_running
    assert is_integer(resumed.now_monotonic)

    # the 200 ms pause went into cumulated_pauses: the action clock resumes
    # where it stopped instead of jumping ahead by the pause
    assert resumed.now_monotonic - paused.now_monotonic in 0..50
  end

  test ":get_state carries the same clock" do
    {:reply, {:ok, time}, _} = TimeAgent.on_call(:get_state, nil, running_state())
    assert_in_delta time.now_monotonic, Time.now(time.cumulated_pauses), 50
  end
end
