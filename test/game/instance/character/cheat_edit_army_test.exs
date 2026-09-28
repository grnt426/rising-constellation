defmodule Character.CheatEditArmyTest do
  @moduledoc """
  The Cheats tab fleet editor: `{:cheat_edit_army, edit}` on
  `Instance.Character.Agent`, reached through the CheatChannel `fleet_*`
  events. Covers placement order and the Shift / Ctrl+Shift line fills,
  the planned-tile guard, the instance-flag re-check, the owner cache
  refresh, and the level pinning.

  Drives the REAL agent handler (the tick decorator is a no-op when
  `tick.running?` is false) against real game data and a fake owner
  player, like `Character.CancelShipCacheSyncTest`.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Army
  alias Instance.Character.Ship
  alias Test.FleetScenario

  @owner_id 42

  setup do
    instance_id = FleetScenario.unique_instance_id()
    FleetScenario.load_game_data(instance_id, speed: :fast, mode: :dev, cheats_enabled: true)
    FleetScenario.spawn_fake_rand(self(), instance_id: instance_id)

    {_player, player_pid} =
      FleetScenario.spawn_fake_player(self(), instance_id: instance_id, player_id: @owner_id, faction: :myrmezir)

    ships = Data.Querier.all(Data.Game.Ship, instance_id)

    %{
      instance_id: instance_id,
      player_pid: player_pid,
      escort: Enum.find(ships, fn ship -> ship.class != :capital end),
      capital: Enum.find(ships, fn ship -> ship.class == :capital end)
    }
  end

  defp admiral(instance_id, opts \\ []) do
    character =
      FleetScenario.build_character(
        [instance_id: instance_id, character_id: 7, faction: :myrmezir, system: 1, owner_id: @owner_id] ++ opts
      )

    %{character | army: Army.new(instance_id)}
  end

  # A tile planned the way a shipyard order plans it.
  defp plan(character, tile_id, ship_data) do
    %{character | army: Army.plan_ship(character.army, tile_id, ship_data, nil)}
  end

  defp agent_state(character) do
    %{
      data: character,
      instance_id: character.instance_id,
      tick: %Core.Tick{time: 0, factor: 1, running?: false}
    }
  end

  defp edit(state, edit), do: Instance.Character.Agent.on_call({:cheat_edit_army, edit}, self(), state)

  defp edit!(state, edit) do
    {:reply, {:ok, _data}, state} = edit(state, edit)
    state
  end

  defp statuses(state), do: Enum.map(state.data.army.tiles, & &1.ship_status)
  defp keys(state), do: Enum.map(state.data.army.tiles, fn tile -> tile.ship && tile.ship.key end)

  test "a click builds a fresh ship at the chosen level in the first empty tile", ctx do
    state = agent_state(admiral(ctx.instance_id))

    {:reply, {:ok, data}, state} = edit(state, {:add, ctx.escort.key, 3, :single})

    [first | rest] = state.data.army.tiles
    assert first.ship_status == :filled
    assert first.ship.key == ctx.escort.key
    assert first.ship.level == 3
    assert length(first.ship.units) == ctx.escort.unit_count
    assert Enum.all?(first.ship.units, fn unit -> unit.hull == ctx.escort.unit_hull end)
    assert Enum.all?(rest, fn tile -> tile.ship_status == :empty end)

    # compute_bonus ran: the army carries the ship's upkeep
    assert data.army.maintenance.value == ctx.escort.maintenance_cost

    # the owner's cached copy is refreshed like a ship completion
    assert [updated] = FleetScenario.get_character_updates(ctx.player_pid)
    assert Enum.count(updated.army.tiles, fn tile -> tile.ship_status == :filled end) == 1
  end

  test "successive clicks fill in tile order and skip planned tiles", ctx do
    state = ctx.instance_id |> admiral() |> plan(2, ctx.capital) |> agent_state()

    state =
      state
      |> edit!({:add, ctx.escort.key, 0, :single})
      |> edit!({:add, ctx.escort.key, 0, :single})

    assert Enum.take(statuses(state), 4) == [:filled, :planned, :filled, :empty]
    assert Enum.take(keys(state), 3) == [ctx.escort.key, ctx.capital.key, ctx.escort.key]
  end

  test "shift fills the first empty tile's line, never overwriting", ctx do
    state =
      ctx.instance_id
      |> admiral()
      |> agent_state()
      |> edit!({:add, ctx.capital.key, 0, :single})
      |> edit!({:add, ctx.escort.key, 0, :fill_line})

    assert Enum.take(keys(state), 4) == [ctx.capital.key, ctx.escort.key, ctx.escort.key, nil]
  end

  test "ctrl+shift overwrites that line's built ships, but not planned tiles or other lines", ctx do
    state = ctx.instance_id |> admiral() |> plan(5, ctx.capital) |> agent_state()

    # L1 full of capitals, then a capital on tile 4: the first empty tile is 6
    state =
      state
      |> edit!({:add, ctx.capital.key, 0, :fill_line})
      |> edit!({:add, ctx.capital.key, 0, :single})
      |> edit!({:add, ctx.escort.key, 5, :override_line})

    assert Enum.take(keys(state), 7) ==
             [ctx.capital.key, ctx.capital.key, ctx.capital.key, ctx.escort.key, ctx.capital.key, ctx.escort.key, nil]

    assert Enum.at(statuses(state), 4) == :planned
    assert Enum.at(state.data.army.tiles, 3).ship.level == 5
  end

  test "a full army refuses placement and sends no update", ctx do
    state = agent_state(admiral(ctx.instance_id))
    lines = div(length(state.data.army.tiles), 3)

    state = Enum.reduce(1..lines, state, fn _, state -> edit!(state, {:add, ctx.escort.key, 0, :fill_line}) end)
    assert Enum.all?(statuses(state), &(&1 == :filled))

    sent = length(FleetScenario.get_character_updates(ctx.player_pid))

    for mode <- [:single, :fill_line, :override_line] do
      assert {:reply, {:error, :army_full}, ^state} = edit(state, {:add, ctx.capital.key, 0, mode})
    end

    assert length(FleetScenario.get_character_updates(ctx.player_pid)) == sent
  end

  test "set swaps a tile's ship, remove and clear empty built tiles, planned tiles are refused", ctx do
    state =
      ctx.instance_id
      |> admiral()
      |> plan(3, ctx.capital)
      |> agent_state()
      |> edit!({:add, ctx.escort.key, 2, :fill_line})
      |> edit!({:set, 2, ctx.capital.key, 4})

    swapped = Enum.at(state.data.army.tiles, 1)
    assert swapped.ship.key == ctx.capital.key
    assert swapped.ship.level == 4

    state = edit!(state, {:remove, 1})
    assert Enum.take(statuses(state), 3) == [:empty, :filled, :planned]

    assert {:reply, {:error, :tile_planned}, _} = edit(state, {:remove, 3})
    assert {:reply, {:error, :tile_planned}, _} = edit(state, {:set, 3, ctx.escort.key, 0})
    assert {:reply, {:error, :unknown_tile}, _} = edit(state, {:remove, 99})

    state = edit!(state, :clear)
    assert Enum.take(statuses(state), 3) == [:empty, :empty, :planned]
    assert Enum.at(keys(state), 2) == ctx.capital.key
  end

  test "capitals are named like ordered ones, escorts are not", ctx do
    state =
      ctx.instance_id
      |> admiral()
      |> agent_state()
      |> edit!({:add, ctx.capital.key, 0, :single})
      |> edit!({:add, ctx.escort.key, 0, :single})

    [capital, escort | _] = state.data.army.tiles
    assert is_binary(capital.ship.name)
    assert escort.ship.name == nil
  end

  test "unknown ships, bad levels and non-deployed characters are refused", ctx do
    state = agent_state(admiral(ctx.instance_id))

    assert {:reply, {:error, :unknown_ship}, ^state} = edit(state, {:add, :not_a_ship, 0, :single})
    assert {:reply, {:error, :invalid_level}, ^state} = edit(state, {:add, ctx.escort.key, -1, :single})

    for opts <- [[status: :in_deck], [type: :spy]] do
      other = agent_state(admiral(ctx.instance_id, opts))
      assert {:reply, {:error, :not_a_deployed_admiral}, _} = edit(other, {:add, ctx.escort.key, 0, :single})
    end

    assert FleetScenario.get_character_updates(ctx.player_pid) == []
  end

  test "an instance without cheat access refuses the edit", ctx do
    instance_id = FleetScenario.unique_instance_id()
    FleetScenario.load_game_data(instance_id)

    state = agent_state(admiral(instance_id))
    assert {:reply, {:error, :cheats_disabled}, ^state} = edit(state, {:add, ctx.escort.key, 0, :single})
  end

  test "a pinned level carries the experience the XP curve reaches it at", ctx do
    fresh = Ship.new(ctx.escort)

    for level <- 1..15 do
      pinned = Ship.set_level(fresh, level)
      next = Ship.set_level(fresh, level + 1)

      assert Ship.add_experience(fresh, pinned.experience + 0.01).level == level
      assert Ship.add_experience(fresh, pinned.experience - 0.01).level == level - 1

      # and it keeps levelling normally from there
      assert Ship.add_experience(pinned, next.experience - pinned.experience + 0.01).level == level + 1
    end
  end
end
