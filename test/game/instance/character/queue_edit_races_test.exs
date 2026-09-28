defmodule Character.QueueEditRacesTest do
  @moduledoc """
  Player edits to a character's action queue that land while the queue is
  LOCKED — i.e. while the action orchestrator is running a start/finish
  hook for the head action — and malformed clear indices.

  How the lock works: when the head action is due, the character tick
  pushes a `:locked` pseudo-action at the head and casts the hook, with a
  copy of the character, to the orchestrator. The orchestrator runs the
  hook and calls `{:done, hook, character}` back, which REPLACES the
  agent's state with its copy.

  These scenarios reproduce that window deterministically: the agent is
  never started (no ticks), `{:update_state, locked}` installs the locked
  queue, the player edit is applied, then `{:done, ...}` delivers the
  orchestrator's copy.

  The contract: an edit is never acknowledged and then silently undone.
  While the queue is locked, edits are refused with `:agent_busy` (the
  channel retries for up to 3 s, see `Portal.Channels.BusyRetry`); a
  cancel names the last action to keep by uid, so it means the same thing
  even if the head finished before the server applied it.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.ActionQueue
  alias Test.FleetScenario

  # 10 — 11 — 12
  setup do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid)

    FleetScenario.spawn_fake_galaxy(self(),
      instance_id: iid,
      edges: %{{10, 11} => 2, {11, 10} => 2, {11, 12} => 2, {12, 11} => 2}
    )

    {_player, player_pid} = FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 100, faction: :phoenix)

    {character, pid} =
      FleetScenario.spawn_real_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :phoenix,
        owner_id: 100,
        system: 10,
        has_ships?: false,
        virtual_position: 10
      )

    # {:done} re-arms the tick from the agent clock; an agent that was
    # never started has none
    :sys.replace_state(pid, fn st -> %{st | tick: %{st.tick | cumulated_pauses: 0, factor: 1}} end)

    %{iid: iid, player: player_pid, character: character, pid: pid}
  end

  # A head jump 10 → 11 already under way (far from finishing), so the
  # orchestrator's copy is "the head just started".
  defp head_jump,
    do: jump_action(10, 11, started_at: Instance.Time.Time.now(0), total_time: 1_000, remaining_time: 1_000)

  # build_action/3 makes uid-less actions (like pre-uid snapshots); give
  # these the uid Action.new/1 would
  defp jump_action(source, target, opts \\ []) do
    action = FleetScenario.build_action(:jump, %{"source" => source, "target" => target}, opts)
    %{action | uid: System.unique_integer([:positive])}
  end

  defp with_queue(character, actions), do: %{character | actions: ActionQueue.replace_queue(actions)}

  defp lock(character), do: %{character | actions: ActionQueue.lock(character.actions)}

  defp install(ctx, character), do: GenServer.cast(ctx.pid, {:update_state, character})

  defp live(ctx) do
    {:ok, character} = Game.call(ctx.iid, :character, 1, :get_state)
    character
  end

  defp route(character) do
    character.actions.queue
    |> Queue.to_list()
    |> Enum.map(fn a -> {a.type, a.data["source"], a.data["target"]} end)
  end

  defp clear(ctx, spec), do: GenServer.call(ctx.pid, {:clear_actions, spec})

  defp uids(character), do: character.actions.queue |> Queue.to_list() |> Enum.map(&Instance.Character.Action.uid/1)

  describe "an edit landing while the orchestrator holds the lock" do
    test "add_actions is refused as busy (not acknowledged then lost), and works once the lock is gone", ctx do
      copy = with_queue(ctx.character, [head_jump()])
      install(ctx, lock(copy))

      assert {:error, :agent_busy} = Game.call(ctx.iid, :character, 1, {:add_actions, [jump_payload(11, 12)]})
      assert FleetScenario.get_character_updates(ctx.player) == []

      :ok = GenServer.call(ctx.pid, {:done, :start, copy})

      assert :ok = Game.call(ctx.iid, :character, 1, {:add_actions, [jump_payload(11, 12)]})
      assert route(live(ctx)) == [{:jump, 10, 11}, {:jump, 11, 12}]
    end

    test "a clear is refused as busy and changes nothing", ctx do
      copy = with_queue(ctx.character, [head_jump(), jump_action(11, 12), jump_action(12, 11)])
      install(ctx, lock(copy))

      assert {:error, :agent_busy} = clear(ctx, 2)
      assert {:error, :agent_busy} = clear(ctx, {:keep_uid, hd(uids(copy))})
      # the lock is still at the head, untouched: nothing was cut from under it
      assert [{:locked, nil, nil} | _] = route(live(ctx))
      assert live(ctx).actions.virtual_position == 11

      :ok = GenServer.call(ctx.pid, {:done, :start, copy})
      assert :ok = clear(ctx, 2)
      assert route(live(ctx)) == [{:jump, 10, 11}, {:jump, 11, 12}]
    end
  end

  describe "cancel by uid" do
    test "keeps through the named action even if the head finished in between", ctx do
      [a, b, c, d] = [head_jump(), jump_action(11, 12), jump_action(12, 11), jump_action(11, 12)]
      # the client rendered [a, b, c, d] and clicked c: keep through b
      keep = Instance.Character.Action.uid(b)
      # ...meanwhile a finished
      install(ctx, with_queue(ctx.character, [b, c, d]))

      assert :ok = clear(ctx, {:keep_uid, keep})
      assert route(live(ctx)) == [{:jump, 11, 12}]
      assert live(ctx).actions.virtual_position == 12
      refute Enum.any?(uids(live(ctx)), &(&1 in [Instance.Character.Action.uid(a), Instance.Character.Action.uid(c)]))
    end

    test "a uid that is no longer queued is refused as stale and changes nothing", ctx do
      [a, b] = [head_jump(), jump_action(11, 12)]
      install(ctx, with_queue(ctx.character, [b]))

      assert {:error, :stale_queue} = clear(ctx, {:keep_uid, Instance.Character.Action.uid(a)})
      assert route(live(ctx)) == [{:jump, 11, 12}]
    end

    test "every queued action gets a distinct uid", ctx do
      assert :ok =
               Game.call(
                 ctx.iid,
                 :character,
                 1,
                 {:add_actions, [jump_payload(10, 11), jump_payload(11, 12), jump_payload(12, 11)]}
               )

      ids = uids(live(ctx))
      assert Enum.all?(ids, &is_integer/1)
      assert length(Enum.uniq(ids)) == 3
    end

    test "actions restored from a snapshot without uids can still be cleared by index", ctx do
      legacy = Map.delete(jump_action(11, 12), :uid)
      install(ctx, with_queue(ctx.character, [head_jump(), legacy]))

      assert :ok = clear(ctx, 1)
      assert route(live(ctx)) == [{:jump, 10, 11}]
    end
  end

  describe "malformed clear requests" do
    test "a negative index is refused and never drops the running head", ctx do
      install(ctx, with_queue(ctx.character, [head_jump(), jump_action(11, 12), jump_action(12, 11)]))

      assert {:error, :invalid_payload} = clear(ctx, -1)
      assert route(live(ctx)) == [{:jump, 10, 11}, {:jump, 11, 12}, {:jump, 12, 11}]
    end

    test "a non-integer index is refused without crashing the character agent", ctx do
      install(ctx, with_queue(ctx.character, [head_jump(), jump_action(11, 12)]))

      assert {:error, :invalid_payload} = clear(ctx, "1")
      assert {:error, :invalid_payload} = clear(ctx, {:keep_uid, "1"})
      assert Process.alive?(ctx.pid)
      assert route(live(ctx)) == [{:jump, 10, 11}, {:jump, 11, 12}]
    end
  end

  defp jump_payload(source, target), do: %{"type" => "jump", "data" => %{"source" => source, "target" => target}}
end
