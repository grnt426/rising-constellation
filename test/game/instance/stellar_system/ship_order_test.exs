defmodule Instance.StellarSystem.ShipOrderTest do
  @moduledoc """
  A stellar system does not start a ship for a Navarch that has orders
  queued.

  A fleet under construction does not move: every order refuses a docking
  Navarch (`:unable_to_move`). The other order of commands was open. A jump
  is accepted into the queue before its start hook takes the Navarch out of
  the system, and until then the Navarch still reads idle. A ship ordered in
  between was planned, the Navarch left with it, the ship stayed in the
  system's queue, and it was delivered to the fleet wherever it then was.

  The rule sits in `StellarSystem.can_order_ship/3`, the player's path to a
  shipyard (`Player.Agent` → `StellarSystem.Agent` → the character agent).
  The instant builds that plan a ship on the character agent directly (the
  Wave warlord's colony ships, fixtures, the fight simulator) do not go
  through it. Armadas have their own gate on top, for the other members:
  `Instance.Player.ArmadaImpl.check_order_ship/2`.

  A real `Character.Agent`, never started, so nothing ticks on its own; the
  system is a bare struct, and its agent's handler is called directly.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.ActionQueue
  alias Instance.Character.Army
  alias Instance.StellarSystem.Agent, as: SystemAgent
  alias Instance.StellarSystem.{ProductionQueue, StellarSystem}
  alias Test.FleetScenario

  @owner 100
  @navarch 1
  @home 10
  @jump [%{"type" => "jump", "data" => %{"source" => 10, "target" => 11}}]

  setup do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid)
    FleetScenario.spawn_fake_galaxy(self(), instance_id: iid, edges: %{{10, 11} => 2})
    FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: @owner, faction: :phoenix)

    {_navarch, pid} =
      FleetScenario.spawn_real_character(self(),
        instance_id: iid,
        character_id: @navarch,
        faction: :phoenix,
        owner_id: @owner,
        system: @home,
        has_ships?: false,
        virtual_position: @home
      )

    system = struct(StellarSystem, %{id: @home, instance_id: iid, siege: nil, bodies: [], queue: ProductionQueue.new()})

    # a ship that needs no shipyard, on the harness Navarch's one empty tile
    ship =
      Data.Game.Ship
      |> Data.Querier.all(iid)
      |> Enum.find(&(&1.shipyard == nil and &1.class != :capital))

    {:ok, iid: iid, pid: pid, system: system, order: {@navarch, 1, ship.key, 1}}
  end

  describe "StellarSystem.can_order_ship/3" do
    test "a Navarch at rest in the system can be given a ship", ctx do
      assert {:ok, _} = StellarSystem.can_order_ship(ctx.system, ctx.order, navarch(ctx))
    end

    test "a Navarch already in the yard can be given another", ctx do
      assert {:ok, %{action_status: :docking}} = Game.call(ctx.iid, :character, @navarch, {:order_ship, ctx.order})

      assert {:ok, _} = StellarSystem.can_order_ship(ctx.system, ctx.order, navarch(ctx))
    end

    test "a Navarch with a jump queued cannot, though it still reads idle", ctx do
      assert :ok == Game.call(ctx.iid, :character, @navarch, {:add_actions, @jump})
      assert %{action_status: :idle, system: @home} = navarch(ctx)

      assert {:error, :character_not_idle_or_docking} ==
               StellarSystem.can_order_ship(ctx.system, ctx.order, navarch(ctx))
    end

    test "nor while the jump's start hook is in flight", ctx do
      assert :ok == Game.call(ctx.iid, :character, @navarch, {:add_actions, @jump})

      # what the tick does before handing the head action to the orchestrator
      queued = navarch(ctx)
      GenServer.cast(ctx.pid, {:update_state, %{queued | actions: ActionQueue.lock(queued.actions)}})
      assert ActionQueue.locked?(navarch(ctx).actions)

      assert {:error, :character_not_idle_or_docking} ==
               StellarSystem.can_order_ship(ctx.system, ctx.order, navarch(ctx))
    end
  end

  describe "the system agent's {:order_ship, _}" do
    test "plans the ship for a Navarch at rest and queues it", ctx do
      state = agent_state(ctx)

      assert {:reply, {:ok, ordered, system}, %{data: system}} =
               SystemAgent.on_call({:order_ship, ctx.order}, nil, state)

      assert ordered.action_status == :docking
      assert Army.has_planned_ship?(navarch(ctx).army)
      assert [%{type: :ship, target_id: @navarch, tile_id: 1}] = Queue.to_list(system.queue.queue)
    end

    test "refuses a Navarch with a jump queued: nothing planned, nothing queued", ctx do
      state = agent_state(ctx)
      assert :ok == Game.call(ctx.iid, :character, @navarch, {:add_actions, @jump})

      assert {:reply, {:error, :character_not_idle_or_docking}, ^state} =
               SystemAgent.on_call({:order_ship, ctx.order}, nil, state)

      assert %{action_status: :idle} = navarch(ctx)
      refute Army.has_planned_ship?(navarch(ctx).army)
    end
  end

  # ---------------------------------------------------------------------------

  defp navarch(ctx) do
    {:ok, navarch} = Game.call(ctx.iid, :character, @navarch, :get_state)
    navarch
  end

  # Enough agent state for the handler: `tick.running?: false` makes the
  # tick decorator a no-op.
  defp agent_state(ctx), do: %{tick: %{running?: false}, instance_id: ctx.iid, data: ctx.system}
end
