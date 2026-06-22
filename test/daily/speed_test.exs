defmodule Daily.SpeedTest do
  use ExUnit.Case, async: true

  # The daily challenge runs in a dedicated :daily speed. It must:
  #   * resolve to the same Legacy (:slow) content as a normal slow game —
  #     this is what makes "daily = Legacy except faster" true, and it relies
  #     on every speed-branching module's :slow spec being its fallback, so we
  #     lock that here;
  #   * carry a faster tick factor than :slow; and
  #   * be hidden from the scenario editor's speed picker.

  @speed_branching [
    Data.Game.Constant,
    Data.Game.Building,
    Data.Game.Patent,
    Data.Game.Doctrine,
    Data.Game.Ship
  ]

  test ":daily resolves to the same content as :slow for every speed-branching module" do
    for module <- @speed_branching do
      daily = Data.Querier.fetch_all(module, speed: :daily, mode: :prod)
      slow = Data.Querier.fetch_all(module, speed: :slow, mode: :prod)
      assert daily == slow, "#{inspect(module)} resolves differently for :daily vs :slow"
    end
  end

  test ":daily carries a fast tick factor, faster than :slow and at least :fast" do
    daily = Data.Querier.fetch_one(Data.Game.Speed, [], :daily)
    slow = Data.Querier.fetch_one(Data.Game.Speed, [], :slow)
    fast = Data.Querier.fetch_one(Data.Game.Speed, [], :fast)

    assert daily != nil
    assert daily.factor > slow.factor
    assert daily.factor >= fast.factor
  end

  test ":daily is hidden from the scenario editor, the three normal speeds are not" do
    assert Data.Querier.fetch_one(Data.Game.Speed, [], :daily).selectable == false

    for key <- [:fast, :medium, :slow] do
      assert Data.Querier.fetch_one(Data.Game.Speed, [], key).selectable == true
    end
  end
end
