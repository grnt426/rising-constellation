defmodule Instance.Victory.VictoryTest do
  # Targeted coverage for the tie-break path added to break ties when two
  # factions land on the same integer victory_points score — which happens
  # almost every time a game ends on `win_on_time` (only 12 distinct values
  # in [0, 27] across all three tracks, so cluster collisions are routine).
  use ExUnit.Case, async: true
  alias Instance.Victory.Victory

  # Build the minimum state shape that rank_factions/1 and tie_break_score/2
  # actually read. Avoids depending on the full TypedStruct constructors and
  # PopulationClass data loader, which would drag in the Data.Querier.
  defp faction(key, opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      key: key,
      victory_points: Keyword.fetch!(opts, :vp),
      possession_count: Keyword.get(opts, :possession_count, 0),
      population_value: Keyword.get(opts, :population_value, 0.0),
      visibility_count: Keyword.get(opts, :visibility_count, 0)
    }
  end

  defp state(factions, inhabitable \\ 30) do
    %{factions: factions, inhabitable_systems_count: inhabitable}
  end

  describe "rank_factions/1" do
    test "respects victory_points when there's no tie" do
      s =
        state([
          faction(:tetrarchy, id: 5, vp: 5),
          faction(:myrmezir, id: 6, vp: 8)
        ])

      assert [%{key: :myrmezir}, %{key: :tetrarchy}] = Victory.rank_factions(s)
    end

    test "breaks tied victory_points using the continuous tie-break score" do
      # The exact prod-game scenario that motivated the change: both factions
      # at 2 VP each. Without the tie-break, Enum.sort's stability would put
      # Tetrarchy first (lower id, first in factions list) even though
      # Myrmezir is ahead on every raw measure.
      s =
        state(
          [
            faction(:tetrarchy,
              id: 5,
              vp: 2,
              possession_count: 2,
              population_value: 50.0,
              visibility_count: 0
            ),
            faction(:myrmezir,
              id: 6,
              vp: 2,
              possession_count: 4,
              population_value: 70.0,
              visibility_count: 1
            )
          ],
          30
        )

      assert [%{key: :myrmezir}, %{key: :tetrarchy}] = Victory.rank_factions(s)
    end

    test "tie-break gives Tetrarchy the win in the design hypothetical" do
      # 30 systems; Tet owns 10, Myr owns 8. Tet packed less population per
      # system; Myr packed more. Tet did better at visibility. With the 160
      # pop denominator, Tet's espionage edge wins over Myr's pop density.
      s =
        state(
          [
            faction(:tetrarchy,
              id: 5,
              vp: 2,
              possession_count: 10,
              population_value: 300.0,
              visibility_count: 20
            ),
            faction(:myrmezir,
              id: 6,
              vp: 2,
              possession_count: 8,
              population_value: 340.0,
              visibility_count: 15
            )
          ],
          30
        )

      assert [%{key: :tetrarchy}, %{key: :myrmezir}] = Victory.rank_factions(s)
    end
  end

  describe "tie_break_score/2" do
    test "all-zero faction scores 0.0" do
      s = state([faction(:tetrarchy, id: 5, vp: 0), faction(:myrmezir, id: 6, vp: 0)])
      score = Victory.tie_break_score(hd(s.factions), s)
      assert score == 0.0
    end

    test "caps pop term at 1.0 even with average population above 160" do
      # 10 systems averaging 200 raw pop each — well past the :prodigious
      # threshold (160) the denominator is anchored to. Pop component must
      # clamp at 1.0; otherwise it could dominate the other two terms.
      s =
        state(
          [
            faction(:tetrarchy,
              id: 5,
              vp: 2,
              possession_count: 10,
              population_value: 2000.0,
              visibility_count: 0
            ),
            faction(:myrmezir, id: 6, vp: 2, possession_count: 0, population_value: 0.0)
          ],
          30
        )

      [tet | _] = s.factions
      # conquest = 10/30, pop = capped 1.0, visibility = 0/(0*5) -> 0
      assert_in_delta Victory.tie_break_score(tet, s), 10 / 30 + 1.0, 1.0e-9
    end

    test "visibility ratio uses enemy possessions, not own" do
      # Tet faces an enemy holding 4 systems. Visibility max = 4 * 5 = 20.
      # Tet at 10 visibility -> 0.5 on the visibility term.
      s =
        state(
          [
            faction(:tetrarchy,
              id: 5,
              vp: 2,
              possession_count: 0,
              population_value: 0.0,
              visibility_count: 10
            ),
            faction(:myrmezir, id: 6, vp: 2, possession_count: 4)
          ],
          30
        )

      [tet | _] = s.factions
      assert_in_delta Victory.tie_break_score(tet, s), 0.5, 1.0e-9
    end

    test "visibility term is 0 when there are no enemy possessions (no div-by-zero)" do
      s =
        state([
          faction(:tetrarchy,
            id: 5,
            vp: 0,
            possession_count: 5,
            population_value: 0.0,
            visibility_count: 7
          ),
          faction(:myrmezir, id: 6, vp: 0, possession_count: 0)
        ])

      [tet | _] = s.factions
      # conquest = 5/30, pop = 0, visibility = 0 (no enemies)
      assert_in_delta Victory.tie_break_score(tet, s), 5 / 30, 1.0e-9
    end
  end
end
