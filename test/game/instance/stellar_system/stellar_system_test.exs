defmodule Instance.StellarSystem.StellarSystemTest do
  use ExUnit.Case, async: true

  alias Instance.StellarSystem.StellarSystem
  alias Instance.StellarSystem.Character, as: SystemCharacter
  alias Instance.Character.Character

  # struct/2 bypasses the enforce: true keys we don't touch — push_character
  # only reads/writes :characters and calls SystemCharacter.convert/1.
  defp state(characters), do: struct(StellarSystem, characters: characters)

  defp incoming(id),
    do: struct(Character, id: id, type: :admiral, name: "c#{id}", level: 1, owner: nil, protection: 0, determination: 0, spy: nil)

  defp entry(id), do: struct(SystemCharacter, id: id)
  defp ids(%{characters: cs}), do: Enum.map(cs, & &1.id)

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
end
