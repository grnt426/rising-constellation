defmodule Instance.Victory.VictoryTest do
  # Targeted coverage for the tie-break path added to break ties when two
  # factions land on the same integer victory_points score — which happens
  # almost every time a game ends on `win_on_time` (only 12 distinct values
  # in [0, 27] across all three tracks, so cluster collisions are routine).
  # Also covers the milestone-threshold math in update_tracks/1, in
  # particular the final-tier hard caps (95% of the achievable ceiling) that
  # keep 2-faction games winnable on the conquest and shadows tracks.
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

  describe "next_tick/2 win_points_target" do
    test "raising the target to 20 keeps a 14-VP leader from winning" do
      state = %{single_faction_victory(14, 500.0, false) | win_points_target: 20}
      {change, new_state, export} = Victory.next_tick(state, 1.0)

      assert new_state.winner == nil
      refute MapSet.member?(change, :victory)
      assert export == nil
    end

    test "a 20-VP leader wins when the target is 20" do
      state = %{single_faction_victory(20, 500.0, false) | win_points_target: 20}
      {change, new_state, export} = Victory.next_tick(state, 1.0)

      assert new_state.winner == :tetrarchy
      assert MapSet.member?(change, :victory)
      assert export.victory_type == "victory_track"
    end

    test "nil target keeps the historical 14 threshold" do
      state = single_faction_victory(14, 500.0, false)
      assert state.win_points_target == nil

      {_change, new_state, export} = Victory.next_tick(state, 1.0)

      assert new_state.winner == :tetrarchy
      assert export.victory_type == "victory_track"
    end

    test "a pre-field snapshot (key entirely absent) falls back to 14" do
      # Snapshot restore rebuilds the struct from a stored map; a snapshot
      # taken before this field existed comes back with the key missing, not
      # nil — exactly what Map.delete produces.
      state = Map.delete(single_faction_victory(14, 500.0, false), :win_points_target)
      {_change, new_state, export} = Victory.next_tick(state, 1.0)

      assert new_state.winner == :tetrarchy
      assert export.victory_type == "victory_track"
    end

    test "a raised target still loses to the clock" do
      state = %{single_faction_victory(14, 0.5, false) | win_points_target: 20}
      {change, new_state, export} = Victory.next_tick(state, 1.0)

      assert new_state.winner == :tetrarchy
      assert MapSet.member?(change, :victory)
      assert export.victory_type == "win_on_time"
    end
  end

  describe "update_tracks/1 milestone thresholds" do
    # Build a real Victory struct via new/7, inject player/possession counts,
    # then recompute the tracks through the public update_visibility/3 — the
    # only update_* entry point that doesn't call into Data.Querier.
    # faction_specs: {key, id, active_players, possessions};
    # sector_specs: {value, owner}.
    defp tracked(faction_specs, sector_specs, inhabitable \\ 60) do
      factions = Enum.map(faction_specs, fn {key, id, _players, _poss} -> %{id: id, key: key} end)

      sectors =
        sector_specs
        |> Enum.with_index()
        |> Enum.map(fn {{value, owner}, i} -> %{id: i, name: "s#{i}", victory_points: value, owner: owner} end)

      v = Victory.new(1_000.0, 14, inhabitable, sectors, factions, 999)

      factions =
        Enum.map(v.factions, fn f ->
          {_, _, players, poss} = Enum.find(faction_specs, fn {k, _, _, _} -> k == f.key end)
          %{f | player_count: players, possession_count: poss}
        end)

      {first_key, _, _, _} = hd(faction_specs)
      Victory.update_visibility(%{v | factions: factions}, first_key, 0)
    end

    defp track(state, key, track_name) do
      state.factions |> Enum.find(&(&1.key == key)) |> Map.fetch!(track_name)
    end

    test "shadows: balanced 2-faction game uses 30/60/95% of the achievable max" do
      # Both factions 10 players; the enemy owns 40 systems -> max = 5 * 40 = 200.
      # Faction-count factor 2 * (1/2) = 1, weighting 1.
      state = tracked([{:ark, 1, 10, 40}, {:myrmezir, 2, 10, 40}], [{1, nil}])

      assert track(state, :ark, :visibility_track).milestones == [0, 60, 120, 190]
    end

    test "shadows: outnumbering faction keeps a reachable final milestone (was > max)" do
      # 12v8 players: weighting = sqrt(12/10) ~ 1.095. The raw final tier is
      # 208 on a 200 max; the old `max + 3` cap pinned it at 203 — permanently
      # unreachable. The 95% hard cap now lands it at 190.
      state = tracked([{:ark, 1, 12, 40}, {:myrmezir, 2, 8, 40}], [{1, nil}])
      %{milestones: milestones} = track(state, :ark, :visibility_track)

      assert milestones == [0, 66, 131, 190]
      assert Enum.at(milestones, 3) <= 5 * 40
    end

    test "shadows: 4-faction game halves the reduced coefficients via the faction-count factor" do
      # Enemies of :ark own 14 + 13 + 13 = 40 systems -> max 200; factor 2/4 = 0.5.
      state =
        tracked(
          [{:ark, 1, 5, 10}, {:myrmezir, 2, 5, 14}, {:tetrarchy, 3, 5, 13}, {:synelle, 4, 5, 13}],
          [{1, nil}]
        )

      assert track(state, :ark, :visibility_track).milestones == [0, 30, 60, 95]
    end

    test "shadows: nothing to infiltrate leaves the final milestone unreachable, not free" do
      state = tracked([{:ark, 1, 10, 5}, {:myrmezir, 2, 10, 0}], [{1, nil}])
      %{milestones: milestones, index: index} = track(state, :ark, :visibility_track)

      assert milestones == [0, 1, 2, 3]
      assert index == 0
    end

    test "shadows: crossing the final milestone still pays the full 10 VP" do
      state =
        tracked([{:ark, 1, 10, 40}, {:myrmezir, 2, 10, 40}], [{1, nil}])
        |> Victory.update_visibility(:ark, 190)

      assert track(state, :ark, :visibility_track).index == 3
      assert Enum.find(state.factions, &(&1.key == :ark)).victory_points == 10
    end

    test "conquest: outnumbering faction never needs 100% of sector points" do
      # 20 sectors x 2 points = 40 total. With 12v8 weighting the raw final
      # tier is 41.6; the old round + `total` cap turned that into "own
      # everything" (40). Floor + 95% hard cap now lands it at 38.
      sectors = List.duplicate({2, nil}, 20)
      state = tracked([{:ark, 1, 12, 40}, {:myrmezir, 2, 8, 40}], sectors)
      %{milestones: milestones} = track(state, :ark, :conquest_track)

      assert Enum.at(milestones, 3) == 38
      assert Enum.at(milestones, 3) < 40
    end

    test "conquest: final milestone rounds down" do
      # Underdog (8v12, weighting ~0.894) on 41 total points:
      # raw = 0.95 * 41 * 0.894 = 34.84 -> floor gives 34 where round said 35.
      sectors = List.duplicate({1, nil}, 41)
      state = tracked([{:ark, 1, 8, 40}, {:myrmezir, 2, 12, 40}], sectors)

      assert Enum.at(track(state, :ark, :conquest_track).milestones, 3) == 34
    end

    test "conquest: 1-point maps keep the final milestone owned, not free" do
      # The daily-challenge shape: one faction, one sector worth 1. The hard
      # cap floors at 1, so owning the sector still maxes the track while a
      # zero-point faction gets nothing for free.
      state = tracked([{:ark, 1, 1, 1}], [{1, :ark}])
      %{milestones: milestones, index: index} = track(state, :ark, :conquest_track)

      assert Enum.at(milestones, 3) == 1
      assert index == 3
    end
  end
end
