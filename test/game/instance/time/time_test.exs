defmodule Instance.Time.TimeTest do
  use ExUnit.Case, async: true

  alias Instance.Time.Time

  # Build a Time state with the given speed in the running phase, primed near
  # the per-speed autosave threshold. The threshold itself is private; we
  # cross it by passing a large `elapsed_time` to `next_tick/2` and assert
  # that `next_autosave.value` resets to 0 — proof that the autosave branch
  # fired. Pre-fix this only happened for :slow.
  defp running_time(speed) do
    # day_factor is irrelevant to the autosave bookkeeping; pass any value.
    %Time{Time.new(0, 1, speed, -1) | is_running: true}
  end

  describe "next_tick autosave generalization" do
    test "fires autosave for :fast (regression for :slow-only guard)" do
      state = running_time(:fast)
      # ~15 wall-clock minutes at fast factor=120 ≈ 600 game-time units.
      {_, after_tick} = Time.next_tick(state, 1000)
      assert after_tick.next_autosave.value == 0.0
    end

    test "fires autosave for :medium" do
      state = running_time(:medium)
      {_, after_tick} = Time.next_tick(state, 200)
      assert after_tick.next_autosave.value == 0.0
    end

    test "fires autosave for :slow at its threshold" do
      state = running_time(:slow)
      {_, after_tick} = Time.next_tick(state, 10)
      assert after_tick.next_autosave.value == 0.0
    end

    test "does not fire autosave below the threshold" do
      state = running_time(:fast)
      {_, after_tick} = Time.next_tick(state, 1)
      assert after_tick.next_autosave.value > 0
      assert after_tick.next_autosave.value < 600
    end

    test "does not fire autosave when not running" do
      state = %Time{running_time(:fast) | is_running: false}
      {_, after_tick} = Time.next_tick(state, 1000)
      # The clause for non-running state leaves next_autosave untouched.
      assert after_tick.next_autosave.value == state.next_autosave.value
    end
  end
end
