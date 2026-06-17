defmodule Character.Actions.JumpTest do
  use ExUnit.Case, async: true

  alias Instance.Character.Action
  alias Instance.Character.Actions.Jump
  alias Instance.Character.Character

  defp action,
    do: %Action{
      type: :jump,
      data: %{"source" => 4, "target" => 5},
      total_time: 5,
      remaining_time: 5,
      started_at: nil,
      cumulated_pauses: nil
    }

  describe "arrival_interception/2 — non-admirals have no army" do
    # 2026-06-17 RCA: the interception-on-arrival feature accessed
    # `character.army.reaction` unconditionally in Jump.finish. For spies and
    # speakers `army` is nil, so it KeyError-ed *after* enter_system, and the
    # orchestrator delivered the pre-finish character with system=nil —
    # stranding every spy/speaker jump-arrival. The gate must make it a no-op
    # for non-admirals without touching army.
    test "spy (army == nil) gets a no-op interception, no KeyError" do
      spy = struct(Character, %{id: 1, type: :spy, army: nil})
      assert {^spy, [], false} = Jump.arrival_interception(spy, action())
    end

    test "speaker (army == nil) gets a no-op interception, no KeyError" do
      speaker = struct(Character, %{id: 2, type: :speaker, army: nil})
      assert {^speaker, [], false} = Jump.arrival_interception(speaker, action())
    end
  end
end
