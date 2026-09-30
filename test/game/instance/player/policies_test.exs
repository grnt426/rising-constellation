defmodule Instance.Player.PoliciesTest do
  @moduledoc """
  Changing active lexes (`Instance.Player.Player.update_policies/2`): a lex is
  active at most once, and every change makes the next wait longer.
  """
  use ExUnit.Case, async: false

  alias Instance.Player.Player

  setup do
    iid = 800_000 + System.unique_integer([:positive])
    Data.Data.insert(iid, speed: :slow, mode: :prod)

    on_exit(fn ->
      try do
        Data.Data.clear(iid)
      rescue
        _ -> :ok
      end
    end)

    {:ok, player: player(iid)}
  end

  test "a lex listed twice is refused, not counted twice", %{player: p} do
    assert {:error, :duplicate_policy} = Player.update_policies(p, [:agent, :agent])

    # The same player may still activate it once.
    assert {:ok, once, _, _} = Player.update_policies(p, [:agent])
    assert once.max_admirals.value == 2
  end

  test "every change makes the next wait longer (Legacy 6, 10, 14 ticks)", %{player: p} do
    waits =
      Enum.map_reduce(1..3, p, fn _, acc ->
        {:ok, next, _, _} = Player.update_policies(acc, [:agent])
        {next.policies_cooldown.value, %{next | policies_cooldown: Core.CooldownValue.new()}}
      end)
      |> elem(0)

    assert waits == [6, 10, 14]
  end

  defp res(v), do: %Core.DynamicValue{value: v, details: %{}, change: 0}

  defp player(iid) do
    %Player{
      id: 1,
      account_id: 1,
      faction_id: 1,
      faction: :tetrarchy,
      is_dead: false,
      is_bankrupt: false,
      is_active: true,
      avatar: "x",
      name: "T",
      stellar_systems: [],
      dominions: [],
      characters: [],
      credit: res(100_000),
      technology: res(100_000),
      ideology: res(100_000),
      patents: [],
      doctrines: [:agent, :admiral_1],
      policies: [],
      character_deck: [],
      max_policies: 2,
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
      instance_id: iid,
      registration_id: 1,
      connected_clients: 0,
      pending_notifications: [],
      next_stats: 0,
      last_connection: Core.DynamicValue.new(0)
    }
  end
end
