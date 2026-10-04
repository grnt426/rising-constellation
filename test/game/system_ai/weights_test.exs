defmodule SystemAI.WeightsTest do
  use ExUnit.Case, async: true

  alias SystemAI.Weights

  # The real Legacy catalog: the multipliers are only worth anything against
  # the buildings a system actually chooses between.
  @buildings Map.new(Data.Game.Building.Content.Slow.data(), &{&1.key, &1})

  defp building(key), do: Map.fetch!(@buildings, key)

  defp body(industry, science, appeal, population \\ 0),
    do: %{industrial_factor: industry, technological_factor: science, activity_factor: appeal, population: population}

  defp system(opts \\ []) do
    %{
      population: %{value: Keyword.get(opts, :population, 0.0)},
      mobility: %{value: Keyword.get(opts, :mobility, 0.0)}
    }
  end

  describe "potentials" do
    test "half a share of lots per point" do
      assert Enum.map(1..5, &Weights.potential/1) == [0.5, 1.0, 1.5, 2.0, 2.5]
      assert Weights.potential(0) == 0.0
      # a potential the viewer cannot see counts as average
      assert Weights.potential(:hidden) == 1.0
    end

    test "on an asteroid with science 5 and appeal 1, the Experiment Station holds five times the Zero-G Arena's lots" do
      asteroid = body(5, 5, 1)

      assert Weights.building(building(:research_orbital), asteroid, system()) == 2.5
      assert Weights.building(building(:happy_pot_orbital), asteroid, system()) == 0.5
      assert Weights.building(building(:mine_orbital), asteroid, system()) == 2.5
    end

    test "a building reading two potentials gets the mean of the two" do
      # Metamaterials Factory: industry for production, science for technology
      assert Weights.building(building(:high_factory_dome), body(5, 1, 3), system()) == 1.5
    end
  end

  describe "population and mobility" do
    test "the curve is flat at the floor, 1 where the building starts to pay, and levels off under the ceiling" do
      assert Weights.saturating(0, 15.0) == 0.2
      assert Weights.saturating(10, 15.0) == 0.2
      assert_in_delta Weights.saturating(15, 15.0), 1.0, 1.0e-9
      assert_in_delta Weights.saturating(20, 15.0), 1.31, 0.01
      assert Weights.saturating(40, 15.0) < 1.5
      assert Weights.saturating(40, 15.0) > 1.49

      for x <- 0..60, do: assert(Weights.saturating(x, 15.0) <= Weights.saturating(x + 1, 15.0))
    end

    test "a planet pays from 15 population" do
      market = building(:market_open)

      assert Weights.building(market, body(3, 3, 3, 8), system()) == 0.2
      assert_in_delta Weights.building(market, body(3, 3, 3, 15), system()), 1.0, 1.0e-9
      assert Weights.building(market, body(3, 3, 3, 25), system()) > 1.3
    end

    test "a Business Arch is nearly worthless until the system's mobility reaches 40" do
      arch = building(:finance_orbital)

      # its happiness cost is a penalty and plays no part
      assert Weights.building(arch, body(5, 5, 5), system(mobility: 12.0)) == 0.2
      assert_in_delta Weights.building(arch, body(1, 1, 1), system(mobility: 40.0)), 1.0, 1.0e-9
      assert Weights.building(arch, body(1, 1, 1), system(mobility: 60.0)) > 1.3
    end

    test "a building with a flat part and a scaling part gets the mean of the two" do
      # Citadel: flat ideology, plus ideology per inhabitant
      assert_in_delta Weights.building(building(:ideo_open), body(3, 3, 3, 8), system()), (1.0 + 0.2) / 2, 1.0e-9
    end
  end

  describe "flat buildings" do
    test "are known by having nothing that scales" do
      assert Weights.flat?(building(:shipyard_1_orbital))
      assert Weights.flat?(building(:radar_orbital))
      assert Weights.flat?(building(:spatioport_orbital))
      assert Weights.flat?(building(:military_school_dome))
      refute Weights.flat?(building(:finance_orbital))
      refute Weights.flat?(building(:research_orbital))
      refute Weights.flat?(building(:ideo_open))

      assert Weights.scaled(building(:shipyard_1_orbital), body(5, 5, 5), system()) == nil
      assert Weights.scaled(building(:research_orbital), body(5, 4, 5), system()) == 2.0
    end

    test "count for x1 anywhere when nothing says what they would displace" do
      assert Weights.building(building(:shipyard_1_orbital), body(5, 5, 5), system()) == 1.0
      assert Weights.building(building(:shipyard_1_orbital), body(1, 1, 1), system()) == 1.0
    end

    test "the opportunity of a body is the best a scaling building could still do there" do
      pool = Enum.map([:research_orbital, :mine_orbital, :happy_pot_orbital, :shipyard_1_orbital], &building/1)

      assert Weights.opportunity(pool, body(2, 5, 1), system()) == 2.5
      assert Weights.opportunity(pool, body(2, 1, 1), system()) == 1.0
      # the Experiment Station is built: science no longer counts
      assert Weights.opportunity(tl(pool), body(2, 5, 1), system()) == 1.0
      assert Weights.opportunity([building(:shipyard_1_orbital)], body(5, 5, 5), system()) == 0.0
    end

    test "belong where they displace the least" do
      assert Weights.flat(nil) == 1.0
      # every potential 2 or less, or nothing else left to build
      assert Weights.flat(0.0) == 2.0
      assert Weights.flat(1.0) == 2.0
      # a potential of 3 still open: neutral
      assert Weights.flat(1.5) == 1.0
      assert Weights.flat(2.0) == 0.5
      assert Weights.flat(2.5) == 0.25

      yard = building(:shipyard_1_orbital)
      assert Weights.building(yard, body(1, 2, 2), system(), opportunity: 1.0) == 2.0
      assert Weights.building(yard, body(5, 2, 2), system(), opportunity: 2.5) == 0.25
    end
  end

  describe "emphasis" do
    test "scales single bonuses by what they produce" do
      # Orbital Terminus: flat mobility and flat credit
      terminus = building(:spatioport_orbital)

      assert Weights.building(terminus, body(1, 1, 1), system(), emphasis: %{sys_mobility: 0.5}) == 0.75
      assert Weights.building(terminus, body(1, 1, 1), system(), emphasis: %{sys_technology: 0.5}) == 1.0

      # Planetary Shield: flat defense. Tripled, it clears a x0.75 floor even
      # where a potential of 5 is still open.
      shield = building(:defense_local_open)
      assert Weights.building(shield, body(5, 1, 1), system(), opportunity: 2.5, emphasis: %{sys_defense: 3.0}) == 0.75
    end
  end
end
