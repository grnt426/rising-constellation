defmodule Headless.FitnessTest do
  use ExUnit.Case, async: true
  alias Headless.Fitness

  # Reusable archetypes.
  defp hollow_win do
    # 1 system, settle-only, weak economy, hoarding, won at the clock on a
    # 2-VP tiebreak. The pattern the user wants scored to ~nothing.
    %{
      sys: 1, pop: 30, income: 200, tech: 20, hoarded: 300_000, colonies: 1,
      won: 1.0, my_vp: 2, their_vp: 1, ut_left: 0
    }
  end

  defp good_loss do
    # 5 systems, 4 mechanics, near-golden economy, lost narrowly, decisive game.
    %{
      sys: 5, pop: 300, income: 2600, tech: 450, hoarded: 40_000, colonies: 5,
      infiltrate: 8, destabilize: 4, dominion: 2, military: 3,
      won: 0.0, my_vp: 8, their_vp: 10, ut_left: 300
    }
  end

  defp generalist_win do
    # 6 systems, all 6 mechanics, at/above the golden line, decisive win.
    %{
      sys: 6, pop: 400, income: 3500, tech: 620, hoarded: 30_000, colonies: 6,
      infiltrate: 10, destabilize: 6, dominion: 3, counter: 2, military: 12,
      won: 1.0, my_vp: 15, their_vp: 9, ut_left: 300
    }
  end

  test "a strong-but-lost empire beats a hollow timeout win" do
    assert Fitness.score(good_loss()) > Fitness.score(hollow_win())
  end

  test "a hollow timeout win scores near zero or below" do
    assert Fitness.score(hollow_win()) < 100.0
  end

  test "a generalist decisive win tops everything and lands near the ~1000 ideal" do
    g = Fitness.score(generalist_win())
    assert g > Fitness.score(good_loss())
    assert g > 900.0
  end

  test "more systems scores higher at equal everything else (the un-saturation fix)" do
    base = %{pop: 200, income: 2000, tech: 300, won: 0.0, ut_left: 300, infiltrate: 1, destabilize: 1}
    three = Fitness.score(Map.merge(base, %{sys: 3, colonies: 3}))
    six = Fitness.score(Map.merge(base, %{sys: 6, colonies: 6}))
    # The old ln curve gave 3->6 systems +~34; the linear term makes it real.
    assert six - three > 150.0
  end

  test "engaging more mechanics scores higher (diminishing)" do
    base = %{sys: 3, pop: 200, income: 2000, tech: 300, colonies: 3, won: 0.0, ut_left: 300}
    two = Fitness.score(Map.merge(base, %{infiltrate: 5}))
    five = Fitness.score(Map.merge(base, %{infiltrate: 5, destabilize: 5, dominion: 2, counter: 1, military: 3}))
    assert five > two
  end

  test "idle-hoarding is penalized (human-likeness knob)" do
    base = %{sys: 4, pop: 250, income: 2500, tech: 400, colonies: 4, infiltrate: 3, destabilize: 2, won: 1.0, my_vp: 14, their_vp: 8, ut_left: 200}
    spends = Fitness.score(Map.put(base, :hoarded, 20_000))
    hoards = Fitness.score(Map.put(base, :hoarded, 300_000))
    assert spends > hoards
  end
end
