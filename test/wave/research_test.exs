defmodule Wave.ResearchTest do
  use ExUnit.Case, async: true

  alias Wave.Research

  # The real Legacy catalogs: the rules are only worth anything on the trees
  # players actually see.
  defp patents, do: Data.Game.Patent.Content.Slow.data()
  defp lexes, do: Data.Game.Doctrine.Content.Slow.data()

  @standing [:admiral_1, :prod_2, :spy_def_1, :stab_2]

  describe "starter patents" do
    test "the root, then the four cheapest-reachable patents of each building branch" do
      assert Research.starter_patents(patents(), %{open: 4, dome: 4, orbital: 4}) == [
               :citadel,
               :infra_open_1,
               :infra_open_2,
               :open_industries,
               :open_ideo,
               :infra_dome_1,
               :infra_dome_2,
               :dome_mobility,
               :dome_pop,
               :orbital_credit,
               :orbital_defense,
               :infra_orbital_2,
               :infra_orbital_3
             ]
    end

    test "every starter patent comes after its ancestor, so the engine takes them in order" do
      plan = Research.starter_patents(patents(), %{open: 4, dome: 4, orbital: 4})
      by_key = Map.new(patents(), &{&1.key, &1})

      for {key, index} <- Enum.with_index(plan), ancestor = by_key[key].ancestor do
        assert Enum.find_index(plan, &(&1 == ancestor)) < index
      end
    end

    test "a branch without a quota gets nothing, and the ship branch is never a starter" do
      assert Research.starter_patents(patents(), %{open: 1}) == [:citadel, :infra_open_1]
      assert Research.starter_patents(patents(), %{}) == [:citadel]
    end
  end

  describe "ship patents" do
    test "only ship-branch patents are copied from the humans" do
      rivals = [[:citadel, :infra_open_1, :transport_1], [:citadel, :shipyard_1, :fighter_2, :transport_1], []]

      assert Research.ship_patents(patents(), rivals) == [:transport_1, :shipyard_1, :fighter_2]
    end

    test "the plan brings the ancestors along and skips what is owned" do
      assert Research.purchase_plan(patents(), [:corvette_1], [:citadel, :shipyard_1]) ==
               [:merge_fighter_1, :shipyard_2, :corvette_1]

      assert Research.purchase_plan(patents(), [:transport_1, :fighter_2], []) ==
               [:citadel, :transport_1, :shipyard_1, :fighter_2]

      assert Research.purchase_plan(patents(), [:transport_1], [:citadel, :transport_1]) == []
    end
  end

  describe "building patents" do
    test "the pool is what the engine would sell now, outside the ship branch" do
      assert Research.building_pool(patents(), [:citadel]) == [:infra_open_1, :infra_dome_1, :orbital_credit]

      pool = Research.building_pool(patents(), [:citadel, :infra_open_1])
      assert :infra_open_2 in pool
      assert :open_industries in pool
      refute :infra_open_1 in pool
      refute :shipyard_1 in pool
      refute :transport_1 in pool
    end

    test "nothing is left once every building patent is owned" do
      assert Research.building_pool(patents(), Enum.map(patents(), & &1.key)) == []
    end
  end

  describe "building patents the humans hold" do
    test "one held by enough of them is followed, ship patents and the root aside" do
      rivals = [
        [:citadel, :infra_open_1, :open_credit, :shipyard_1],
        [:citadel, :infra_open_1, :open_credit, :open_island, :shipyard_1],
        [:citadel, :infra_open_1, :orbital_credit]
      ]

      assert Research.followed_patents(patents(), rivals, 2) == [:infra_open_1, :open_credit]
      assert Research.followed_patents(patents(), rivals, 3) == [:infra_open_1]

      assert Enum.sort(Research.followed_patents(patents(), rivals, 1)) ==
               [:infra_open_1, :open_credit, :open_island, :orbital_credit]

      assert Research.followed_patents(patents(), [], 2) == []
    end

    test "the plan brings their ancestors along" do
      assert Research.purchase_plan(patents(), [:open_island], [:citadel, :infra_open_1]) ==
               [:open_credit, :open_island]
    end
  end

  describe "building patents on the clock" do
    test "the game moves through three stages, counted in days elapsed" do
      days = [5, 12]

      assert Enum.map([0, 4.9, 5, 11.9, 12, 20], &Research.stage(&1, days)) ==
               [:early, :early, :mid, :mid, :late, :late]

      # an unusable knob never holds the Rebellion back
      assert Research.stage(3, []) == :late
    end

    test "each stage has its dearest patent" do
      caps = [5_000, 45_000]

      assert Research.cost_cap(:early, caps) == 5_000
      assert Research.cost_cap(:mid, caps) == 45_000
      # the late game's patents are left to the humans to lead on
      assert Research.cost_cap(:late, caps) == 45_000
      assert Research.cost_cap(:late, []) == :infinity
    end

    test "the cheapest patent on offer is bought, inside the stage" do
      starter = Research.starter_patents(patents(), %{open: 4, dome: 4, orbital: 4})

      # early: what is left under 5,000, cheapest first
      assert Research.building_pick(patents(), starter, 5_000) == :infra_open_3

      early =
        Enum.reduce_while(1..40, starter, fn _, owned ->
          case Research.building_pick(patents(), owned, 5_000) do
            nil -> {:halt, owned}
            key -> {:cont, owned ++ [key]}
          end
        end)

      by_key = Map.new(patents(), &{&1.key, &1})
      assert Enum.all?(early, &(by_key[&1].cost <= 5_000))
      assert :orbital_prod in early and :orbital_research in early and :dome_defense_1 in early
      refute :open_credit in early

      # mid-game opens the 8,000 to 40,000 patents: Residential Archipelagos,
      # the Accelerator, the Network of Artificial Islands
      assert by_key[Research.building_pick(patents(), early, 45_000)].cost == 8_000

      mid =
        Enum.reduce_while(1..40, early, fn _, owned ->
          case Research.building_pick(patents(), owned, 45_000) do
            nil -> {:halt, owned}
            key -> {:cont, owned ++ [key]}
          end
        end)

      assert :open_credit in mid and :open_research in mid and :open_island in mid
      refute :orbital_mobility in mid or :dome_ideo in mid or :dome_industries in mid

      # The late game's patents (the Terminus and the Business Arch, then the
      # megastructures) are out of the clock's reach at any stage: they are
      # bought when the humans hold them.
      assert Research.building_pick(patents(), mid, Research.cost_cap(:late, [5_000, 45_000])) == nil
      assert Research.building_pick(patents(), mid, :infinity) == :orbital_mobility
    end
  end

  describe "the economy lexes" do
    @economy [:mobility_1, :credit_perc_1, :tech_3, :ideo_3, :stab_1, :prod_1, :upgrade_repair, :spy_2]

    test "are bought down the list, each through its ancestors" do
      owned = Research.purchase_plan(lexes(), @standing, [])

      # Freedom of Movement sits behind Proto-Empire and Extended Administration
      assert Research.economy_step(lexes(), @economy, owned) == :system_1
      assert Research.economy_step(lexes(), @economy, owned ++ [:system_1]) == :system_2
      assert Research.economy_step(lexes(), @economy, owned ++ [:system_1, :system_2]) == :mobility_1

      next = owned ++ [:system_1, :system_2, :mobility_1]
      assert Research.economy_step(lexes(), @economy, next) == :credit_perc_1

      everything = Research.purchase_plan(lexes(), @standing ++ @economy, [])
      assert Research.economy_step(lexes(), @economy, everything) == nil
    end

    test "are enacted after the standing lexes, in the order of the list" do
      owned = Research.purchase_plan(lexes(), @standing ++ @economy, [])
      enactable = Research.enactable(lexes(), owned, @standing ++ @economy)

      assert Enum.take(enactable, 12) == @standing ++ @economy
      # Extended Administration costs technology: bought on the way, never enacted
      assert :system_2 in owned
      refute :system_2 in enactable
    end
  end

  describe "lex penalties" do
    test "a negative bonus is a penalty, a cut to fleet upkeep is not" do
      by_key = Map.new(lexes(), &{&1.key, &1})

      assert Research.penalised?(by_key.defense_1)
      assert Research.penalised?(by_key.spy_1)
      assert Research.penalised?(by_key.system_2)
      refute Research.penalised?(by_key.reduce_maintenance_1)
      refute Research.penalised?(by_key.prod_2)
      refute Research.penalised?(by_key.stab_2)
    end

    test "cap-only lexes are the ones whose every bonus the bot already bypasses" do
      by_key = Map.new(lexes(), &{&1.key, &1})

      assert Research.cap_only?(by_key.agent)
      assert Research.cap_only?(by_key.admiral_1)
      assert Research.cap_only?(by_key.dominion_1)
      refute Research.cap_only?(by_key.tech_2)
      refute Research.cap_only?(by_key.prod_1)
    end
  end

  describe "lex purchases" do
    test "the standing lexes come with every ancestor, penalised or not" do
      assert Research.purchase_plan(lexes(), @standing, []) == [
               :agent,
               :admiral_1,
               :defense_1,
               :prod_1,
               :prod_2,
               :credit_1,
               :spy_1,
               :spy_def_1,
               :speaker_1,
               :ideo_1,
               :ideo_2,
               :stab_2
             ]
    end

    test "targets leave out penalised lexes, except in the expansion branch" do
      targets = Research.lex_targets(lexes(), [:agent])

      refute :agent in targets
      refute :upgrade_raid in targets
      refute :spy_4 in targets
      assert :system_2 in targets
      assert :dominion_3 in targets
      assert :speaker_dominion in targets
      assert :reduce_maintenance_2 in targets
    end

    test "a target behind a penalised lex is approached through it, one purchase at a time" do
      owned = [:agent, :speaker_1, :ideo_1, :ideo_2]

      assert Research.next_step(lexes(), :speaker_dominion, owned) == :speaker_2
      assert Research.next_step(lexes(), :speaker_dominion, owned ++ [:speaker_2]) == :speaker_3
      assert Research.next_step(lexes(), :speaker_dominion, owned ++ [:speaker_2, :speaker_3]) == :speaker_dominion
      assert Research.next_step(lexes(), :ideo_2, owned) == nil
    end
  end

  describe "enactment" do
    test "the standing lexes lead, penalised ones stay on the shelf, cap-only ones come last" do
      owned = Research.purchase_plan(lexes(), @standing, [])

      assert Research.enactable(lexes(), owned, @standing) ==
               @standing ++ [:prod_1, :ideo_2, :ideo_1, :credit_1, :speaker_1, :agent]
    end

    test "a standing lex not owned yet takes no slot" do
      assert Research.enactable(lexes(), [:agent, :admiral_1], @standing) == [:admiral_1, :agent]
    end

    test "penalised expansion lexes are enacted only when asked for" do
      owned = [:agent, :system_1, :system_2]

      assert Research.enactable(lexes(), owned, []) == [:system_1, :agent]
      assert Research.enactable(lexes(), owned, [], true) == [:system_2, :system_1, :agent]
    end

    test "slots follow the best human, but the standing lexes always fit" do
      assert Research.slots_wanted(10, 4, 8) == 8
      assert Research.slots_wanted(10, 4, 1) == 4
      assert Research.slots_wanted(3, 4, 8) == 3
      assert Research.slots_wanted(0, 0, 8) == 0
    end
  end
end
