defmodule Daily.HeadhunterTest do
  use ExUnit.Case, async: true

  alias Daily.Headhunter

  @date "2026-10-27"

  describe "the roster" do
    test "a 30-minute run sends one Erased every 15 seconds: 119" do
      assert Headhunter.interval_seconds() == 15
      assert Headhunter.total(30 * 60) == 119
      assert Headhunter.total() == 119
    end

    test "due/1 counts whole intervals and stops at the roster" do
      assert Headhunter.due(0.0) == 0
      assert Headhunter.due(14.9) == 0
      assert Headhunter.due(15.0) == 1
      assert Headhunter.due(44.0) == 2
      assert Headhunter.due(1785.0) == 119
      assert Headhunter.due(1800.0) == 119
      assert Headhunter.due(5000.0) == 119
    end

    test "a date's roster is the same every time, and differs from another date's" do
      roster = fn date -> for n <- 1..Headhunter.total(), do: Headhunter.recruit(date, n) end

      assert roster.(@date) == roster.(@date)
      assert roster.(@date) != roster.("2026-10-28")
    end

    test "the band opens at 1 to 3 and its average rises by 0.75 every 2 minutes" do
      # {lowest, highest} in each 2-minute window
      assert Headhunter.level_band(0) == {1, 3}
      assert Headhunter.level_band(119) == {1, 3}
      assert Headhunter.level_band(120) == {1, 4.5}
      assert Headhunter.level_band(4 * 60) == {1, 6}
      assert Headhunter.level_band(16 * 60) == {1, 15}
      assert Headhunter.level_band(28 * 60) == {1, 24}
      assert Headhunter.level_band(30 * 60 - 1) == {1, 24}

      for window <- 0..14 do
        {lowest, highest} = Headhunter.level_band(window * 120)
        assert (lowest + highest) / 2 == 2 + 0.75 * window
      end
    end

    test "every recruit is inside the band of its moment" do
      roster = for n <- 1..Headhunter.total(), do: Headhunter.recruit(@date, n)

      assert Enum.all?(roster, &(&1.evasion >= 0 and &1.evasion < 1))

      for recruit <- roster do
        {lowest, highest} = Headhunter.level_band(recruit.n * Headhunter.interval_seconds())
        assert recruit.level >= lowest and recruit.level <= ceil(highest)
      end

      # the first two minutes draw from 1 to 3
      assert roster |> Enum.take(7) |> Enum.all?(&(&1.level in 1..3))

      # a high level can turn up well before the average gets there, and
      # easy ones are still arriving at mid-run
      mid_run = Enum.filter(roster, &(&1.n in 40..64))
      assert Enum.any?(mid_run, &(&1.level >= 8))
      assert Enum.any?(mid_run, &(&1.level <= 3))

      mean = fn recruits -> Enum.sum(Enum.map(recruits, & &1.level)) / length(recruits) end
      thirds = Enum.chunk_every(roster, 40)
      assert thirds |> Enum.map(mean) |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)
      # by the end the band reaches well past level 10
      assert Enum.any?(roster, &(&1.level >= 15))
    end

    test "across many days, each window's average level is the band's" do
      dates = for day <- 1..200, do: Date.to_iso8601(Date.add(~D[2026-10-27], day))

      for window <- [0, 1, 6, 9, 14] do
        {lowest, highest} = Headhunter.level_band(window * 120)
        # arrivals 8w..8w+7 land in window w (the first interval is at 15 s)
        arrivals = Enum.filter((window * 8)..(window * 8 + 7), &(&1 in 1..Headhunter.total()))
        levels = for date <- dates, n <- arrivals, do: Headhunter.recruit(date, n).level

        assert_in_delta Enum.sum(levels) / length(levels), (lowest + highest) / 2, 0.06 * highest
      end
    end

    test "a recruit's only skill is removal, at half its level" do
      for level <- 1..24, do: assert(Headhunter.removal_points(level) == ceil(level / 2))
      # a skill slot holds 12 points at most: the top of the band is exactly there
      assert Headhunter.removal_points(24) == 12

      recruit = Headhunter.recruit(@date, 100)
      assert recruit.skills == [0, Headhunter.removal_points(recruit.level), 0, 0, 0, 0]
    end

    test "about one recruit in eight is bold" do
      bold = Enum.count(1..Headhunter.total(), &Headhunter.recruit(@date, &1).bold?)
      assert bold in 8..24
    end
  end

  describe "exposure" do
    test "nothing is exposed below 25 Intelligence" do
      for level <- 1..24 do
        assert Headhunter.reveal_chance(0, level) == 0.0
        assert Headhunter.reveal_chance(24.9, level) == 0.0
        refute Headhunter.exposed?(24.9, level, 0.0)
      end
    end

    test "every 25 Intelligence adds 20% over the agent's level" do
      assert_in_delta Headhunter.reveal_chance(25, 1), 0.2, 1.0e-9
      assert_in_delta Headhunter.reveal_chance(49, 1), 0.2, 1.0e-9
      assert_in_delta Headhunter.reveal_chance(50, 1), 0.4, 1.0e-9
      assert_in_delta Headhunter.reveal_chance(100, 4), 0.2, 1.0e-9
      assert_in_delta Headhunter.reveal_chance(300, 9), 12 * 0.2 / 9, 1.0e-9
      assert Headhunter.reveal_chance(300, 1) == 1.0
    end

    test "a lower level is always easier to expose, and more Intelligence never hides anyone" do
      for intel <- [25, 100, 200, 300], level <- 1..8 do
        assert Headhunter.reveal_chance(intel, level) >= Headhunter.reveal_chance(intel, level + 1)
      end

      for level <- 1..9, intel <- [0, 25, 50, 100, 150, 200, 250] do
        assert Headhunter.reveal_chance(intel + 25, level) >= Headhunter.reveal_chance(intel, level)
      end
    end

    test "the day's roster opens up with Intelligence: a spread, never the whole roster" do
      roster = for n <- 1..Headhunter.total(), do: Headhunter.recruit(@date, n)
      seen = fn intel -> Enum.count(roster, &Headhunter.exposed?(intel, &1.level, &1.evasion)) end

      assert seen.(0) == 0
      assert seen.(25) in 2..12
      assert seen.(100) in 12..35
      assert seen.(200) in 25..55
      assert seen.(300) in 35..70
      assert seen.(100) < seen.(200) and seen.(200) < seen.(300)
    end

    test "an exposed agent is held under the discovery threshold" do
      assert Headhunter.exposed_cover() < 75
    end
  end
end
