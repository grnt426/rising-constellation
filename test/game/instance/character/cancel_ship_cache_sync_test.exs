defmodule Character.CancelShipCacheSyncTest do
  @moduledoc """
  Regression tests for the stuck-Navarch bug (prod instance 87,
  "Grania Astarly", 2026-07-30).

  The player agent keeps a cached `Instance.Player.Character` copy of every
  character it owns; that cache is what the market's list-for-sale check
  validates and what the client renders (via the `player_player` broadcast).
  Ship COMPLETION (`{:put_ship, ...}`) casts `{:update_character, data}` to
  the owner so the cache tracks the army and the final docking -> idle flip.
  Ship CANCELLATION did not: `Character.Agent`'s `{:cancel_ship, tile_id}`
  handler updated only its own state, the stellar-system agent discarded the
  returned character, and the player agent's `cancel_production` handler
  never touched its character list.

  The stale cache normally self-heals when a later ship completes. But when
  the LAST state transition is a cancel — the player lets part of the fleet
  build, then cancels the rest — nothing ever refreshes the cache: the
  character agent is `:idle` while the cached copy says `:docking` with
  phantom planned ships, forever. The UI shows "Stuck in the docking bay"
  and blocks movement; the market rejects the listing server-side.

  These tests drive the REAL `Instance.Character.Agent.on_call/3` handler
  (the tick decorator is a no-op when `tick.running?` is false) against a
  fake player registered in `Game.Registry`, and assert the
  `{:update_character, ...}` cast now fires on every successful cancel.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Tile
  alias Test.FleetScenario

  @owner_id 42
  @tile_filled 1
  @tile_planned_a 2
  @tile_planned_b 3

  defp docking_admiral(instance_id, planned_tile_ids) do
    character =
      FleetScenario.build_character(
        instance_id: instance_id,
        character_id: 494,
        faction: :myrmezir,
        system: 238,
        action_status: :docking,
        owner_id: @owner_id
      )

    tiles =
      [struct(Tile, %{id: @tile_filled, ship_status: :filled, ship: nil})] ++
        Enum.map(planned_tile_ids, fn id -> struct(Tile, %{id: id, ship_status: :planned, ship: nil}) end)

    %{character | army: %{character.army | tiles: tiles}}
  end

  # Minimal Core.TickServer-shaped state. `running?: false` short-circuits
  # the `@decorate tick()` wrapper (`next_tick/1` returns state unchanged),
  # so the real handler body runs without live tick scheduling.
  defp agent_state(character) do
    %{
      data: character,
      instance_id: character.instance_id,
      tick: %Core.Tick{time: 0, factor: 1, running?: false}
    }
  end

  test "cancelling the LAST planned ship flips docking -> idle and casts the update to the owner" do
    instance_id = FleetScenario.unique_instance_id()

    {_player, player_pid} =
      FleetScenario.spawn_fake_player(self(), instance_id: instance_id, player_id: @owner_id, faction: :myrmezir)

    state = agent_state(docking_admiral(instance_id, [@tile_planned_a]))

    {:reply, {:ok, data}, new_state} =
      Instance.Character.Agent.on_call({:cancel_ship, @tile_planned_a}, self(), state)

    assert data.action_status == :idle
    assert new_state.data.action_status == :idle

    # The cast and this getter call are both sent from the test process to
    # the same fake, so delivery order is guaranteed — no sleep needed.
    assert [updated] = FleetScenario.get_character_updates(player_pid)
    assert updated.id == 494
    assert updated.action_status == :idle
    refute Enum.any?(updated.army.tiles, fn tile -> tile.ship_status == :planned end)
  end

  test "cancelling a ship while others remain planned stays :docking but still refreshes the cache" do
    instance_id = FleetScenario.unique_instance_id()

    {_player, player_pid} =
      FleetScenario.spawn_fake_player(self(), instance_id: instance_id, player_id: @owner_id, faction: :myrmezir)

    state = agent_state(docking_admiral(instance_id, [@tile_planned_a, @tile_planned_b]))

    {:reply, {:ok, data}, _new_state} =
      Instance.Character.Agent.on_call({:cancel_ship, @tile_planned_a}, self(), state)

    assert data.action_status == :docking

    # The cache still needs this update: it carries the decremented
    # planned-ship count (army_size) the client renders.
    assert [updated] = FleetScenario.get_character_updates(player_pid)
    assert updated.action_status == :docking
    assert Enum.count(updated.army.tiles, fn tile -> tile.ship_status == :planned end) == 1
  end

  test "a failed cancel (tile not planned) sends no update" do
    instance_id = FleetScenario.unique_instance_id()

    {_player, player_pid} =
      FleetScenario.spawn_fake_player(self(), instance_id: instance_id, player_id: @owner_id, faction: :myrmezir)

    state = agent_state(docking_admiral(instance_id, [@tile_planned_a]))

    {:reply, {:error, :tile_not_planned}, unchanged_state} =
      Instance.Character.Agent.on_call({:cancel_ship, @tile_filled}, self(), state)

    assert unchanged_state.data.action_status == :docking
    assert FleetScenario.get_character_updates(player_pid) == []
  end
end
