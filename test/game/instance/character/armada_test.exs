defmodule Character.ArmadaTest do
  @moduledoc """
  Pure unit tests for `Instance.Character.Armada`: stance priorities,
  membership-map helpers, formation/join/break validation, the busy
  (lead-rule) predicate, and battle-side ordering (test classes 1, 3,
  4, 6, 9, 9a at the logic layer — the scenario suite drives the same
  rules through the engagement pipeline).
  """
  use ExUnit.Case, async: true

  alias Instance.Character.ActionQueue
  alias Instance.Character.Armada
  alias Test.FleetScenario

  @iid 999_001

  defp char(id, opts \\ []) do
    FleetScenario.build_character(
      Keyword.merge(
        [instance_id: @iid, character_id: id, faction: :phoenix, system: 10, owner_id: 100],
        opts
      )
    )
  end

  defp in_armada(character, armada), do: Map.put(character, :armada, armada)

  defp with_experience(character, xp), do: %{character | experience: Core.DynamicValue.new(xp * 1.0)}

  defp with_queue(character) do
    actions = ActionQueue.add(character.actions, {:jump, %{"target" => 11}, 5}, 11)
    %{character | actions: actions}
  end

  describe "stance_priority/1" do
    test "orders Fury -> Interdiction -> Defender -> Prudent -> Deserter" do
      order = [:attack_everyone, :attack_enemies, :defend, :fight_back, :flee]
      priorities = Enum.map(order, &Armada.stance_priority/1)
      assert priorities == Enum.sort(priorities)
      assert length(Enum.uniq(priorities)) == 5
    end
  end

  describe "effective_reaction/1" do
    test "is the most aggressive member stance" do
      a = char(1, reaction: :fight_back)
      b = char(2, reaction: :attack_everyone)
      c = char(3, reaction: :defend)

      assert Armada.effective_reaction([a, b, c]) == :attack_everyone
      assert Armada.effective_reaction([a, c]) == :defend
      assert Armada.effective_reaction([a]) == :fight_back
    end
  end

  describe "membership helpers" do
    test "member_ids / other_member_ids are nil-safe and snapshot-safe" do
      solo = char(1)
      assert Armada.get(solo) == nil
      refute Armada.member?(solo)
      assert Armada.member_ids(solo) == []
      assert Armada.other_member_ids(solo) == []

      armada = Armada.new(1, "The Iron Concord", [3, 1])
      member = in_armada(char(1), armada)
      assert Armada.member?(member)
      assert Armada.member_ids(member) == [1, 3]
      assert Armada.other_member_ids(member) == [3]

      # a pre-armada snapshot struct has no :armada key at all
      stripped = Map.delete(solo, :armada)
      assert Armada.get(stripped) == nil
      assert Armada.other_member_ids(stripped) == []
    end
  end

  describe "busy?/1 (the lead rule predicate)" do
    test "idle and docking are not busy; queues, sieges, transit are" do
      refute Armada.busy?(char(1, action_status: :idle))
      refute Armada.busy?(char(1, action_status: :docking))

      assert Armada.busy?(with_queue(char(1)))
      assert Armada.busy?(char(1, action_status: :conquest))
      assert Armada.busy?(char(1, action_status: :moving))
      assert Armada.busy?(char(1, action_status: :attached))
    end
  end

  describe "validate_formation/2 (test classes 1 and 3)" do
    test "accepts two idle co-located admirals of the same player" do
      assert :ok == Armada.validate_formation(char(1), char(2))
    end

    test "rejects cross-player formation" do
      assert {:error, :armada_same_player_only} ==
               Armada.validate_formation(char(1, owner_id: 100), char(2, owner_id: 200))
    end

    test "rejects non-co-located pairs" do
      assert {:error, :armada_not_colocated} ==
               Armada.validate_formation(char(1, system: 10), char(2, system: 11))
    end

    test "rejects a Deserter-stance member (flee ban)" do
      assert {:error, :armada_flee_stance_forbidden} ==
               Armada.validate_formation(char(1), char(2, reaction: :flee))
    end

    test "rejects busy characters" do
      assert {:error, :armada_character_busy} ==
               Armada.validate_formation(with_queue(char(1)), char(2))
    end

    test "rejects members of existing armadas" do
      armada = Armada.new(1, nil, [1, 3])

      assert {:error, :armada_already_member} ==
               Armada.validate_formation(in_armada(char(1), armada), char(2))
    end

    test "rejects self-pairing and non-admirals" do
      assert {:error, :armada_needs_two_characters} == Armada.validate_formation(char(1), char(1))
      assert {:error, :armada_admirals_only} == Armada.validate_formation(char(1, type: :spy), char(2))
    end
  end

  describe "validate_join/2 (test class 1)" do
    test "accepts a third member, rejects a fourth with :armada_full" do
      armada = Armada.new(1, nil, [1, 2])
      members = [in_armada(char(1), armada), in_armada(char(2), armada)]

      assert :ok == Armada.validate_join(char(3), members)

      full = Armada.new(1, nil, [1, 2, 4])
      full_members = [in_armada(char(1), full), in_armada(char(2), full), in_armada(char(4), full)]

      assert {:error, :armada_full} == Armada.validate_join(char(3), full_members)
    end

    test "rejects joining while the armada is busy" do
      armada = Armada.new(1, nil, [1, 2])
      members = [in_armada(with_queue(char(1)), armada), in_armada(char(2), armada)]

      assert {:error, :armada_busy} == Armada.validate_join(char(3), members)
    end

    test "rejects joining from another system or player" do
      armada = Armada.new(1, nil, [1, 2])
      members = [in_armada(char(1), armada), in_armada(char(2), armada)]

      assert {:error, :armada_not_colocated} == Armada.validate_join(char(3, system: 99), members)
      assert {:error, :armada_same_player_only} == Armada.validate_join(char(3, owner_id: 200), members)
    end
  end

  describe "validate_break/1 (test classes 1 and 4)" do
    test "allows break at rest, rejects while any member is busy" do
      assert :ok == Armada.validate_break([char(1), char(2)])
      assert {:error, :armada_busy} == Armada.validate_break([char(1), char(2, action_status: :conquest)])
      assert {:error, :armada_busy} == Armada.validate_break([char(1, action_status: :attached), char(2)])
    end
  end

  describe "order_battle_side/2 (test classes 6, 9, 9a)" do
    test "a Prudent armada member joins last of its block — but joins" do
      armada = Armada.new(1, nil, [1, 2, 3])
      fury = in_armada(char(1, reaction: :attack_everyone), armada)
      defender = in_armada(char(2, reaction: :defend), armada)
      prudent = in_armada(char(3, reaction: :fight_back), armada)

      # the prudent bomber is the initiator (primary), yet joins last
      ordered = Armada.order_battle_side([prudent, fury, defender], prudent.id)
      assert Enum.map(ordered, & &1.id) == [1, 2, 3]
    end

    test "9a: the initiation winner's armada joins before an equal-stance solo defender" do
      armada = Armada.new(1, nil, [1, 2, 3])
      a = in_armada(char(1, reaction: :attack_everyone), armada)
      b = in_armada(char(2, reaction: :defend), armada)
      c = in_armada(char(3, reaction: :defend), armada)
      beta = char(4, reaction: :attack_everyone)

      # Alpha's Fury (A) won the initiation flip: A, B, C all join
      # before Beta even though Beta is also Fury.
      ordered = Armada.order_battle_side([a, b, c, beta], a.id)
      assert Enum.map(ordered, & &1.id) == [1, 2, 3, 4]

      # Beta won the flip instead: Beta first, then the Alpha block.
      ordered = Armada.order_battle_side([a, b, c, beta], beta.id)
      assert Enum.map(ordered, & &1.id) == [4, 1, 2, 3]
    end

    test "armada blocks stay adjacent among other joiners" do
      armada = Armada.new(5, nil, [5, 6])
      a = in_armada(char(5, reaction: :defend), armada)
      b = in_armada(char(6, reaction: :fight_back), armada)
      solo_fury = char(7, reaction: :attack_everyone)
      solo_prudent = char(8, reaction: :fight_back)

      # primary = solo_fury: its (solo) block first, then the armada
      # block (best member :defend beats solo :fight_back), then the
      # remaining solo prudent.
      ordered = Armada.order_battle_side([a, b, solo_fury, solo_prudent], solo_fury.id)
      assert Enum.map(ordered, & &1.id) == [7, 5, 6, 8]
    end

    test "equal stances break ties by experience among non-primary joiners" do
      primary = char(3, reaction: :attack_everyone)
      strong = with_experience(char(1, reaction: :defend), 50)
      weak = with_experience(char(2, reaction: :defend), 5)

      ordered = Armada.order_battle_side([weak, strong, primary], primary.id)
      assert Enum.map(ordered, & &1.id) == [3, 1, 2]
    end

    test "the primary wins an equal-stance tie inside its own block" do
      armada = Armada.new(1, nil, [1, 2])
      strong = with_experience(in_armada(char(1, reaction: :defend), armada), 50)
      weak = with_experience(in_armada(char(2, reaction: :defend), armada), 5)

      ordered = Armada.order_battle_side([strong, weak], weak.id)
      assert Enum.map(ordered, & &1.id) == [2, 1]
    end
  end
end
