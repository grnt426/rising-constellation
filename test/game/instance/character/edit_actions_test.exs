defmodule Character.EditActionsTest do
  @moduledoc """
  `{:edit_actions, keep_uid, tail}` — the "edit the plan" operation behind
  mid-queue cancels and stop reordering: keep the queue through the action
  with `keep_uid` (never less than the running head), replace the rest with
  a freshly validated `tail`, all or nothing.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.{Action, ActionQueue, Character, Speaker}
  alias Test.FleetScenario

  #   10 — 11 — 12 — 13
  #         \_________/      (11 — 13 is a shortcut)
  @edges %{
    {10, 11} => 2,
    {11, 10} => 2,
    {11, 12} => 2,
    {12, 11} => 2,
    {12, 13} => 2,
    {13, 12} => 2,
    {11, 13} => 3,
    {13, 11} => 3
  }

  setup do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid)
    FleetScenario.spawn_fake_galaxy(self(), instance_id: iid, edges: @edges)
    {_player, player_pid} = FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 100, faction: :phoenix)
    %{iid: iid, player: player_pid}
  end

  defp agent(ctx, opts \\ []) do
    {character, pid} =
      FleetScenario.spawn_real_character(
        self(),
        Keyword.merge(
          [instance_id: ctx.iid, character_id: 1, faction: :phoenix, owner_id: 100, system: 10, virtual_position: 10],
          opts
        )
      )

    %{character: character, pid: pid}
  end

  defp jump(source, target), do: %{"type" => "jump", "data" => %{"source" => source, "target" => target}}
  defp action(type, target), do: %{"type" => type, "data" => %{"target" => target}}
  defp carry(payload, %Action{} = action), do: Map.put(payload, "uid", Action.uid(action))

  defp add!(ctx, payloads), do: :ok = Game.call(ctx.iid, :character, 1, {:add_actions, payloads})
  defp edit(ctx, keep_uid, tail), do: Game.call(ctx.iid, :character, 1, {:edit_actions, keep_uid, tail})

  defp live(ctx) do
    {:ok, character} = Game.call(ctx.iid, :character, 1, :get_state)
    character
  end

  defp queue(ctx), do: Queue.to_list(live(ctx).actions.queue)
  defp plan(ctx), do: Enum.map(queue(ctx), &{&1.type, &1.data["source"], &1.data["target"]})

  describe "replacing the plan after the kept prefix" do
    test "removing a stop reroutes the rest (the new route may pass the old stop)", ctx do
      agent(ctx)
      # stops: 11, 12, 13
      add!(ctx, [jump(10, 11), jump(11, 12), jump(12, 13)])
      [head | _] = queue(ctx)

      # drop stop 12: route 11 → 13 via the shortcut
      assert :ok = edit(ctx, Action.uid(head), [jump(11, 13)])
      assert plan(ctx) == [{:jump, 10, 11}, {:jump, 11, 13}]
      assert live(ctx).actions.virtual_position == 13
      assert [_ | _] = FleetScenario.get_character_updates(ctx.player)
    end

    test "the kept prefix is untouched: same actions, same uids", ctx do
      agent(ctx)
      add!(ctx, [jump(10, 11), jump(11, 12), jump(12, 13)])
      [a, b, _c] = queue(ctx)

      assert :ok = edit(ctx, Action.uid(b), [jump(12, 11)])
      assert [^a, ^b, new] = queue(ctx)
      assert {new.data["source"], new.data["target"]} == {12, 11}
    end

    test "re-sent actions keep their uid; new ones get a fresh one", ctx do
      agent(ctx)
      add!(ctx, [jump(10, 11), jump(11, 12), jump(12, 13)])
      [a, b, c] = queue(ctx)

      assert :ok = edit(ctx, Action.uid(a), [carry(jump(11, 12), b), jump(12, 11)])
      assert [^a, kept, fresh] = queue(ctx)
      assert Action.uid(kept) == Action.uid(b)
      refute Action.uid(fresh) in [Action.uid(a), Action.uid(b), Action.uid(c)]
    end

    test "a carried uid on a different action is ignored (fresh uid)", ctx do
      agent(ctx)
      add!(ctx, [jump(10, 11), jump(11, 12), jump(12, 13)])
      [a, b, c] = queue(ctx)

      # c's uid, but a different target
      assert :ok = edit(ctx, Action.uid(a), [carry(jump(11, 13), c)])
      assert [^a, other] = queue(ctx)
      refute Action.uid(other) == Action.uid(c)
    end

    test "an empty tail cancels everything after the kept action", ctx do
      agent(ctx)
      add!(ctx, [jump(10, 11), jump(11, 12), jump(12, 13)])
      [a | _] = queue(ctx)

      assert :ok = edit(ctx, Action.uid(a), [])
      assert plan(ctx) == [{:jump, 10, 11}]
      assert live(ctx).actions.virtual_position == 11
    end
  end

  describe "refusals change nothing" do
    test "an invalid tail entry is refused with its index", ctx do
      agent(ctx)
      add!(ctx, [jump(10, 11), jump(11, 12)])
      [a, _] = before = queue(ctx)

      # 12 → 10 is not a lane
      assert {:error, {:invalid_jump, 1}} = edit(ctx, Action.uid(a), [jump(11, 12), jump(12, 10)])
      assert queue(ctx) == before
    end

    test "a tail that doesn't start where the prefix ends is refused", ctx do
      agent(ctx)
      add!(ctx, [jump(10, 11), jump(11, 12)])
      [a, _] = before = queue(ctx)

      assert {:error, {:invalid_position, 0}} = edit(ctx, Action.uid(a), [jump(12, 13)])
      assert queue(ctx) == before
    end

    test "an unknown keep_uid (already ran / replaced) is stale", ctx do
      agent(ctx)
      add!(ctx, [jump(10, 11), jump(11, 12)])
      before = queue(ctx)

      assert {:error, {:stale_queue, nil}} = edit(ctx, 424_242, [])
      assert queue(ctx) == before
    end

    test "while the orchestrator holds the lock: busy", ctx do
      %{pid: pid} = agent(ctx)
      add!(ctx, [jump(10, 11), jump(11, 12)])
      [a, _] = queue(ctx)
      locked = %{live(ctx) | actions: ActionQueue.lock(live(ctx).actions)}
      GenServer.cast(pid, {:update_state, locked})

      assert {:error, :agent_busy} = edit(ctx, Action.uid(a), [])
    end

    test "malformed payloads are refused without crashing the agent", ctx do
      %{pid: pid} = agent(ctx)
      add!(ctx, [jump(10, 11)])
      [a] = queue(ctx)

      assert {:error, {:invalid_payload, nil}} = edit(ctx, "1", [])
      assert {:error, {:invalid_payload, nil}} = edit(ctx, Action.uid(a), "nope")
      assert {:error, {_reason, 0}} = edit(ctx, Action.uid(a), [%{"type" => "jump"}])
      assert Process.alive?(pid)
    end
  end

  describe "queue length cap" do
    test "an edit may not grow the queue past the cap", ctx do
      agent(ctx)
      add!(ctx, [jump(10, 11)])
      [a] = queue(ctx)
      cap = Character.max_queue_length()

      pingpong = for i <- 1..cap, do: if(rem(i, 2) == 1, do: jump(11, 12), else: jump(12, 11))
      assert {:error, {:queue_too_long, nil}} = edit(ctx, Action.uid(a), pingpong)
      assert :ok = edit(ctx, Action.uid(a), Enum.take(pingpong, cap - 1))
      assert length(queue(ctx)) == cap
    end

    test "add_actions may not grow the queue past the cap either", ctx do
      agent(ctx)
      cap = Character.max_queue_length()
      pingpong = for i <- 1..cap, do: if(rem(i, 2) == 1, do: jump(10, 11), else: jump(11, 10))

      assert :ok = Game.call(ctx.iid, :character, 1, {:add_actions, pingpong})
      assert {:error, :queue_too_long} = Game.call(ctx.iid, :character, 1, {:add_actions, [jump(10, 11)]})
    end
  end

  describe "rules are applied to the edited plan, not the old one" do
    test "a re-sent conquest is not a duplicate of itself", ctx do
      agent(ctx, has_ships?: true)
      add!(ctx, [jump(10, 11), jump(11, 12), action("conquest", 12)])
      [a, b, conquest] = queue(ctx)

      # reroute 11 → 12 unchanged, keep the conquest
      assert :ok = edit(ctx, Action.uid(a), [carry(jump(11, 12), b), carry(action("conquest", 12), conquest)])
      assert [:jump, :jump, :conquest] = Enum.map(queue(ctx), & &1.type)
    end

    test "a Siderian cooling down can still reshape a plan it already had; new orders wait for the cooldown", ctx do
      %{pid: pid} = agent(ctx, type: :speaker)
      speaker = %{live(ctx) | speaker: Speaker.new()}
      GenServer.cast(pid, {:update_state, speaker})
      add!(ctx, [jump(10, 11), jump(11, 12), action("make_dominion", 12)])
      [a, _b, dominion] = queue(ctx)

      # a control attempt elsewhere put the Siderian on cooldown since
      GenServer.cast(pid, {:update_state, %{live(ctx) | speaker: Speaker.set_cooldown(live(ctx).speaker, 50)}})

      # reroute to 12 via 13 and keep the queued control: accepted
      reroute = [jump(11, 13), jump(13, 12), carry(action("make_dominion", 12), dominion)]
      assert :ok = edit(ctx, Action.uid(a), reroute)
      assert [:jump, :jump, :jump, :make_dominion] = Enum.map(queue(ctx), & &1.type)
      # the real cooldown is untouched
      assert Speaker.locked?(live(ctx).speaker)

      # a brand-new control is still refused while cooling down
      [a | _] = queue(ctx)

      assert {:error, {:locked_character, 2}} =
               edit(ctx, Action.uid(a), [jump(11, 13), jump(13, 12), action("make_dominion", 12)])
    end
  end
end
