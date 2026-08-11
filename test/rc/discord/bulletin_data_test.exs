defmodule RC.Discord.BulletinDataTest do
  use ExUnit.Case, async: true

  alias RC.Discord.BulletinData

  defp event(kind, payload), do: %{kind: kind, payload: payload}

  describe "battle folds" do
    test "battle_factions tallies wins/losses, draws count neither" do
      battles = [
        event("battle", %{"attacker_faction" => "synelle", "defender_faction" => "ark", "winner" => "attackers"}),
        event("battle", %{"attacker_faction" => "ark", "defender_faction" => "synelle", "winner" => "defenders"}),
        event("battle", %{"attacker_faction" => "ark", "defender_faction" => "synelle", "winner" => "draw"})
      ]

      assert [
               %{faction: "synelle", wins: 2, losses: 0},
               %{faction: "ark", wins: 0, losses: 2}
             ] = BulletinData.battle_factions(battles)
    end

    test "battle_records aggregates per player across battles" do
      battles = [
        event("battle", %{
          "winners" => [%{"name" => "Kalid", "faction" => "synelle"}],
          "losers" => [%{"name" => "Tianxia", "faction" => "ark"}]
        }),
        event("battle", %{
          "winners" => [%{"name" => "Kalid", "faction" => "synelle"}],
          "losers" => [%{"name" => "Tianxia", "faction" => "ark"}]
        })
      ]

      assert [
               %{name: "Kalid", faction: "synelle", wins: 2, losses: 0},
               %{name: "Tianxia", faction: "ark", wins: 0, losses: 2}
             ] = BulletinData.battle_records(battles)
    end
  end

  describe "spoils/4" do
    test "detailed tier lists non-neutral targets with counts and value sums" do
      raids = [
        event("raid", %{
          "system_name" => "Boras",
          "system_id" => 1,
          "victim_faction" => "synelle",
          "damaged_buildings" => 3,
          "population_lost" => 120.5
        }),
        # neutral victim: counts toward totals, never named
        event("raid", %{"system_name" => "Cone", "system_id" => 2, "victim_faction" => nil, "damaged_buildings" => 2})
      ]

      loots = [
        event("loot", %{
          "system_name" => "Amorin",
          "system_id" => 3,
          "victim_faction" => "synelle",
          "credit" => 1000,
          "technology" => 50,
          "ideology" => 25
        }),
        event("loot", %{"system_name" => "Amorin", "system_id" => 3, "victim_faction" => "synelle", "credit" => 500})
      ]

      spoils = BulletinData.spoils([], raids, loots, true)

      assert spoils.conquests == %{count: 0, names: []}
      assert spoils.bombards.count == 2
      assert spoils.bombards.systems == 2
      assert spoils.bombards.names == ["Boras"]
      assert spoils.bombards.buildings == 5
      assert spoils.bombards.population == 121
      assert spoils.pillages.count == 2
      assert spoils.pillages.names == [%{name: "Amorin", count: 2}]
      assert spoils.pillages.credits == 1500
      assert spoils.pillages.technology == 50
      assert spoils.pillages.ideology == 25
    end

    test "vague tier hides names but keeps totals" do
      raids = [event("raid", %{"system_name" => "Boras", "system_id" => 1, "victim_faction" => "synelle"})]

      spoils = BulletinData.spoils([], raids, [], false)
      assert spoils.bombards.names == nil
      assert spoils.bombards.count == 1
    end

    test "pre-enrichment rows without value fields sum to zero" do
      loots = [event("loot", %{"system_name" => "Amorin", "system_id" => 3, "victim_faction" => "synelle"})]

      spoils = BulletinData.spoils([], [], loots, true)
      assert spoils.pillages.credits == 0
      assert spoils.pillages.technology == 0
      assert spoils.pillages.ideology == 0
    end
  end

  describe "highlights/3" do
    test "conquests and bombards take precedence over pillages on the same system" do
      conquests = [event("conquest", %{"system_name" => "Dumfri", "system_id" => 1, "faction" => "ark"})]

      raids = [event("raid", %{"system_name" => "Boras", "system_id" => 2, "victim_faction" => "synelle"})]

      loots = [
        event("loot", %{"system_name" => "Dumfri", "system_id" => 1, "victim_faction" => "synelle"}),
        event("loot", %{"system_name" => "Amorin", "system_id" => 3, "victim_faction" => "synelle"}),
        event("loot", %{"system_name" => "Amorin", "system_id" => 3, "victim_faction" => "synelle"})
      ]

      highlights = BulletinData.highlights(conquests, raids, loots)

      assert %{system_id: 1, kind: :conquest, faction: "ark"} = Enum.find(highlights, &(&1.kind == :conquest))
      assert %{system_id: 2, kind: :bombard} = Enum.find(highlights, &(&1.kind == :bombard))
      assert [%{system_id: 3, kind: :pillage, count: 2}] = Enum.filter(highlights, &(&1.kind == :pillage))
    end

    test "neutral-victim strikes are not mapped" do
      raids = [event("raid", %{"system_name" => "Cone", "system_id" => 2, "victim_faction" => nil})]
      assert BulletinData.highlights([], raids, []) == []
    end
  end
end
