defmodule Portal.Channels.BusyRetryTest do
  use ExUnit.Case, async: true

  alias Portal.Channels.BusyRetry

  defp scripted(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    fn ->
      Agent.get_and_update(agent, fn
        [reply] -> {reply, [reply]}
        [reply | rest] -> {reply, rest}
      end)
    end
  end

  test "a non-busy reply is returned at once" do
    assert :ok == BusyRetry.run(scripted([:ok]))
    assert {:error, :invalid_jump} == BusyRetry.run(scripted([{:error, :invalid_jump}]))
  end

  test "retries while busy, then returns the real reply" do
    fun = scripted([{:error, :agent_busy}, {:error, :agent_busy}, :ok])
    assert :ok == BusyRetry.run(fun)
  end

  test "a real error after a busy spell is returned as is" do
    assert {:error, :stale_queue} == BusyRetry.run(scripted([{:error, :agent_busy}, {:error, :stale_queue}]))
  end

  test "gives up with :agent_busy once the deadline passes" do
    {elapsed_us, reply} = :timer.tc(fn -> BusyRetry.run(scripted([{:error, :agent_busy}]), timeout_ms: 300) end)

    assert reply == {:error, :agent_busy}
    assert elapsed_us >= 300_000
    assert elapsed_us < 700_000
  end

  test "the default deadline is 3 seconds" do
    {elapsed_us, reply} = :timer.tc(fn -> BusyRetry.run(scripted([{:error, :agent_busy}])) end)

    assert reply == {:error, :agent_busy}
    assert_in_delta elapsed_us / 1000, 3_000, 400
  end
end
