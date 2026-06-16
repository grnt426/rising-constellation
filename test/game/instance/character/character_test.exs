defmodule Character.CharacterTest do
  use ExUnit.Case, async: true
  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character
  alias Spatial.Position

  describe "get_position/2 — action_status: :moving with degenerate head" do
    test "returns last-known position when queue is empty" do
      character = moving_character(queue: [])
      assert {%Position{x: 10.0, y: 20.0}, 0} == Character.get_position(character, :unused)
    end

    test "returns last-known position when head action has not started" do
      action = %Action{
        type: :jump,
        data: %{"source_position" => %Position{x: 0.0, y: 0.0}, "target_position" => %Position{x: 100.0, y: 0.0}},
        total_time: 10,
        remaining_time: 10,
        started_at: nil,
        cumulated_pauses: nil
      }

      character = moving_character(queue: [action])
      assert {%Position{x: 10.0, y: 20.0}, 0} == Character.get_position(character, :unused)
    end

    test "returns last-known position when head action is a started infiltrate (Challor 2026-06-14)" do
      # Repro of the bug: Jump.finish failed to call enter_system, the next action
      # took the head, and Action.start stamped started_at on it. action_status
      # was left at :moving. get_position must not crash on the missing
      # source_position/target_position keys.
      action = %Action{
        type: :infiltrate,
        data: %{"target" => 426},
        total_time: :unknown_yet,
        remaining_time: :unknown_yet,
        started_at: -575_703_518_040,
        cumulated_pauses: -755_602_990
      }

      character = moving_character(queue: [action])
      assert {%Position{x: 10.0, y: 20.0}, 0} == Character.get_position(character, :unused)
    end
  end

  describe "next_tick/3 recovers a stale-locked character (lost orchestrator round-trip)" do
    test "a legacy/stale :locked head drops the wedged queue and idles in the current system" do
      # The exact prod wedge (2026-06-16): orchestrator never delivered {:done},
      # so a :locked head sits in front of a half-stamped action forever. A lock
      # with no timestamp is treated as stale; recovery drops the queue and idles.
      lock = Action.new({:locked, %{lock: true}, 100})
      wedged = Action.new({:infiltrate, %{"target" => 5}, :unknown_yet})

      character =
        moving_character(
          queue: [lock, wedged],
          type: :admiral,
          system: 5,
          action_status: :infiltration,
          virtual_position: 5
        )

      {_change, _notifs, recovered} = Character.next_tick(character, 1, 0)

      assert recovered.action_status == :idle
      assert ActionQueue.empty?(recovered.actions)
      assert recovered.actions.virtual_position == 5
      assert recovered.system == 5
    end

    test "a fresh :locked head is left alone (does not abort a live action)" do
      lock = %{Action.new({:locked, %{lock: true}, 100}) | started_at: Instance.Time.Time.now(0)}

      character =
        moving_character(queue: [lock], type: :admiral, system: 5, action_status: :infiltration, virtual_position: 5)

      {_change, _notifs, after_tick} = Character.next_tick(character, 1, 0)

      # Still locked, still mid-action — the orchestrator round-trip is in flight.
      assert after_tick.action_status == :infiltration
      assert match?(%Action{type: :locked}, Queue.peek(after_tick.actions.queue))
    end
  end

  describe "start-hook failure recovery: abort_action/1 |> idle/1 (no re-queue, no loop)" do
    # This is what the orchestrator now does when a :start hook raises (e.g.
    # Infiltrate.start MatchErrors because system is nil). The OLD behavior
    # re-queued the action, producing the infinite orchestrator-pegging loop
    # (2026-06-16). Aborting must DROP the failed action, not retain/re-add it.
    test "drops the failed head action and idles, preserving any following actions" do
      failed = Action.new({:infiltrate, %{"target" => 5}, :unknown_yet})
      following = Action.new({:jump, %{"source" => 5, "target" => 6}, 10})

      character =
        moving_character(queue: [failed, following], system: 5, action_status: :infiltration, virtual_position: 5)

      recovered = character |> Character.abort_action() |> Character.idle()

      items = Queue.to_list(recovered.actions.queue)
      assert recovered.action_status == :idle
      assert length(items) == 1
      assert hd(items).type == :jump
    end

    test "drops the only action and idles to an empty queue (terminal, not retried)" do
      failed = Action.new({:infiltrate, %{"target" => 5}, :unknown_yet})
      character = moving_character(queue: [failed], system: 5, action_status: :infiltration, virtual_position: 5)

      recovered = character |> Character.abort_action() |> Character.idle()

      assert recovered.action_status == :idle
      assert ActionQueue.empty?(recovered.actions)
    end
  end

  defp moving_character(opts) do
    queue =
      opts
      |> Keyword.fetch!(:queue)
      |> Enum.reduce(Queue.new(), fn a, q -> Queue.insert(q, a) end)

    %Character{
      id: 1,
      status: :on_board,
      type: Keyword.get(opts, :type, :spy),
      specialization: nil,
      second_specialization: nil,
      skills: [],
      age: 30,
      culture: nil,
      name: "Test",
      gender: nil,
      illustration: nil,
      level: 1,
      experience: nil,
      protection: 0,
      determination: 0,
      credit_cost: 0,
      technology_cost: 0,
      ideology_cost: 0,
      owner: nil,
      on_sold: false,
      system: Keyword.get(opts, :system, nil),
      position: %Position{x: 10.0, y: 20.0},
      actions: %ActionQueue{virtual_position: Keyword.get(opts, :virtual_position, 426), queue: queue},
      action_status: Keyword.get(opts, :action_status, :moving),
      on_strike: false,
      army: nil,
      spy: nil,
      speaker: nil,
      instance_id: 0
    }
  end
end
