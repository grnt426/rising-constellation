defmodule Character.ActionTest do
  use ExUnit.Case, async: true
  alias Instance.Character.Action

  doctest Action, import: true

  # `compute_progress/2` is now derived from `remaining_time / total_time`
  # instead of `(now - started_at)`. The previous clock-based formula broke
  # whenever an action outlived a BEAM restart (started_at captured from the
  # old BEAM's monotonic clock was compared against the new BEAM's clock,
  # producing nonsense — see action.ex docstring). The `factor` argument is
  # retained for call-site compatibility but ignored.
  test "compute_progress/2 returns 0.0 when started_at is nil" do
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

  test "compute_progress/2 returns 0.0 at action start (remaining_time == total_time)" do
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

  test "compute_progress/2 returns 1.0 at action end (remaining_time == 0)" do
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

  test "compute_progress/2 reflects the remaining_time / total_time ratio" do
    base = %Action{
      data: %{},
      started_at: Instance.Time.Time.now(),
      total_time: 1000,
      cumulated_pauses: 0,
      type: :jump
    }

    assert (%{base | remaining_time: 800} |> Action.compute_progress(120) |> Float.round(2)) == 0.20
    assert (%{base | remaining_time: 500} |> Action.compute_progress(120) |> Float.round(2)) == 0.50
    assert (%{base | remaining_time: 200} |> Action.compute_progress(120) |> Float.round(2)) == 0.80
    assert (%{base | remaining_time: 120} |> Action.compute_progress(120) |> Float.round(2)) == 0.88
  end

  test "compute_progress/2 ignores the speed factor argument" do
    action = %Action{
      data: %{},
      remaining_time: 500,
      started_at: Instance.Time.Time.now(),
      total_time: 1000,
      cumulated_pauses: 0,
      type: :jump
    }

    assert Action.compute_progress(action, 1) == Action.compute_progress(action, 120)
    assert Action.compute_progress(action, 120) == Action.compute_progress(action, 9999)
  end

  test "compute_progress/2 is stable against monotonic-time discontinuities" do
    # Simulates the post-deploy state: an action whose `started_at` was
    # captured from a now-defunct BEAM's monotonic clock. Under the old
    # clock-based formula this produced a wildly negative progress; the
    # new formula only reads in-struct fields and so is unaffected.
    action = %Action{
      data: %{},
      remaining_time: 300,
      started_at: -575_712_167_441,
      total_time: 1000,
      cumulated_pauses: -700_000_000,
      type: :jump
    }

    assert (action |> Action.compute_progress(1) |> Float.round(2)) == 0.70
  end
end
