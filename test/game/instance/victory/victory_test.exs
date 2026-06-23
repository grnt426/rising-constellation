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

  describe "next_tick/2 time_only (daily challenges)" do
    # A single, already-scored faction. We build the real Victory struct via
    # new/7 (so next_update is a valid DynamicValue) then override :factions
    # with a plain scored map — check_for_victory only reads victory_points off
    # the leader, and rank_factions never invokes the comparator for one
    # faction, so this is enough to drive the win decision without the
    # PopulationClass data loader.
    defp single_faction_victory(vp, ut_time_left, time_only) do
      v = Victory.new(ut_time_left, 14, 1, [], [], 999, time_only)

      %{
        v
        | factions: [
            %{
              id: 1,
              key: :tetrarchy,
              victory_points: vp,
              possession_count: 1,
              population_value: 0.0,
              visibility_count: 0
            }
          ]
      }
    end

    test "ignores the points-based win when time_only is set" do
      # 20 VP (>= 14) but the clock is nowhere near zero: a normal game would
      # declare victory_track here; a daily must not.
      state = single_faction_victory(20, 500.0, true)
      {change, new_state, export} = Victory.next_tick(state, 1.0)

      assert new_state.winner == nil
      refute MapSet.member?(change, :victory)
      assert export == nil
    end

    test "non-daily games still win on points (time_only defaults to false)" do
      state = single_faction_victory(20, 500.0, false)
      {change, new_state, export} = Victory.next_tick(state, 1.0)

      assert new_state.winner == :tetrarchy
      assert MapSet.member?(change, :victory)
      assert export.victory_type == "victory_track"
    end

    test "a daily still ends when its timer runs out, never as victory_track" do
      # 20 VP *and* the clock crosses zero this tick. time_is_up takes
      # precedence in the cond, so even without the time_only gate this would be
      # win_on_time — but asserting it here guards that suppressing the points
      # win doesn't strand a finished daily with no winner.
      state = single_faction_victory(20, 0.5, true)
      {change, new_state, export} = Victory.next_tick(state, 1.0)

      assert new_state.winner == :tetrarchy
      assert MapSet.member?(change, :victory)
      assert export.victory_type == "win_on_time"
      # victory resets the clock to the post-game window
      assert new_state.ut_time_left == 200
    end

    test "new/6 still works and defaults time_only to false" do
      v = Victory.new(100.0, 14, 1, [], [], 999)
      assert v.time_only == false
    end
  end
end
