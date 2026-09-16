defmodule Instance.ResourceMarket.Agent do
  @moduledoc """
  Per-instance host of the galactic tech/ideology value index
  (`Instance.ResourceMarket.ResourceMarket`). Player agents report their gross
  incomes by cast on their stats cadence; the agent never calls a player, so
  it can't deadlock against one. Clients read it through the player channel
  (`get_resource_market`).
  """
  use Core.TickServer

  alias Instance.ResourceMarket.ResourceMarket

  @decorate tick()
  def on_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  @decorate tick()
  def on_call(:get_public, _from, state) do
    {:reply, {:ok, ResourceMarket.public(state.data)}, state}
  end

  @decorate tick()
  def on_cast({:report_income, player_id, faction_id, incomes}, state) do
    {:noreply, %{state | data: ResourceMarket.report_income(state.data, player_id, faction_id, incomes)}}
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  defp do_next_tick(state, elapsed) do
    {%{state | data: ResourceMarket.next_tick(state.data, elapsed)}, ResourceMarket}
  end
end
