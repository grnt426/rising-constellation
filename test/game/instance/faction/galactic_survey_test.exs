defmodule Instance.Faction.GalacticSurveyTest do
  use ExUnit.Case, async: true

  alias Instance.Faction.GalacticSurvey
  alias Instance.Faction.StellarSystem, as: FactionStellarSystem

  @own_faction_id 1
  @foreign_faction_id 2

  describe "project/3 — agents column" do
    test "below visibility 2 the agent list is unknown (nil), not empty" do
      row = survey_row(1, [admiral(10, @foreign_faction_id, :cardan, "Raider")])

      assert row.agents == nil
    end

    test "at visibility 2 every visible agent is listed with its faction and owner" do
      row =
        survey_row(2, [
          admiral(10, @foreign_faction_id, :cardan, "Raider"),
          # own Erased are never filtered, undercover or not
          spy(11, @own_faction_id, :tetrarchy, "Shade", 0.9)
        ])

      assert [
               %{id: 10, type: :admiral, name: "Raider", level: 3, faction: :cardan, owner_name: "Player 2"},
               %{id: 11, type: :spy, name: "Shade", level: 3, faction: :tetrarchy, owner_name: "Player 1"}
             ] = Enum.sort_by(row.agents, & &1.id)
    end

    test "a seen system with nobody in it reports an empty list" do
      assert survey_row(2, []).agents == []
    end
  end

  describe "project/3 — bodies" do
    test "nested moons and asteroids are counted by type" do
      row = survey_row(1, [])

      assert row.bodies_by_type == %{
               habitable_planet: 1,
               moon: 1,
               gaseous_giant: 1,
               asteroid_belt: 1,
               asteroid: 2
             }

      assert row.orbitals == 6
    end
  end

  ## Helpers

  defp survey_row(vis, characters) do
    system = %{governor: nil, characters: characters, bodies: bodies()}
    contact = %Core.Value{value: vis, details: %{}}
    obfuscated = FactionStellarSystem.obfuscate(system, contact, @own_faction_id, 1)

    GalacticSurvey.project(obfuscated, snapshot(), vis)
  end

  defp snapshot do
    %{
      id: 7,
      name: "Alpha",
      sector_id: 1,
      position: %{x: 0, y: 0},
      type: :yellow_dwarf,
      status: :inhabited_player,
      faction: :tetrarchy,
      owner: "Player 1"
    }
  end

  defp bodies do
    [
      body(:habitable_planet, [body(:moon, [])]),
      body(:gaseous_giant, []),
      body(:asteroid_belt, [body(:asteroid, []), body(:asteroid, [])])
    ]
  end

  defp body(type, children) do
    %{
      type: type,
      industrial_factor: 1,
      technological_factor: 1,
      activity_factor: 1,
      population: 0,
      tiles: [],
      bodies: children
    }
  end

  defp admiral(id, faction_id, faction, name) do
    character(id, :admiral, faction_id, faction, name, nil)
  end

  defp spy(id, faction_id, faction, name, cover) do
    character(id, :spy, faction_id, faction, name, cover)
  end

  defp character(id, type, faction_id, faction, name, cover) do
    %Instance.StellarSystem.Character{
      id: id,
      type: type,
      name: name,
      level: 3,
      owner: %Instance.Character.Player{
        id: faction_id,
        name: "Player #{faction_id}",
        faction: faction,
        faction_id: faction_id
      },
      protection: 1,
      determination: 1,
      cover: cover
    }
  end
end
