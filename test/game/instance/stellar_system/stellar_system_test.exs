defmodule Instance.StellarSystem.StellarSystemTest do
  use ExUnit.Case, async: true

  alias Instance.StellarSystem.StellarSystem
  alias Instance.StellarSystem.Character, as: SystemCharacter
  alias Instance.Character.Character

  # struct/2 bypasses the enforce: true keys we don't touch — push_character
  # only reads/writes :characters and calls SystemCharacter.convert/1.
  defp state(characters), do: struct(StellarSystem, characters: characters)

  defp incoming(id),
    do:
      struct(Character,
        id: id,
        type: :admiral,
        name: "c#{id}",
        level: 1,
        owner: nil,
        protection: 0,
        determination: 0,
        spy: nil
      )

  defp entry(id), do: struct(SystemCharacter, id: id)
  defp ids(%{characters: cs}), do: Enum.map(cs, & &1.id)

  # `damage_fun` stubs for apply_building_damage/3 — they stand in for
  # `damage_tile/1` so the count boundary is exercised without the
  # Data.Querier/`:rand` machinery a real tile-damage roll needs. `state` is an
  # opaque token threaded through untouched.
  defp always_damage(refund \\ 0), do: fn s -> {:damaged, s, refund} end
  defp never_damage, do: fn s -> {:nothing_to_damage, s, 0} end

  describe "push_character/3 :on_board is idempotent by character id" do
    test "adds a character to an empty system" do
      {:ok, s} = StellarSystem.push_character(state([]), incoming(62), :on_board)
      assert ids(s) == [62]
    end

    test "re-pushing the same character does not create a duplicate" do
      {:ok, s} = StellarSystem.push_character(state([entry(62)]), incoming(62), :on_board)
      assert ids(s) == [62]
    end

    test "collapses pre-existing duplicates of the pushed id into one" do
      start = state([entry(62), entry(62), entry(99)])
      {:ok, s} = StellarSystem.push_character(start, incoming(62), :on_board)
      assert Enum.count(ids(s), &(&1 == 62)) == 1
      assert 99 in ids(s)
    end

    test "leaves other occupants untouched" do
      {:ok, s} = StellarSystem.push_character(state([entry(99)]), incoming(62), :on_board)
      assert Enum.sort(ids(s)) == [62, 99]
    end
  end

  describe "apply_building_damage/3 damage count" do
    test "a count of 0 damages nothing (Elixir-1.17 descending-range regression)" do
      # The bug this guards: an implicit-step `1..0` is the *descending* range
      # `[1, 0]`, so the loop ran twice and damaged 2 buildings on every
      # outcome whose table count is 0 — raid/conquest critical-failure, loot
      # failures, and the death/flee `{:release_siege, 0, 0}` release. Reverting
      # `1..count//1` back to `1..count` makes this assert 2 and fail.
      {_state, damaged, _refund} = StellarSystem.apply_building_damage(:state, 0, always_damage())
      assert damaged == 0
    end

    test "a count of N damages exactly N when tiles are available" do
      # Spanning the real table values: raid 1/5/6, loot 1/2, conquest 2/6.
      for n <- [1, 2, 5, 6] do
        {_state, damaged, _refund} = StellarSystem.apply_building_damage(:state, n, always_damage())
        assert damaged == n, "count #{n} should damage #{n} buildings, got #{damaged}"
      end
    end

    test "stops short when there is nothing left to damage" do
      {_state, damaged, _refund} = StellarSystem.apply_building_damage(:state, 5, never_damage())
      assert damaged == 0
    end

    test "accumulates cancelled-upgrade refunds across hits" do
      {_state, damaged, refund} = StellarSystem.apply_building_damage(:state, 3, always_damage(10))
      assert damaged == 3
      assert refund == 30
    end
  end
end
