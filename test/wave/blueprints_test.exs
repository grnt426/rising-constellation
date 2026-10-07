defmodule Wave.BlueprintsTest do
  use ExUnit.Case, async: true

  alias Wave.Blueprints

  # The Legacy catalog, as the Warlord reads it.
  defp ships, do: Map.new(Data.Game.Ship.Content.Slow.data(), &{&1.key, &1})

  defp design(id, hulls, evidence, players \\ 1) do
    %{
      id: id,
      slots: hulls |> Enum.with_index(1) |> Enum.map(fn {hull, tile} -> {tile, hull} end),
      evidence: evidence,
      players: players,
      stance: :defend
    }
  end

  describe "the shipped pool" do
    test "every design names hulls of the catalog and fits the eighteen tiles" do
      pool = Blueprints.pool()
      catalog = ships()

      assert length(pool) > 100

      for design <- pool, {tile, hull} <- design.slots do
        assert tile in 1..18
        assert Map.has_key?(catalog, hull), "#{design.id} names #{hull}"
        # Designs hold hulls, never a stack: the stack follows the patents.
        refute hull |> Atom.to_string() |> String.match?(~r/v\d$/)
      end
    end

    test "every role has designs, and nothing carries a colony ship" do
      pool = Blueprints.pool()

      for role <- Blueprints.roles() do
        assert Enum.any?(pool, &(Blueprints.weight(&1, role) > 0)), "no design for #{role}"
      end

      refute Enum.any?(pool, fn design -> Enum.any?(design.slots, fn {_tile, hull} -> hull == :transport_1 end) end)
    end

    test "with the first fighter and corvette patents a fleet can be picked for the early roles" do
      patents = [:shipyard_1, :fighter_2, :fighter_3, :fighter_4, :shipyard_2, :corvette_1]

      for role <- [:defense, :raid, :siege, :screen] do
        assert {:ok, pick} = Blueprints.pick(Blueprints.pool(), role, patents, ships(), 0.5)
        assert length(pick.slots) >= 9
      end

      # An invasion needs Carriers, and nobody holds that patent yet.
      refute Enum.any?(Blueprints.eligible(Blueprints.pool(), :conquest, patents, ships()), fn pick ->
               Enum.any?(pick.slots, fn {_tile, key} -> key == :transport_2 end)
             end)
    end
  end

  describe "parse/1" do
    test "reads slots, evidence and stance, and drops a design with a hull it does not know" do
      json = %{
        "blueprints" => [
          %{
            "id" => "bp_a",
            "slots" => [[2, "fighter_4"], [1, "corvette_1"]],
            "evidence" => %{"raid" => 3},
            "players" => 2,
            "stance" => "attack_everyone"
          },
          %{"id" => "bp_b", "slots" => [[1, "deathstar_9"]], "evidence" => %{"raid" => 1}},
          %{"id" => "bp_c", "slots" => [[1, "fighter_1"]], "stance" => "sulk"}
        ]
      }

      assert [a, c] = Blueprints.parse(json)

      assert a == %{
               id: "bp_a",
               slots: [{1, :corvette_1}, {2, :fighter_4}],
               evidence: %{"raid" => 3},
               players: 2,
               stance: :attack_everyone
             }

      assert c.stance == :defend
      assert Blueprints.parse(%{"nothing" => true}) == []
    end
  end

  describe "stack/3 and resolve/3" do
    test "a hull is built as the largest stack the merge patents allow" do
      catalog = ships()

      assert Blueprints.stack(:fighter_4, [], catalog) == nil
      assert Blueprints.stack(:fighter_4, [:fighter_4], catalog) == :fighter_4
      assert Blueprints.stack(:fighter_4, [:fighter_4, :merge_fighter_1], catalog) == :fighter_4v2
      assert Blueprints.stack(:fighter_4, [:fighter_4, :merge_fighter_1, :merge_fighter_2], catalog) == :fighter_4v3
      # A later merge without the one before it is not a stack the engine builds.
      assert Blueprints.stack(:fighter_4, [:fighter_4, :merge_fighter_2], catalog) == :fighter_4
      # The assault frigate comes with the frigate yard's own patent.
      assert Blueprints.stack(:frigate_1, [:shipyard_3], catalog) == :frigate_1
      assert Blueprints.stack(:capital_1, [:capital_1], catalog) == :capital_1
    end

    test "a design is locked until every hull's patent is held" do
      d = design("bp", [:fighter_4, :frigate_1], %{"screen" => 1})

      assert Blueprints.resolve(d, [:fighter_4], ships()) == :locked

      assert Blueprints.resolve(d, [:fighter_4, :merge_fighter_1, :shipyard_3], ships()) ==
               {:ok, [{1, :fighter_4v2}, {2, :frigate_1}]}
    end
  end

  describe "weight/2" do
    test "sightings in the role plus the players who fielded it; screens also count hunters at half" do
      d = design("bp", [:fighter_4], %{"raid" => 4, "screen" => 2, "hunt" => 3}, 2)

      assert Blueprints.weight(d, :raid) == 6.0
      assert Blueprints.weight(d, :screen) == 2 + 1.5 + 2
      assert Blueprints.weight(d, :defense) == 0.0
    end
  end

  describe "pick/6" do
    setup do
      pool = [
        design("scouts", List.duplicate(:fighter_1, 4), %{"raid" => 50}),
        design("corvettes", List.duplicate(:corvette_1, 4), %{"raid" => 1}),
        design("bombers", List.duplicate(:fighter_3, 4), %{"raid" => 1}),
        design("interceptors", List.duplicate(:fighter_4, 4), %{"raid" => 1}),
        design("frigates", List.duplicate(:frigate_2, 4), %{"raid" => 9}),
        design("guards", List.duplicate(:corvette_1, 4), %{"defense" => 1})
      ]

      %{pool: pool, patents: [:shipyard_1, :fighter_3, :fighter_4, :corvette_1]}
    end

    test "only the role's designs the patents allow are eligible, costliest first", %{pool: pool, patents: patents} do
      ids = pool |> Blueprints.eligible(:raid, patents, ships()) |> Enum.map(& &1.design.id)
      assert ids == ["corvettes", "bombers", "interceptors", "scouts"]
    end

    test "the cheap end of the list is out of the draw however popular it was", %{pool: pool, patents: patents} do
      picks =
        for roll <- [0.0, 0.3, 0.6, 0.99], do: elem(Blueprints.pick(pool, :raid, patents, ships(), roll), 1).design.id

      assert Enum.uniq(picks) == ["corvettes", "bombers", "interceptors"]
      # With the whole list in the draw the fifty sightings win almost always.
      assert {:ok, %{design: %{id: "scouts"}}} = Blueprints.pick(pool, :raid, patents, ships(), 0.5, share: 1.0)
    end

    test "a design already in the book is left out of the draw while there are others", %{pool: pool, patents: patents} do
      taken = ["corvettes", "bombers"]

      for roll <- [0.0, 0.5, 0.99] do
        assert {:ok, %{design: %{id: "interceptors"}}} =
                 Blueprints.pick(pool, :raid, patents, ships(), roll, exclude: taken)
      end

      # With every design in the draw excluded, the draw is what it was.
      assert {:ok, %{design: %{id: "corvettes"}}} =
               Blueprints.pick(pool, :raid, patents, ships(), 0.0, exclude: taken ++ ["interceptors"])

      assert Blueprints.draw_floor(pool, :raid, patents, ships()) == 4 * 352
      assert Blueprints.draw_floor(pool, :conquest, patents, ships()) == nil
    end

    test "`allow` keeps what no yard can build out, and nothing eligible is :none", %{pool: pool, patents: patents} do
      no_corvettes = fn slots -> not Enum.any?(slots, fn {_tile, key} -> key == :corvette_1 end) end

      ids = pool |> Blueprints.eligible(:raid, patents, ships(), no_corvettes) |> Enum.map(& &1.design.id)
      refute "corvettes" in ids

      assert Blueprints.pick(pool, :conquest, patents, ships(), 0.5) == :none
      assert Blueprints.pick(pool, :defense, patents, ships(), 0.5, allow: no_corvettes) == :none
    end
  end
end
