defmodule Daily.RotationTest do
  @moduledoc """
  Pins the daily rotation boundary: the active date flips at 07:00 UTC,
  not midnight, so every "today" surface (boot, API, blast scheduler,
  SPA countdown) agrees on which puzzle is live.
  """

  use ExUnit.Case, async: true

  test "rotation hour is 07:00 UTC" do
    assert Daily.rotation_hour_utc() == 7
  end

  test "before 07:00 UTC the previous calendar date is still active" do
    assert Daily.today(~U[2026-08-03 00:00:00Z]) == ~D[2026-08-02]
    assert Daily.today(~U[2026-08-03 06:59:59Z]) == ~D[2026-08-02]
  end

  test "at and after 07:00 UTC the current calendar date is active" do
    assert Daily.today(~U[2026-08-03 07:00:00Z]) == ~D[2026-08-03]
    assert Daily.today(~U[2026-08-03 23:59:59Z]) == ~D[2026-08-03]
  end

  test "month and year boundaries shift cleanly" do
    assert Daily.today(~U[2026-09-01 03:00:00Z]) == ~D[2026-08-31]
    assert Daily.today(~U[2027-01-01 06:59:00Z]) == ~D[2026-12-31]
  end
end
