defmodule SystemAI.ConstructionChargingTest do
  @moduledoc """
  The Rebellion pays for what its systems' tree orders (`Wave.Construction`,
  `Wave.Budget`), and nobody else's system AI changes.

  Rebel systems are real generated systems (`StellarSystem.new/4`) claimed by
  the Rebellion and ticked through `StellarSystem.next_tick/2`, so the charge
  is exercised where the engine applies it (the system AI step); only the
  `:rand` agent is a seeded stand-in.
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.{ProductionQueue, StellarBody, StellarSystem, Tile}
  alias SystemAI.Helper

  defmodule SeededRand do
    @moduledoc false
    use GenServer

    def init(seed) do
      :rand.seed(:exsss, {seed, seed, seed})
      {:ok, nil}
    end

    def handle_call({:uniform}, _from, s), do: {:reply, :rand.uniform(), s}
    def handle_call({:uniform, n}, _from, s), do: {:reply, :rand.uniform(n), s}
    def handle_call({:uniform, min, max}, _from, s), do: {:reply, :rand.uniform() * (max - min) + min, s}
    def handle_call({:random, enum}, _from, s), do: {:reply, Enum.random(enum), s}
    def handle_call({:take_random, list, n}, _from, s), do: {:reply, Enum.take_random(list, n), s}
  end

  defmodule BTGalaxy do
    @moduledoc false
    use GenServer

    def init(bt), do: {:ok, bt}
    def handle_call(:get_behavior_tree, _from, bt), do: {:reply, {:ok, bt}, bt}
  end

  @rebellion %{id: 1, name: "The Rebellion", avatar: "bot", faction: :rebellion, faction_id: 9}
  @human %{id: 2, name: "p2", avatar: "a", faction: :myrmezir, faction_id: 1}

  setup do
    iid = System.unique_integer([:positive])
    Test.FleetScenario.load_game_data(iid, speed: :slow, mode: :prod)
    Data.Data.update_metadata(iid, :wave, true)
    Data.Data.update_metadata(iid, :wave_config, %{"bot_faction" => "rebellion"})

    {:ok, rand} = GenServer.start_link(SeededRand, 7, name: Game.via_tuple({iid, :rand, :master}))

    vanilla =
      Instance.SystemAI.Parser.parse!(Path.join(:code.priv_dir(:rc), "data/system_ai/behavior_tree.json"), "Dominion")

    {:ok, galaxy} = GenServer.start_link(BTGalaxy, vanilla, name: Game.via_tuple({iid, :galaxy, :master}))

    on_exit(fn ->
      Process.exit(rand, :shutdown)
      Process.exit(galaxy, :shutdown)
      Wave.Budget.clear(iid)
    end)

    {:ok, iid: iid}
  end

  describe "a rebel system" do
    test "pays a human's price for every order its tree places, out of the allowance", %{iid: iid} do
      Wave.Budget.put(iid, 10_000_000)
      system = rebel(iid)

      {_system, paid} =
        Enum.reduce(1..40, {system, []}, fn _, {system, paid} ->
          {change, ticked} = turn(system)
          placed = Wave.Construction.orders_credit(system, ticked)

          # what the turn emits for the owner is exactly what it ordered
          assert charges(change) == if(placed > 0, do: [placed], else: [])
          {ticked, paid ++ charges(change)}
        end)

      assert length(paid) >= 3
      assert Wave.Budget.spent(iid) == Enum.sum(paid)
      assert Wave.Budget.available(iid) == 10_000_000 - Enum.sum(paid)
    end

    test "orders nothing it cannot pay for", %{iid: iid} do
      system = rebel(iid)

      # no allowance yet (the Warlord has not passed), then an empty one
      for budget <- [nil, 0] do
        if budget, do: Wave.Budget.put(iid, budget)

        Enum.reduce(1..20, system, fn _, system ->
          {change, ticked} = turn(system)
          assert charges(change) == []
          assert Wave.Construction.orders_credit(system, ticked) == 0
          ticked
        end)
      end

      assert Wave.Budget.spent(iid) == 0
    end

    test "picks among the upgrades and buildings the allowance covers", %{iid: iid} do
      # infrastructure level 3 costs 34,320; a mine level 2 4,576; Pressurized
      # Habitats level 1 3,450
      state =
        struct_system(iid, [
          Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 2),
          Tile.new(2, :primary) |> Tile.force_building(:mine_dome, 1),
          Tile.new(3, :primary)
        ])

      legal = Helper.get_legal_upgrades(state)

      upgradable = fn state ->
        state |> Helper.affordable_upgrades(legal) |> Enum.map(& &1.building_key) |> Enum.sort()
      end

      rebel = %{state | owner: @rebellion}
      Wave.Budget.put(iid, 10_000)
      assert upgradable.(rebel) == [:mine_dome]
      assert :hab_dome in Helper.housing_options(rebel, :dome)

      Wave.Budget.put(iid, 3_000)
      assert upgradable.(rebel) == []
      assert Helper.housing_options(rebel, :dome) == []

      Wave.Budget.put(iid, 40_000)
      assert upgradable.(rebel) == [:infra_dome, :mine_dome]

      # a system the Rebellion does not hold is never held to the allowance
      Wave.Budget.put(iid, 0)
      assert upgradable.(state) == [:infra_dome, :mine_dome]
      assert upgradable.(%{state | owner: @human}) == [:infra_dome, :mine_dome]
      assert :hab_dome in Helper.housing_options(state, :dome)
    end
  end

  describe "everyone else's system AI" do
    test "a neutral system builds with the vanilla tree, for nothing", %{iid: iid} do
      assert_builds_free(neutral(iid), iid)
    end

    test "a human's dominion builds with the vanilla tree, for nothing", %{iid: iid} do
      {_, dominion} = StellarSystem.claim(neutral(iid), @human, false, true)
      assert Wave.Config.system_ai(dominion, 50) == {:dominion, 50}
      assert_builds_free(dominion, iid)
    end
  end

  describe "prices" do
    test "are a human's: the level's credit to build or upgrade, that times the repair factor to repair", %{iid: iid} do
      factor = Data.Querier.one(Data.Game.Constant, iid, :main).building_repairs_factor
      patents = Data.Querier.all(Data.Game.Patent, iid) |> Enum.map(& &1.key)

      player =
        struct(Instance.Player.Player, %{
          instance_id: iid,
          stellar_systems: [%{id: 1}],
          credit: Core.DynamicValue.new(1.0e9),
          is_bankrupt: false,
          patents: patents
        })

      paid = fn type, key, level ->
        {:ok, after_order} = Instance.Player.Player.order_building(player, 1, type, {"1", 2, key, level})
        round(player.credit.value - after_order.credit.value)
      end

      for {key, level} <- [{:mine_dome, 1}, {:mine_dome, 2}, {:spatioport_orbital, 5}, {:infra_open, 3}] do
        assert Wave.Construction.credit(iid, :building, key, level) == paid.("build", key, level)
        assert Wave.Construction.credit(iid, :building_repairs, key, level) == paid.("repair", key, level)
      end

      assert Wave.Construction.credit(iid, :building_repairs, :mine_dome, 2) == round(4_576 * factor)
      assert Wave.Construction.credit(iid, :ship, :fighter_1, 1) == 0
    end
  end

  # --- helpers ------------------------------------------------------------------

  # One AI turn: the turn is due, and enough time passes for a level-1 order
  # to be produced, so the next turn can order again.
  defp turn(system) do
    due = %{system | ai_next_action: Core.DynamicValue.change_value(system.ai_next_action, 100.0)}
    {change, _notifs, ticked} = StellarSystem.next_tick(due, 5.0)
    {change, ticked}
  end

  defp charges(change) do
    for {:construction_paid, credit} <- change, do: credit
  end

  defp assert_builds_free(system, iid) do
    Wave.Budget.clear(iid)

    placed =
      Enum.reduce(1..30, {system, 0}, fn _, {system, placed} ->
        {change, ticked} = turn(system)
        assert charges(change) == []
        {ticked, placed + Wave.Construction.orders_credit(system, ticked)}
      end)
      |> elem(1)

    assert placed > 0
    assert Wave.Budget.available(iid) == nil
  end

  defp rebel(iid) do
    {_, system} = StellarSystem.claim(neutral(iid), @rebellion, false, false)
    assert Wave.Config.system_ai(system, 50) == {:rebel_dominion, Wave.Config.ai_interval(iid)}
    system
  end

  # A generated autonomous system with room left to build.
  defp neutral(iid) do
    Enum.find_value(1..200, fn key ->
      system =
        StellarSystem.new(
          %{"key" => key, "type" => "red_dwarf", "position" => %{"x" => 0, "y" => 0}},
          1,
          iid,
          name: "sys-#{key}",
          forced_status: :inhabited_neutral
        )

      free = for body <- Helper.get_bodies(system), tile <- body.tiles, tile.building_status == :empty, do: tile

      if system.status == :inhabited_neutral and length(free) >= 6, do: system
    end) || flunk("no autonomous system with free tiles in 200 draws")
  end

  # A one-dome system, for the choice helpers.
  defp struct_system(iid, tiles) do
    dome =
      struct(StellarBody, %{
        id: 1,
        uid: "1",
        type: :sterile_planet,
        name: "Dome",
        industrial_factor: 3,
        technological_factor: 3,
        activity_factor: 3,
        population: 10,
        bodies: [],
        tiles: tiles
      })

    struct(StellarSystem, %{
      id: 4343,
      name: "charge-test",
      status: :inhabited_player,
      instance_id: iid,
      bodies: [dome],
      queue: ProductionQueue.new(),
      siege: nil,
      owner: nil,
      workforce: 20,
      used_workforce: 0,
      habitation: %Core.Value{value: 0, details: %{}},
      happiness: %Core.Value{value: 50, details: %{}},
      population: Core.DynamicValue.new(0.0),
      ai_profile: :production
    })
  end
end
