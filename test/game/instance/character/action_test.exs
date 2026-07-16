defmodule Character.ActionTest do
  use ExUnit.Case, async: true
  alias Instance.Character.Action

  doctest Action, import: true

  describe "compute_progress/2" do
    test "returns 0.0 when started_at is nil" do
      progress =
        %Action{
          data: %{},
          remaining_time: 1000,
          started_at: nil,
          total_time: 1000,
          cumulated_pauses: 0,
          type: :jump
        }
        |> Action.compute_progress(120)
        |> Float.round(2)

      assert progress == 0.0
    end

    test "returns 0.0 at action start (no wall-clock elapsed)" do
      progress =
        %Action{
          data: %{},
          remaining_time: 1000,
          started_at: Instance.Time.Time.now(),
          total_time: 1000,
          cumulated_pauses: 0,
          type: :jump
        }
        |> Action.compute_progress(120)
        |> Float.round(2)

      assert progress == 0.0
    end

    test "returns 1.0 once remaining_time hits 0" do
      progress =
        %Action{
          data: %{},
          remaining_time: 0,
          started_at: Instance.Time.Time.now(),
          total_time: 1000,
          cumulated_pauses: 0,
          type: :jump
        }
        |> Action.compute_progress(120)
        |> Float.round(2)

      assert progress == 1.0
    end

    test "advances with elapsed wall-clock at speed factor" do
      # 60s of real-clock at factor 120 → 60_000 * 120 / 180_000_000 = 0.04
      progress =
        %Action{
          data: %{},
          remaining_time: 500,
          started_at: Instance.Time.Time.now() - 60_000,
          total_time: 1000,
          cumulated_pauses: 0,
          type: :jump
        }
        |> Action.compute_progress(120)
        |> Float.round(2)

      assert progress == 0.04

      # Same elapsed wall-clock, factor 12 → 1/10 the progress
      progress =
        %Action{
          data: %{},
          remaining_time: 500,
          started_at: Instance.Time.Time.now() - 60_000,
          total_time: 1000,
          cumulated_pauses: 0,
          type: :jump
        }
        |> Action.compute_progress(12)
        |> Float.round(3)

      assert progress == 0.004
    end
  end

  describe "rebase_started_at/3 — engine pause/resume + post-restart migration" do
    test "leaves a not-yet-started action alone" do
      action = %Action{
        data: %{},
        remaining_time: 1000,
        started_at: nil,
        total_time: 1000,
        cumulated_pauses: nil,
        type: :jump
      }

      assert Action.rebase_started_at(action, 1, 0) == action
    end

    test "rebases so compute_progress reads the same fraction as (total - remaining) / total" do
      # An action that's 30% game-time done, originally started in a
      # different monotonic frame (very negative — simulates pre-deploy).
      action = %Action{
        data: %{},
        remaining_time: 700,
        started_at: -575_705_439_456,
        total_time: 1000,
        cumulated_pauses: -700_000_000,
        type: :jump
      }

      rebased = Action.rebase_started_at(action, 1, 0)

      # Same struct otherwise — only `started_at` and `cumulated_pauses` change.
      assert rebased.remaining_time == 700
      assert rebased.total_time == 1000
      assert rebased.cumulated_pauses == 0

      # `compute_progress` on the rebased action should give the same
      # fraction as remaining-time math: (1000-700)/1000 = 0.30.
      progress = Action.compute_progress(rebased, 1) |> Float.round(2)
      assert progress == 0.30
    end

    test "factor scales the rebase: higher factor → less wall-clock elapsed to account for" do
      action_template = %Action{
        data: %{},
        remaining_time: 500,
        started_at: -12345,
        total_time: 1000,
        cumulated_pauses: nil,
        type: :jump
      }

      slow_rebased = Action.rebase_started_at(action_template, 1, 0)
      fast_rebased = Action.rebase_started_at(action_template, 120, 0)

      # Both should round-trip to 50% progress under their own factors.
      assert Action.compute_progress(slow_rebased, 1) |> Float.round(2) == 0.50
      assert Action.compute_progress(fast_rebased, 120) |> Float.round(2) == 0.50
    end

    test "0 remaining_time stays at 100% after rebase" do
      action = %Action{
        data: %{},
        remaining_time: 0,
        started_at: -42,
        total_time: 1000,
        cumulated_pauses: nil,
        type: :jump
      }

      rebased = Action.rebase_started_at(action, 1, 0)
      assert Action.compute_progress(rebased, 1) == 1.0
    end

    # 2026-06-15 regression: a half-stamped infiltrate (started_at set by
    # process_next_action, but total_time/remaining_time still :unknown_yet
    # because ActionImpl.start hasn't resolved the duration) used to raise
    # ArithmeticError here, crashing Character.Agent's :start for the whole
    # agent on every restart/resume/deploy. Such actions must be a no-op.
    test "leaves an :unknown_yet action untouched even when started_at is set" do
      action = %Action{
        data: %{"target" => 426},
        remaining_time: :unknown_yet,
        started_at: -575_663_775_181,
        total_time: :unknown_yet,
        cumulated_pauses: -758_214_684,
        type: :infiltrate
      }

      assert Action.rebase_started_at(action, 1, 0) == action
      # And the realistic call path (factor from a real speed) must not raise.
      assert Action.rebase_started_at(action, 120, -758_214_684) == action
    end

    test "leaves an action untouched if only one of total/remaining is resolved" do
      action = %Action{
        data: %{},
        remaining_time: :unknown_yet,
        started_at: -100,
        total_time: 50.0,
        cumulated_pauses: 0,
        type: :infiltrate
      }

      assert Action.rebase_started_at(action, 1, 0) == action
    end
  end
end
