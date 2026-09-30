defmodule Instance.StellarSystem.MobilityCreditTest do
  @moduledoc """
  The credits a system earns from mobility (`{:misc, :population_mobility}`,
  mobility × `system_mobility_taxes_factor` × workforce) count all of the
  system's mobility, percentage bonuses included. The line used to be a
  `:mul`, which reads the bonus pipeline's last snapshot: a +10 % mobility lex
  (Trade Secrets) or tradition raised mobility but not these credits, unless
  some unrelated order-30 `:add` (a Monolith's ideology, a Reflect District's
  credits) happened to refresh the snapshot. Found by the help manual's
  Patents & lexes review, 2026-09-30.
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.{ProductionQueue, StellarBody, StellarSystem, Tile}
  alias Test.FleetScenario

  setup do
    iid = System.unique_integer([:positive])
    FleetScenario.load_game_data(iid, speed: :slow, mode: :prod)
    {:ok, iid: iid}
  end

  @flat_mobility %{reason: {:test, :mobility}, bonus: %Core.Bonus{from: :direct, to: :sys_mobility, type: :add, value: 30}}
  @plus_ten_percent %{reason: {:doctrine, :mobility_2}, bonus: %Core.Bonus{from: :sys_mobility, to: :sys_mobility, type: :mul, value: 0.1}}

  test "a percentage mobility bonus raises the credits from mobility", %{iid: iid} do
    {_, _, without} = StellarSystem.update_bonuses(system(iid), :test, [@flat_mobility])
    {_, _, with_lex} = StellarSystem.update_bonuses(system(iid), :test, [@flat_mobility, @plus_ten_percent])

    # Legacy: 0.1 credit per mobility point per workforce point, 20 workforce
    assert without.mobility.value == 30
    assert mobility_credits(without) == 30 * 0.1 * 20

    assert with_lex.mobility.value == 33.0
    assert_in_delta mobility_credits(with_lex), 33 * 0.1 * 20, 1.0e-9
  end

  defp mobility_credits(state) do
    state.credit.details
    |> Map.get(:misc, [])
    |> Enum.filter(&(&1.reason == :population_mobility))
    |> Enum.map(& &1.value)
    |> Enum.sum()
  end

  # One habitable planet with nothing built, 20 workforce.
  defp system(iid) do
    body =
      struct(StellarBody, %{
        id: 1,
        uid: "1",
        type: :habitable_planet,
        name: "Mobility test",
        industrial_factor: 3,
        technological_factor: 3,
        activity_factor: 3,
        population: 20,
        bodies: [],
        tiles: [Tile.new(1, :primary), Tile.new(2, :primary)]
      })

    struct(StellarSystem, %{
      id: 998,
      name: "mobility-credit-test",
      status: :inhabited_player,
      instance_id: iid,
      bodies: [body],
      queue: ProductionQueue.new(),
      siege: nil,
      owner: nil,
      workforce: 20,
      population: Core.DynamicValue.new(20.5),
      remove_contact: Core.DynamicValue.new(0.0),
      happiness_penalties: [],
      ai_profile: :production
    })
  end
end
