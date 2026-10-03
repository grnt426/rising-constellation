defmodule RC.SystemPlannerTest do
  use ExUnit.Case, async: false

  alias RC.SystemPlanner
  alias Instance.StellarSystem.{ProductionQueue, StellarSystem}
  alias Test.FleetScenario

  # Legacy. A habitable planet (infrastructure 2, a factory, one free tile)
  # with a moon; 20.5 population.
  defp plan(overrides \\ %{}) do
    Map.merge(
      %{
        "speed" => "slow",
        "faction" => "tetrarchy",
        "capital" => false,
        "population" => 20.5,
        "bodies" => [
          %{
            "type" => "habitable_planet",
            "industrial_factor" => 4,
            "technological_factor" => 2,
            "activity_factor" => 5,
            "tiles" => [
              %{"building_key" => "infra_open", "building_level" => 2},
              %{"building_key" => "factory_open", "building_level" => 1},
              %{"building_key" => nil}
            ],
            "bodies" => [
              %{
                "type" => "moon",
                "industrial_factor" => 2,
                "technological_factor" => 1,
                "activity_factor" => 1,
                "tiles" => [%{"building_key" => nil}]
              }
            ]
          }
        ],
        "governor" => nil,
        "lexes" => []
      },
      overrides
    )
  end

  defp compute!(params) do
    {:ok, %{system: system, growth: growth}} = SystemPlanner.compute(params)
    {system, growth}
  end

  defp constant, do: Data.Querier.one(Data.Game.Constant, SystemPlanner.instance_id(:slow), :main)

  defp with_tile(params, index, tile) do
    [body] = params["bodies"]
    put_in(params, ["bodies"], [%{body | "tiles" => List.replace_at(body["tiles"], index, tile)}])
  end

  describe "compute/1" do
    test "matches the live game path on a registry-backed instance" do
      {planned, _} = compute!(plan(%{"lexes" => ["prod_1"]}))

      # The same system, built the way StellarSystem tests build one and fed
      # the bonuses a live player would push, on an ordinary instance id.
      iid = System.unique_integer([:positive])
      FleetScenario.load_game_data(iid, speed: :slow, mode: :prod)

      player =
        struct(Instance.Player.Player, %{
          instance_id: iid,
          faction: :tetrarchy,
          policies: [:prod_1],
          stellar_systems: [],
          dominions: [],
          characters: [],
          government_effects: nil
        })

      live = %{planned | instance_id: iid, queue: ProductionQueue.new(), happiness: Core.Value.new(), bonuses: %{}}

      {_, _, live} =
        StellarSystem.update_bonuses(live, :player, Instance.Player.Player.extract_bonus(player, [:stellar_system]))

      for field <- [:production, :credit, :technology, :ideology, :happiness, :habitation, :defense, :mobility] do
        assert Map.get(planned, field).value == Map.get(live, field).value, "#{field} differs"
      end

      assert planned.used_workforce == live.used_workforce
    end

    test "a capital earns the capital base production" do
      {colony, _} = compute!(plan())
      {capital, _} = compute!(plan(%{"capital" => true}))

      c = constant()

      assert_in_delta capital.production.value - colony.production.value,
                      c.system_capital_base_production - c.system_base_production,
                      1.0e-9
    end

    test "workforce is the whole part of the population" do
      {system, _} = compute!(plan(%{"population" => 20.9}))

      assert system.workforce == 20
      assert system.population.value == 20.9
      # infra_open + factory_open, two workforce each
      assert system.used_workforce == 4
    end

    test "a governor's skills apply, under the governor's name" do
      governor = %{"type" => "speaker", "name" => "Vela", "skills" => [0, 0, 0, 3, 0, 0]}

      {without, _} = compute!(plan())
      {with_governor, _} = compute!(plan(%{"governor" => governor}))

      # leader: +6 stability per point
      assert_in_delta with_governor.happiness.value - without.happiness.value, 18, 1.0e-9
      assert [%Core.ValuePart{reason: "Vela", value: from_governor}] = with_governor.happiness.details[:agent]
      assert_in_delta from_governor, 18, 1.0e-9
    end

    test "active lexes apply, and a repeated lex counts once" do
      {without, _} = compute!(plan())
      {with_lex, _} = compute!(plan(%{"lexes" => ["prod_2", "prod_2"]}))

      # prod_2: +50 production, then +10 %
      assert_in_delta with_lex.production.value, (without.production.value + 50) * 1.1, 1.0e-6
    end

    test "a damaged building costs workforce but gives nothing" do
      damaged = %{"building_key" => "factory_open", "building_level" => 1, "building_status" => "damaged"}

      {built, _} = compute!(plan())
      {broken, _} = compute!(with_tile(plan(), 1, damaged))

      assert broken.production.value < built.production.value
      assert broken.used_workforce == built.used_workforce
    end

    test "the population status follows stability" do
      {calm, _} = compute!(plan())
      assert calm.happiness.value > 0
      assert calm.population_status == :normal

      # one stability lost per workforce point: 120 population sinks it
      {restless, _} = compute!(plan(%{"population" => 120}))
      assert restless.happiness.value <= -30
      assert restless.population_status == :general_uprising
    end

    test "growth is the game's population growth" do
      {system, growth} = compute!(plan())

      assert growth ==
               StellarSystem.population_growth(
                 system.habitation.value,
                 20.5,
                 system.happiness.value,
                 constant().system_base_growth
               )

      assert system.population.change == growth
    end

    test "the result encodes to JSON with the system's breakdowns" do
      {:ok, result} = SystemPlanner.compute(plan())
      decoded = result |> Jason.encode!() |> Jason.decode!()

      assert %{"system" => %{"production" => %{"value" => _, "details" => %{"building" => _}}}, "growth" => _} =
               decoded

      refute Map.has_key?(decoded["system"], "bonuses")
    end

    test "Flash and Tactic plans compute with their own data" do
      flash =
        plan(%{"speed" => "fast"})
        |> with_tile(0, %{"building_key" => "infra_open", "building_level" => 1})
        |> with_tile(1, %{"building_key" => nil})

      assert {:ok, _} = SystemPlanner.compute(flash)
      assert {:ok, _} = SystemPlanner.compute(plan(%{"speed" => "medium"}))
      assert {:ok, _} = SystemPlanner.compute(plan(%{"speed" => "daily"}))
    end
  end

  describe "compute/1 refuses impossible systems" do
    test "unknown data" do
      assert {:error, :invalid_speed} = SystemPlanner.compute(plan(%{"speed" => "warp"}))
      assert {:error, :invalid_faction} = SystemPlanner.compute(plan(%{"faction" => "nobody"}))
      assert {:error, :unknown_lex} = SystemPlanner.compute(plan(%{"lexes" => ["not_a_lex"]}))

      assert {:error, :unknown_building} =
               SystemPlanner.compute(with_tile(plan(), 2, %{"building_key" => "castle", "building_level" => 1}))
    end

    test "buildings that don't fit their tile" do
      assert {:error, :building_biome_mismatch} =
               SystemPlanner.compute(with_tile(plan(), 2, %{"building_key" => "mine_dome", "building_level" => 1}))

      assert {:error, :building_tile_mismatch} =
               SystemPlanner.compute(with_tile(plan(), 2, %{"building_key" => "infra_open", "building_level" => 1}))

      assert {:error, :building_tile_mismatch} =
               SystemPlanner.compute(with_tile(plan(), 0, %{"building_key" => "factory_open", "building_level" => 1}))

      assert {:error, :invalid_building_level} =
               SystemPlanner.compute(with_tile(plan(), 1, %{"building_key" => "factory_open", "building_level" => 6}))
    end

    test "unique buildings stay unique" do
      lift = %{"building_key" => "lift_open", "building_level" => 1}

      assert {:error, :unique_building_per_body} =
               plan() |> with_tile(1, lift) |> with_tile(2, lift) |> SystemPlanner.compute()
    end

    test "bad shapes" do
      assert {:error, :invalid_population} = SystemPlanner.compute(plan(%{"population" => -1}))
      assert {:error, :invalid_population} = SystemPlanner.compute(plan(%{"population" => "lots"}))
      assert {:error, :invalid_bodies} = SystemPlanner.compute(plan(%{"bodies" => []}))
      assert {:error, :invalid_body} = SystemPlanner.compute(plan(%{"bodies" => [%{"type" => "moon"}]}))

      assert {:error, :invalid_governor} =
               SystemPlanner.compute(plan(%{"governor" => %{"type" => "speaker", "skills" => [13, 0, 0, 0, 0, 0]}}))

      assert {:error, :invalid_governor} =
               SystemPlanner.compute(plan(%{"governor" => %{"type" => "pirate", "skills" => [0, 0, 0, 0, 0, 0]}}))

      assert {:error, :invalid_plan} = SystemPlanner.compute("plan")
    end
  end

  describe "template/1" do
    test "is the starting system, ready to compute" do
      template = SystemPlanner.template(:slow)

      assert template.capital
      assert template.population == constant().system_starting_population

      # open_system/1: the infrastructure goes on the largest habitable planet
      planet =
        template.bodies
        |> Enum.filter(&(&1.type == "habitable_planet"))
        |> Enum.max_by(&length(&1.tiles))

      assert [%{building_key: "infra_open", building_level: 1} | _] = planet.tiles

      assert template.bodies |> Enum.flat_map(& &1.tiles) |> Enum.count(& &1.building_key) == 1

      params = template |> Jason.encode!() |> Jason.decode!() |> Map.put("faction", "synelle")
      assert {:ok, %{system: system}} = SystemPlanner.compute(params)
      assert system.production.value > 0
    end
  end
end
