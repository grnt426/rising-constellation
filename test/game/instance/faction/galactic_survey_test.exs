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

  describe "cache" do
    test "a cache never built has nothing to serve" do
      assert GalacticSurvey.lookup(nil) == :build
      assert GalacticSurvey.lookup(GalacticSurvey.new()) == :build
    end

    test "freshly stored rows are served as they are" do
      assert {:fresh, [:row]} = GalacticSurvey.lookup(GalacticSurvey.store([:row]))
    end

    test "an aged cache is served while it is rebuilt, by one rebuild at a time" do
      aged = %{GalacticSurvey.store([:row]) | expires_at: System.system_time(:millisecond) - 1_000}

      assert {:stale, [:row]} = GalacticSurvey.lookup(aged)
      assert {:refreshing, [:row]} = aged |> GalacticSurvey.mark_refreshing() |> GalacticSurvey.lookup()
    end

    test "a rebuild that never reported back is started again" do
      now = System.system_time(:millisecond)
      stuck = %{GalacticSurvey.store([:row]) | expires_at: now - 1_000, refreshing_until: now - 1}

      assert {:stale, [:row]} = GalacticSurvey.lookup(stuck)
    end

    test "a cache left untouched for minutes is not served" do
      old = %{GalacticSurvey.store([:row]) | expires_at: System.system_time(:millisecond) - 600_000}

      assert GalacticSurvey.lookup(old) == :build
    end

    test "a cache restored from before the refresh mark still reads" do
      legacy = GalacticSurvey.store([:row]) |> Map.delete(:refreshing_until)
      legacy = %{legacy | expires_at: System.system_time(:millisecond) - 1_000}

      assert {:stale, [:row]} = GalacticSurvey.lookup(legacy)
    end
  end

  describe "fleet upkeep" do
    test "another faction's fleet shows its upkeep from visibility 4 only" do
      raider = %{admiral(10, @foreign_faction_id, :cardan, "Raider") | maintenance: 1200.0}

      assert [%{upkeep: nil}] = survey_row(3, [raider]).agents
      assert [%{upkeep: 1200.0}] = survey_row(4, [raider]).agents
    end

    test "the faction's own fleet keeps its upkeep whatever the contact on the system" do
      own = %{admiral(11, @own_faction_id, :tetrarchy, "Warden") | maintenance: 800.0}
      raider = %{admiral(10, @foreign_faction_id, :cardan, "Raider") | maintenance: 1200.0}

      system = %{governor: nil, characters: [own, raider], bodies: bodies()}
      contact = %Core.Value{value: 2, details: %{}}

      row =
        system
        |> FactionStellarSystem.obfuscate(contact, @own_faction_id, 1)
        |> GalacticSurvey.reveal_own_fleets(system, :tetrarchy)
        |> GalacticSurvey.project(snapshot(), 2)

      assert [%{id: 10, upkeep: nil}, %{id: 11, upkeep: 800.0}] = Enum.sort_by(row.agents, & &1.id)
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
