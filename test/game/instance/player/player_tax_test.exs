defmodule Instance.Player.PlayerTaxTest do
  use ExUnit.Case, async: true

  alias Instance.Player.Player

  @moduledoc """
  The faction income tax as the member sees it (docs/faction-government.md):
  what leaves the member's income is what the treasury is sent, a member
  who cannot afford it is not taxed, and a deficit is never taxed
  backwards.
  """

  @test_instance_id 999_999_981

  setup_all do
    Data.Data.insert(@test_instance_id, speed: :fast, mode: :prod)
    on_exit(fn -> Data.Data.clear(@test_instance_id) end)
    :ok
  end

  # One system bringing `income` of each resource, and agents whose wages
  # (10 credit per level on the fast clock) add up to `wages`.
  defp player(income, wages, opts \\ []) do
    agents =
      if wages > 0,
        do: [%{id: 1, name: "Agent", type: :spy, status: :on_board, level: div(wages, 10), army_maintenance: 0}],
        else: []

    %Player{
      id: 1,
      account_id: 1,
      faction_id: 1,
      faction: :myrmezir,
      is_dead: false,
      is_bankrupt: false,
      is_active: true,
      avatar: nil,
      name: "Member",
      stellar_systems: [%{name: "Home", credit: income, technology: income, ideology: income}],
      dominions: [],
      characters: agents,
      credit: Core.DynamicValue.new(Keyword.get(opts, :stock, 10_000)),
      technology: Core.DynamicValue.new(10_000),
      ideology: Core.DynamicValue.new(10_000),
      patents: [],
      doctrines: [],
      policies: [],
      character_deck: [],
      max_policies: 1,
      update_policies_count: 1,
      policies_cooldown: Core.CooldownValue.new(),
      max_systems: Core.Value.new(),
      max_dominions: Core.Value.new(),
      max_admirals: Core.Value.new(),
      max_spies: Core.Value.new(),
      max_speakers: Core.Value.new(),
      dominion_rate: Core.Value.new(),
      transformed_system_count: 0,
      dominions_under_attack: [],
      instance_id: @test_instance_id,
      registration_id: 1,
      connected_clients: 0,
      pending_notifications: [],
      next_stats: 0,
      last_connection: Core.DynamicValue.new(0)
    }
  end

  defp taxed(player, rate) do
    effects = %{bonuses: [], tax_rates: %{credit: rate, technology: rate, ideology: rate}}
    Player.set_government_effects(player, effects)
  end

  defp untaxed(player), do: taxed(player, 0)

  test "the tax is taken on the income left after wages, and all of it is remitted" do
    before = untaxed(player(1000, 500))
    member = taxed(player(1000, 500), 10)

    assert before.credit.change == 500
    # 10% of the 500 left after wages, not of the 1000 before them
    assert_in_delta member.credit.change, 450, 0.001
    assert_in_delta member.tax_remit_rates.credit, 50, 0.001

    # no wages on technology: 10% of the full 1000
    assert_in_delta member.technology.change, 900, 0.001
    assert_in_delta member.tax_remit_rates.technology, 100, 0.001

    # the income tooltip names it
    assert [%{value: value}] = member.credit.details[:government]
    assert_in_delta value, -50, 0.001
  end

  test "a tax never turns a positive income into a deficit" do
    member = taxed(player(1000, 950), 10)

    assert_in_delta member.credit.change, 45, 0.001
    assert_in_delta member.tax_remit_rates.credit, 5, 0.001
  end

  test "a member running a deficit is not taxed, and is not paid either" do
    before = untaxed(player(1000, 1500))
    member = taxed(player(1000, 1500), 10)

    assert before.credit.change == -500
    assert member.credit.change == -500
    assert member.tax_remit_rates.credit == 0
    refute Map.has_key?(member.credit.details, :government)

    # the deficit is in credit only: the other incomes are still taxed
    assert_in_delta member.tax_remit_rates.technology, 100, 0.001
  end

  test "no rate, no tax" do
    member = untaxed(player(1000, 0))

    assert member.credit.change == 1000
    assert member.tax_remit_rates == %{credit: 0, technology: 0, ideology: 0}
  end
end
