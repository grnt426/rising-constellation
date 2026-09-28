defmodule Character.AddActionsTest do
  @moduledoc """
  `{:add_actions, actions}` on a real `Instance.Character.Agent`: an
  action refused by its `pre_validate/2` comes back as
  `{:error, reason}` (the reason the client toasts) instead of a silent
  `:ok` that dropped the order. A batch is all or nothing, and a refused
  batch leaves the queue and the owner's cached copy untouched.
  Malformed payloads are refused as data errors; they must not crash the
  agent, which would restart it from the last snapshot.

  Also the Player.Agent layer the channel calls
  (`{:add_character_actions, ...}`), which relays the reason.
  """
  use ExUnit.Case, async: true

  alias Instance.Player.Agent, as: PlayerAgent
  alias Instance.Player.Player
  alias Test.FleetScenario

  # 10 — 11 are adjacent, 12 is not reachable from 10
  setup do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid)
    FleetScenario.spawn_fake_galaxy(self(), instance_id: iid, edges: %{{10, 11} => 2, {11, 10} => 2})
    {_player, player_pid} = FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 100, faction: :phoenix)

    %{iid: iid, player: player_pid}
  end

  defp navarch(ctx, opts \\ []) do
    FleetScenario.spawn_real_character(
      self(),
      Keyword.merge(
        [
          instance_id: ctx.iid,
          character_id: 1,
          faction: :phoenix,
          owner_id: 100,
          system: 10,
          has_ships?: false,
          virtual_position: 10
        ],
        opts
      )
    )
  end

  defp live(ctx, id \\ 1) do
    {:ok, character} = Game.call(ctx.iid, :character, id, :get_state)
    character
  end

  defp queued(ctx), do: Queue.to_list(live(ctx).actions.queue) |> Enum.map(& &1.type)

  defp jump(source, target), do: %{"type" => "jump", "data" => %{"source" => source, "target" => target}}
  defp colonization(target), do: %{"type" => "colonization", "data" => %{"target" => target}}

  describe "jump" do
    test "an adjacent jump is queued and the owner's copy refreshed", ctx do
      navarch(ctx)

      assert :ok == Game.call(ctx.iid, :character, 1, {:add_actions, [jump(10, 11)]})
      assert queued(ctx) == [:jump]
      assert live(ctx).actions.virtual_position == 11
      assert [_refreshed] = FleetScenario.get_character_updates(ctx.player)
    end

    test "a jump along no edge is refused with :invalid_jump, nothing changes", ctx do
      navarch(ctx)

      assert {:error, :invalid_jump} == Game.call(ctx.iid, :character, 1, {:add_actions, [jump(10, 12)]})
      assert queued(ctx) == []
      assert live(ctx).actions.virtual_position == 10
      assert [] == FleetScenario.get_character_updates(ctx.player)
    end

    test "a jump from the wrong source is refused with :invalid_position", ctx do
      navarch(ctx)

      assert {:error, :invalid_position} == Game.call(ctx.iid, :character, 1, {:add_actions, [jump(11, 12)]})
      assert queued(ctx) == []
    end
  end

  describe "colonization" do
    test "a docking navarch's colonization is refused with :unable_to_move", ctx do
      navarch(ctx, action_status: :docking)

      assert {:error, :unable_to_move} == Game.call(ctx.iid, :character, 1, {:add_actions, [colonization(10)]})
      assert queued(ctx) == []
      assert [] == FleetScenario.get_character_updates(ctx.player)
    end

    test "a colonization away from the navarch's position is refused with :invalid_position", ctx do
      navarch(ctx)

      assert {:error, :invalid_position} == Game.call(ctx.iid, :character, 1, {:add_actions, [colonization(11)]})
      assert queued(ctx) == []
    end

    test "a second colonization of the same target is refused", ctx do
      navarch(ctx)

      assert :ok == Game.call(ctx.iid, :character, 1, {:add_actions, [colonization(10)]})

      assert {:error, :no_multiple_colonization} ==
               Game.call(ctx.iid, :character, 1, {:add_actions, [colonization(10)]})

      assert queued(ctx) == [:colonization]
    end
  end

  describe "batches are all or nothing" do
    test "each action validates against the queue the previous ones built", ctx do
      navarch(ctx)

      assert :ok == Game.call(ctx.iid, :character, 1, {:add_actions, [jump(10, 11), colonization(11)]})
      assert queued(ctx) == [:jump, :colonization]
    end

    test "one refused action rejects the whole batch", ctx do
      navarch(ctx)

      # the jump alone is valid, the colonization after it is not (12 is
      # not where the jump lands)
      assert {:error, :invalid_position} ==
               Game.call(ctx.iid, :character, 1, {:add_actions, [jump(10, 11), colonization(12)]})

      assert queued(ctx) == []
      assert live(ctx).actions.virtual_position == 10
      assert [] == FleetScenario.get_character_updates(ctx.player)
    end
  end

  describe "malformed payloads" do
    test "are refused without crashing the character agent", ctx do
      {_character, pid} = navarch(ctx)
      # a type string that is not an existing atom used to raise in
      # String.to_existing_atom/1 inside the agent
      unknown = "warp_#{System.unique_integer([:positive])}"

      assert {:error, :action_not_found} ==
               Game.call(ctx.iid, :character, 1, {:add_actions, [%{"type" => unknown, "data" => %{}}]})

      assert {:error, :bad_data} == Game.call(ctx.iid, :character, 1, {:add_actions, [%{"type" => "jump"}]})

      assert {:error, :bad_data} ==
               Game.call(ctx.iid, :character, 1, {:add_actions, [%{"type" => "jump", "data" => "10-11"}]})

      assert {:error, :bad_data} == Game.call(ctx.iid, :character, 1, {:add_actions, ["jump"]})
      assert {:error, :bad_data} == Game.call(ctx.iid, :character, 1, {:add_actions, %{"type" => "jump"}})

      assert Process.alive?(pid)
      assert queued(ctx) == []
    end
  end

  describe "Player.Agent add_character_actions" do
    # tick.running?: false short-circuits the tick decorator
    defp player_state(ctx, character_ids) do
      %{
        tick: %{running?: false},
        instance_id: ctx.iid,
        data: struct(Player, %{characters: Enum.map(character_ids, &%{id: &1, on_sold: false})}),
        channel: "test:add-actions:#{ctx.iid}"
      }
    end

    test "relays the refusal reason", ctx do
      navarch(ctx)

      assert {:reply, {:error, :invalid_jump}, _state} =
               PlayerAgent.on_call({:add_character_actions, 1, [jump(10, 12)]}, nil, player_state(ctx, [1]))

      assert {:reply, :ok, _state} =
               PlayerAgent.on_call({:add_character_actions, 1, [jump(10, 11)]}, nil, player_state(ctx, [1]))
    end

    test "a rostered character without an agent is :character_not_found", ctx do
      assert {:reply, {:error, :character_not_found}, _state} =
               PlayerAgent.on_call({:add_character_actions, 2, [jump(10, 11)]}, nil, player_state(ctx, [2]))
    end
  end
end
