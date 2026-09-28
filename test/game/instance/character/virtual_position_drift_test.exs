defmodule Character.VirtualPositionDriftTest do
  @moduledoc """
  `actions.virtual_position` is where a character will stand once its queue
  is done, and every order is validated against it. Paths that leave it
  anywhere but the character's real position poison every later order
  (refused as `:invalid_position`, or worse, accepted from the wrong place).

  Each scenario below drives one such path and asserts the invariant: once
  the queue is emptied, `virtual_position` is the system the character is
  actually in. And a jump that would start from a system the character is
  not in is refused (queue cleared, position reset) instead of "leaving" a
  system it never was in — which left it listed, a ghost, where it really
  stood.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.{Action, ActionQueue, Character, Spy}
  alias Instance.Character.Actions.{Gateway, Jump}
  alias Test.FleetScenario

  @owner 100

  setup do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid)
    FleetScenario.spawn_fake_galaxy(self(), instance_id: iid, edges: %{{10, 11} => 2, {11, 10} => 2, {11, 12} => 2})

    {_player, player_pid} =
      FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: @owner, faction: :phoenix)

    %{iid: iid, player: player_pid}
  end

  defp character(ctx, opts) do
    FleetScenario.build_character(
      Keyword.merge([instance_id: ctx.iid, character_id: 1, faction: :phoenix, owner_id: @owner, system: 10], opts)
    )
  end

  defp with_queue(character, actions, vp) do
    %{character | actions: %{ActionQueue.replace_queue(actions) | virtual_position: vp}}
  end

  defp jump(source, target, opts \\ []),
    do: FleetScenario.build_action(:jump, %{"source" => source, "target" => target}, opts)

  describe "a spy discovered by its own infiltration/sabotage/assassination" do
    test "is left standing where it is, with an empty queue", ctx do
      # Infiltrate.finish runs with the finished action already popped: the
      # head is the NEXT order, a jump out of the system
      spy = %{character(ctx, type: :spy) | spy: Spy.new()}
      spy = with_queue(spy, [jump(10, 11)], 11)

      {spy, became_discovered?} = Character.lose_cover(spy, 20)

      assert became_discovered?
      assert Queue.to_list(spy.actions.queue) == []
      assert spy.actions.virtual_position == 10
    end
  end

  describe "a gateway charge aborted by the government" do
    test "stands down where it is: queue cleared, position reset", ctx do
      charge =
        FleetScenario.build_action(:gateway_charge, %{"source" => 10, "target" => 20},
          started_at: Instance.Time.Time.now(0)
        )

      follow_up = FleetScenario.build_action(:raid, %{"target" => 20})
      admiral = with_queue(character(ctx, action_status: :gateway_charging), [charge, follow_up], 20)

      assert {:aborted, aborted} = Gateway.abort_charge(admiral)

      assert aborted.action_status == :idle
      # the follow-up was premised on arriving on the far side
      assert Queue.to_list(aborted.actions.queue) == []
      assert aborted.actions.virtual_position == 10
    end
  end

  describe "clearing every order" do
    test "clear_actions_after(0) leaves the position on the character's system", ctx do
      admiral = with_queue(character(ctx, []), [jump(10, 11)], 11)

      cleared = Character.clear_actions_after(admiral, 0)

      assert Queue.to_list(cleared.actions.queue) == []
      assert cleared.actions.virtual_position == 10
    end

    test "through the agent: the next order validates from where the agent stands", ctx do
      {_c, pid} =
        FleetScenario.spawn_real_character(self(),
          instance_id: ctx.iid,
          character_id: 1,
          faction: :phoenix,
          owner_id: @owner,
          system: 10,
          virtual_position: 10
        )

      :ok =
        Game.call(
          ctx.iid,
          :character,
          1,
          {:add_actions, [%{"type" => "jump", "data" => %{"source" => 10, "target" => 11}}]}
        )

      :ok = GenServer.call(pid, {:clear_actions, 0})

      assert :ok =
               Game.call(
                 ctx.iid,
                 :character,
                 1,
                 {:add_actions, [%{"type" => "jump", "data" => %{"source" => 10, "target" => 11}}]}
               )
    end

    test "Character.fix repairs an IDLE character with no position too", ctx do
      broken = with_queue(character(ctx, []), [], nil)

      assert {:fixed, fixed} = Character.fix(broken, [])
      assert fixed.actions.virtual_position == 10
    end
  end

  describe "a jump from a system the character is not in" do
    # a spy: Jump.start skips the spatial index for non-admirals
    setup ctx do
      listed = FleetScenario.build_system_character(character_id: 1, faction: :phoenix, owner_id: @owner, type: :spy)

      {_s, s10} =
        FleetScenario.spawn_fake_stellar_system(self(), instance_id: ctx.iid, system_id: 10, characters: [listed])

      {_s, s11} = FleetScenario.spawn_fake_stellar_system(self(), instance_id: ctx.iid, system_id: 11, characters: [])
      %{s10: s10, s11: s11}
    end

    defp listed_in(pid), do: :sys.get_state(pid).characters |> Enum.map(& &1.id)

    test "is refused: queue cleared, position reset, the character stays where it is", ctx do
      # stale queue: says it leaves 11; the character stands (and is listed) in 10
      [head | _] = queue = [jump(11, 12, started_at: Instance.Time.Time.now(0)), jump(12, 11)]
      spy = with_queue(character(ctx, type: :spy), queue, 11)

      {_change, _notifs, result} = Jump.start(spy, head)

      assert result.system == 10
      assert result.action_status == :idle
      assert Queue.to_list(result.actions.queue) == []
      assert result.actions.virtual_position == 10
      # no ghost: still listed exactly where it still is
      assert listed_in(ctx.s10) == [1]
    end

    test "a consistent jump still leaves its source", ctx do
      [head | _] = queue = [jump(10, 11, started_at: Instance.Time.Time.now(0))]
      spy = with_queue(character(ctx, type: :spy), queue, 11)

      {_change, _notifs, result} = Jump.start(spy, head)

      assert result.system == nil
      assert result.action_status == :moving
      assert [%Action{type: :jump}] = Queue.to_list(result.actions.queue)
      assert listed_in(ctx.s10) == []
    end
  end
end
