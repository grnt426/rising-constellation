defmodule Fight.ManagerOutcomeTest do
  @moduledoc """
  Regression pin for `Fight.Manager.do_check_outcome/2`'s
  both-defeated branch: a battle in which BOTH sides end up with no
  ships on the field and no reinforcement is a DRAW — `victory` stays
  `:undefined` and every shipless combatant is `:dead`.

  Before 2026-08-17 the [:left, :right] outcome reduce did not halt:
  the right-side pass overwrote the left's verdict, so the attacker
  was declared `:victorious` over two annihilated sides.
  """
  use ExUnit.Case, async: true

  alias Test.FleetScenario

  test "shipless vs shipless resolves as a draw with both sides dead" do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid)

    left =
      FleetScenario.build_character(
        instance_id: iid,
        character_id: 1,
        faction: :crow,
        owner_id: 200,
        system: 10,
        has_ships?: false
      )

    right =
      FleetScenario.build_character(
        instance_id: iid,
        character_id: 2,
        faction: :phoenix,
        owner_id: 100,
        system: 10,
        has_ships?: false
      )

    {{[{left_status, :left, _}], [{right_status, :right, _}]}, _logs, _metadata, victory} =
      Fight.Manager.fight([left], [right])

    assert victory == :undefined, "mutual annihilation has no victor"
    assert left_status == :dead
    assert right_status == :dead
  end

  test "the draw verdict is symmetric — no attacker/defender bias" do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid)

    left =
      FleetScenario.build_character(
        instance_id: iid,
        character_id: 1,
        faction: :crow,
        owner_id: 200,
        system: 10,
        has_ships?: false
      )

    right =
      FleetScenario.build_character(
        instance_id: iid,
        character_id: 2,
        faction: :phoenix,
        owner_id: 100,
        system: 10,
        has_ships?: false
      )

    {_result, _logs, _metadata, victory} = Fight.Manager.fight([left], [right])
    assert victory == :undefined

    # swapping who "attacks" must not change the verdict — the old
    # non-halting reduce always favored whichever list was :left
    {_result2, _logs2, _metadata2, victory2} = Fight.Manager.fight([right], [left])
    assert victory2 == :undefined
  end
end
