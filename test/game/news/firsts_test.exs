defmodule Game.News.FirstsTest do
  @moduledoc """
  A galaxy first is a player's to claim: the Wave Defense bot is left out of
  every one of them.

  The server is driven through its own message handler. The instance has no
  row in the database, so a claim that is attempted fails and says so in the
  log: that warning is how these tests tell an event that reached the claim
  from one that was stopped before it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Game.News.Server
  alias Test.FleetScenario

  setup do
    iid = System.unique_integer([:positive])

    FleetScenario.load_game_data(iid,
      speed: :slow,
      mode: :prod,
      wave: true,
      wave_config: %{"bot_faction" => "rebellion"}
    )

    {:ok, state: %Server{instance_id: iid, eligibility: :eligible}}
  end

  defp emit(state, key, payload), do: Server.handle_info({:news_emit, key, payload}, state)

  test "the bot claims no first, whatever the kind", %{state: state} do
    log =
      capture_log(fn ->
        for {key, extra} <- [
              {"building.completed",
               %{building: "monument_dome", system_name: "Buxtons", system_id: 260, sector_id: 10}},
              {"ship.fielded", %{ship: "capital_1"}},
              {"income.crossed", %{resource: "technology", player_name: "The Rebellion"}},
              {"credit.crossed", %{player_name: "The Rebellion"}},
              {"doctrine.crossed", %{player_name: "The Rebellion"}}
            ] do
          payload = Map.merge(%{faction: "rebellion", winning_faction_id: 2}, extra)

          assert {:noreply, after_state} = emit(state, key, payload)
          assert after_state.claimed == MapSet.new()
        end
      end)

    refute log =~ "first-claim"
  end

  test "a human's event still goes to the claim", %{state: state} do
    payload = %{faction: "myrmezir", winning_faction_id: 1, building: "monument_dome", system_id: 12, sector_id: 1}

    assert capture_log(fn -> emit(state, "building.completed", payload) end) =~ "first-claim failed"
  end
end
