defmodule Data.PickerTest do
  use ExUnit.Case, async: true

  describe "all/1" do
    test "loads the place list trimmed, non-empty, and internally unique" do
      names = Data.Picker.all("place")

      assert length(names) > 0
      assert Enum.all?(names, fn n -> n == String.trim(n) and n != "" end)
      assert length(names) == length(Enum.uniq(names))
    end

    test "the place list covers a 10,000-system galaxy without overflow suffixes" do
      assert length(Data.Picker.all("place")) >= 10_000
    end

    test "no place name ends in a roman-numeral token (reserved for stellar bodies)" do
      romans = ~w(I II III IV V VI VII VIII IX X)

      colliding =
        Data.Picker.all("place")
        |> Enum.filter(fn n -> String.upcase(List.last(String.split(n, " "))) in romans end)

      assert colliding == []
    end
  end

  describe "extend_unique/2" do
    test "first pass is the shuffled list itself" do
      assert Data.Picker.extend_unique(~w(a b c), 3) == ~w(a b c)
    end

    test "overflow passes cycle the list with numeric generation suffixes" do
      assert Data.Picker.extend_unique(~w(a b c), 8) ==
               ["a", "b", "c", "a 2", "b 2", "c 2", "a 3", "b 3"]
    end

    test "deep overflow stays unique" do
      names = Data.Picker.extend_unique(~w(a b), 60)

      assert length(names) == 60
      assert length(Enum.uniq(names)) == 60
      assert List.last(names) == "b 30"
    end
  end
end
