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

  defp moving_character(opts) do
    queue =
      opts
      |> Keyword.fetch!(:queue)
      |> Enum.reduce(Queue.new(), fn a, q -> Queue.insert(q, a) end)

    %Character{
      id: 1,
      status: :on_board,
      type: :spy,
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
      system: nil,
      position: %Position{x: 10.0, y: 20.0},
      actions: %ActionQueue{virtual_position: 426, queue: queue},
      action_status: :moving,
      on_strike: false,
      army: nil,
      spy: nil,
      speaker: nil,
      instance_id: 0
    }
  end
end
