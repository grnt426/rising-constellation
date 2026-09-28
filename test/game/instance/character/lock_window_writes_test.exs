defmodule Character.LockWindowWritesTest do
  @moduledoc """
  Writes to a character that land while the action orchestrator runs its
  head action's start/finish hook.

  The tick locks the queue and hands the orchestrator a copy of the
  character; the orchestrator runs the hook on that copy and calls
  `{:done, hook, character}` back. Anything the agent received in between
  — a ship finishing in a shipyard, a reaction change, an armada update,
  bonuses, training XP, a fight's result — was applied to the agent's
  state and then replaced by the orchestrator's copy.

  Each scenario installs a locked queue (the agent is never started, so no
  tick runs), applies one write, delivers the orchestrator's copy, and
  asserts the write survived alongside the hook's own changes.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.{ActionQueue, Character, LockMerge, Tile}
  alias Test.FleetScenario

  @owner 100

  setup do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid, speed: :fast, mode: :dev, cheats_enabled: true)

    FleetScenario.spawn_fake_galaxy(self(),
      instance_id: iid,
      edges: %{{10, 11} => 2, {11, 10} => 2},
      closest_systems: %{10 => 11}
    )

    {_player, player_pid} =
      FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: @owner, faction: :phoenix)

    {_character, pid} =
      FleetScenario.spawn_real_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :phoenix,
        owner_id: @owner,
        system: 10,
        has_ships?: false,
        virtual_position: 10
      )

    # {:done} re-arms the tick from the agent clock; an agent that was
    # never started has none
    :sys.replace_state(pid, fn st -> %{st | tick: %{st.tick | cumulated_pauses: 0, factor: 1}} end)

    # three empty tiles (real ships get planned/built on them)
    live = get(pid)
    tiles = for id <- 1..3, do: struct(Tile, %{id: id, ship_status: :empty, ship: nil})
    install(pid, %{live | army: %{live.army | tiles: tiles}})

    ship =
      Data.Querier.all(Data.Game.Ship, iid)
      |> Enum.find(&(&1.class != :capital))

    %{iid: iid, pid: pid, player: player_pid, ship: ship.key}
  end

  # ---- scenario plumbing ----------------------------------------------------

  defp get(pid) do
    {:ok, character} = GenServer.call(pid, :get_state)
    character
  end

  defp install(pid, character), do: GenServer.cast(pid, {:update_state, character})

  defp head_jump do
    FleetScenario.build_action(:jump, %{"source" => 10, "target" => 11},
      started_at: Instance.Time.Time.now(0),
      total_time: 1_000,
      remaining_time: 1_000
    )
  end

  # Lock the queue exactly as the tick does, run `write` inside the window,
  # then deliver the orchestrator's result: the pre-lock character with the
  # hook's own changes (`hook`) applied.
  defp in_lock_window(ctx, write, hook \\ & &1) do
    base = %{get(ctx.pid) | actions: ActionQueue.replace_queue([head_jump()])}
    locked = %{base | actions: ActionQueue.lock(base.actions)}
    install(ctx.pid, locked)

    write.()

    # the orchestrator returns its result together with the copy it was handed
    :ok = GenServer.call(ctx.pid, {:done, :start, hook.(base), locked})
    get(ctx.pid)
  end

  defp tile(character, id), do: Enum.find(character.army.tiles, &(&1.id == id))

  # the hook's own change, which must survive too
  defp started(character), do: %{character | action_status: :moving}

  # ---- shipyard ---------------------------------------------------------------

  describe "shipyard writes" do
    test "a ship completing during the lock stays built", ctx do
      {:ok, _} = GenServer.call(ctx.pid, {:order_ship, {1, 2, ctx.ship, 1}})

      after_done = in_lock_window(ctx, fn -> GenServer.cast(ctx.pid, {:put_ship, 2, 0}) end, &started/1)

      assert tile(after_done, 2).ship_status == :filled
      assert after_done.action_status == :moving
    end

    test "a ship ordered during the lock stays planned", ctx do
      after_done =
        in_lock_window(ctx, fn -> {:ok, _} = GenServer.call(ctx.pid, {:order_ship, {1, 3, ctx.ship, 1}}) end)

      assert tile(after_done, 3).ship_status == :planned
    end

    test "a ship cancelled during the lock stays cancelled", ctx do
      {:ok, _} = GenServer.call(ctx.pid, {:order_ship, {1, 2, ctx.ship, 1}})

      after_done = in_lock_window(ctx, fn -> {:ok, _} = GenServer.call(ctx.pid, {:cancel_ship, 2}) end)

      assert tile(after_done, 2).ship_status == :empty
    end

    test "a fleet-editor ship added during the lock stays", ctx do
      after_done =
        in_lock_window(ctx, fn ->
          {:ok, _} = GenServer.call(ctx.pid, {:cheat_edit_army, {:add, ctx.ship, 1, :single}})
        end)

      assert Enum.count(after_done.army.tiles, &(&1.ship_status == :filled)) == 1
    end
  end

  # ---- settings and progression --------------------------------------------------

  describe "settings and progression" do
    test "a reaction change during the lock sticks", ctx do
      after_done =
        in_lock_window(ctx, fn -> GenServer.call(ctx.pid, {:update_reaction, :attack_enemies}) end, &started/1)

      assert after_done.army.reaction == :attack_enemies
      assert after_done.action_status == :moving
    end

    test "an armada update during the lock sticks", ctx do
      armada = %{id: 7, lead_id: 1, member_ids: [1, 2]}
      after_done = in_lock_window(ctx, fn -> GenServer.call(ctx.pid, {:update_armada, armada}) end)

      assert Map.get(after_done, :armada) == armada
    end

    test "bonuses updated during the lock stick", ctx do
      bonus = [%{reason: {:lex, :test}, bonus: %Core.Bonus{from: :direct, to: :army_repair, type: :add, value: 3}}]
      after_done = in_lock_window(ctx, fn -> GenServer.call(ctx.pid, {:update_bonuses, :player, bonus}) end)

      assert after_done.bonuses[:player] == bonus
    end

    test "training XP granted during the lock sticks", ctx do
      before = get(ctx.pid).experience.value
      after_done = in_lock_window(ctx, fn -> GenServer.cast(ctx.pid, {:add_experience, 5}) end)

      assert after_done.experience.value > before
    end

    test "XP from the hook and from training during the lock both count", ctx do
      before = get(ctx.pid).experience.value

      after_done =
        in_lock_window(ctx, fn -> GenServer.cast(ctx.pid, {:add_experience, 5}) end, fn c ->
          %{c | experience: %{c.experience | value: c.experience.value + 3}}
        end)

      assert_in_delta after_done.experience.value, before + 8, 0.01
    end
  end

  # ---- fights involving a locked defender ------------------------------------------

  describe "a fight result for an agent whose own hook is pending" do
    setup ctx do
      {:ok, _} = GenServer.call(ctx.pid, {:order_ship, {1, 1, ctx.ship, 1}})
      GenServer.cast(ctx.pid, {:put_ship, 1, 0})
      assert tile(get(ctx.pid), 1).ship_status == :filled
      :ok
    end

    test "battle damage (a destroyed ship) survives the defender's {:done}", ctx do
      after_done =
        in_lock_window(
          ctx,
          fn ->
            # Player.Agent.fight_callback(:victorious, ...) casts the post-fight copy,
            # built from a :get_state snapshot taken during the lock
            snapshot = get(ctx.pid)
            GenServer.cast(ctx.pid, {:update_state, Character.remove_ship(snapshot, 1)})
          end,
          &started/1
        )

      assert tile(after_done, 1).ship_status == :empty
      assert after_done.action_status == :moving
    end

    test "a beaten defender still flees once its own hook lands", ctx do
      # its own pending hook: a raid starting where it stands
      raid = FleetScenario.build_action(:raid, %{"target" => 10}, started_at: Instance.Time.Time.now(0))
      base = %{get(ctx.pid) | actions: ActionQueue.replace_queue([raid])}
      locked = %{base | actions: ActionQueue.lock(base.actions)}
      install(ctx.pid, locked)

      # Player.Agent.fight_callback(:fleeing, ...): the post-fight copy, then :flee
      snapshot = get(ctx.pid)
      GenServer.cast(ctx.pid, {:update_state, Character.remove_ship(snapshot, 1)})
      fled = GenServer.call(ctx.pid, :flee)
      # the caller gets the fleeing character right away (it updates its cache)
      assert [%{type: :jump}] = Queue.to_list(fled.actions.queue)
      # ...but the lock the pending hook relies on is still in place
      assert ActionQueue.locked?(get(ctx.pid).actions)

      :ok = GenServer.call(ctx.pid, {:done, :start, %{base | action_status: :raid}, locked})
      after_done = get(ctx.pid)

      # (the tick {:done} triggers may already be starting the flee jump)
      queue = ActionQueue.skip_initial_lock(after_done.actions).queue
      assert [%{type: :jump, data: %{"source" => 10, "target" => 11}}] = Queue.to_list(queue)
      assert after_done.actions.virtual_position == 11
      assert tile(after_done, 1).ship_status == :empty
    end
  end

  # ---- the merge rules themselves -------------------------------------------------

  defp char(tiles, extra \\ %{}) do
    base = FleetScenario.build_character(instance_id: 1, character_id: 1, faction: :phoenix, system: 10)
    Map.merge(%{base | army: %{base.army | tiles: tiles}}, extra)
  end

  defp t(id, status), do: struct(Tile, %{id: id, ship_status: status, ship: nil})

  describe "LockMerge" do
    test "each side keeps the tiles it changed; a tile both changed goes to the hook" do
      base = char([t(1, :filled), t(2, :planned), t(3, :filled)])
      # the window: ship 2 completed, tile 3 lost in another agent's fight
      ours = char([t(1, :filled), t(2, :filled), t(3, :empty)])
      # the hook's own changes: tile 1 destroyed, tile 3 changed too
      theirs = char([t(1, :empty), t(2, :planned), t(3, :planned)])

      {merged, changed, conflicts} = LockMerge.merge(base, ours, theirs)

      assert Enum.map(merged.army.tiles, &{&1.id, &1.ship_status}) == [{1, :empty}, {2, :filled}, {3, :planned}]
      assert :army in changed
      assert conflicts == []
    end

    test "the queue is always the hook's, silently" do
      base = char([t(1, :empty)])
      ours = %{base | actions: ActionQueue.replace_queue([FleetScenario.build_action(:jump, %{"target" => 11})])}
      theirs = %{base | actions: ActionQueue.replace_queue([FleetScenario.build_action(:jump, %{"target" => 12})])}

      {merged, _changed, conflicts} = LockMerge.merge(base, ours, theirs)
      assert merged.actions == theirs.actions
      assert conflicts == []
    end

    test "bonus maps merge key by key" do
      base = char([t(1, :empty)], %{bonuses: %{a: [1]}})
      ours = %{base | bonuses: %{a: [1], player: [2]}}
      theirs = %{base | bonuses: %{a: [1], character: [3]}}

      {merged, _changed, conflicts} = LockMerge.merge(base, ours, theirs)
      assert merged.bonuses == %{a: [1], player: [2], character: [3]}
      assert conflicts == []
    end

    test "a scalar both sides changed differently goes to the hook and is reported" do
      base = char([t(1, :empty)], %{action_status: :idle})
      ours = %{base | action_status: :docking}
      theirs = %{base | action_status: :moving}

      {merged, _changed, conflicts} = LockMerge.merge(base, ours, theirs)
      assert merged.action_status == :moving
      assert conflicts == [:action_status]
    end

    test "nothing written during the window: the hook's result, untouched" do
      base = char([t(1, :filled)])
      theirs = %{base | action_status: :moving, system: nil}
      assert {^theirs, [], []} = LockMerge.merge(base, base, theirs)
    end
  end
end
