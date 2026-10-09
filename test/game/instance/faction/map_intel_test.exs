defmodule Instance.Faction.MapIntelTest do
  use ExUnit.Case, async: true

  alias Instance.Faction.MapIntel

  describe "project/2 — systems" do
    test "keeps the faction's own systems and any system with agents or a siege" do
      rows = [
        row(1, :tetrarchy, []),
        row(2, :cardan, [agent(10, :admiral, :tetrarchy, 900.0)]),
        row(3, :cardan, []),
        row(4, nil, [], siege: true)
      ]

      assert [1, 2, 4] = rows |> MapIntel.project(:tetrarchy) |> Map.fetch!(:systems) |> Enum.map(& &1.id)
    end

    test "agents carry what the map draws and nothing that names them" do
      [system] =
        MapIntel.project([row(2, :cardan, [agent(10, :admiral, :tetrarchy, 900.0)])], :tetrarchy).systems

      assert system.own == false
      assert system.agents == [%{id: 10, type: :admiral, faction: :tetrarchy, level: 3, upkeep: 900.0}]
    end

    test "a system whose agents cannot be seen (nil) is not listed for them" do
      assert MapIntel.project([row(3, :cardan, nil)], :tetrarchy).systems == []
    end
  end

  describe "project/2 — sectors" do
    test "sums each faction's income sector by sector, over the systems that can be read" do
      rows = [
        row(1, :tetrarchy, [], sector_id: 1, current_sci: 4, current_appeal: 2, current_credit: 30),
        row(2, :tetrarchy, [], sector_id: 1, current_sci: 1, current_appeal: 1, current_credit: 20),
        row(3, :tetrarchy, [], sector_id: 2, current_sci: 7, current_appeal: 0, current_credit: 5),
        # another faction, read at contact 4 or more
        row(4, :cardan, [], sector_id: 1, current_sci: 9, current_appeal: 3, current_credit: 100),
        # ... and one of its systems the faction cannot read: not counted
        row(5, :cardan, [], sector_id: 1),
        # neutral systems belong to no faction
        row(6, nil, [], sector_id: 1, current_credit: 50)
      ]

      sectors =
        rows |> MapIntel.project(:tetrarchy) |> Map.fetch!(:sectors) |> Enum.sort_by(&{&1.id, &1.faction})

      assert [
               %{id: 1, faction: :cardan, systems: 1, technology: 9, ideology: 3, credit: 100},
               %{id: 1, faction: :tetrarchy, systems: 2, technology: 5, ideology: 3, credit: 50},
               %{id: 2, faction: :tetrarchy, systems: 1, technology: 7, ideology: 0, credit: 5}
             ] = sectors
    end

    test "a faction with no readable system in a sector has no entry" do
      assert MapIntel.project([row(5, :cardan, [], sector_id: 1)], :tetrarchy).sectors == []
    end
  end

  defp row(id, faction, agents, extra \\ []) do
    Map.merge(
      %{
        id: id,
        sector_id: 1,
        faction: faction,
        agents: agents,
        siege: false,
        defense: nil,
        stability: nil,
        counter_intelligence: nil,
        current_prod: nil,
        current_sci: nil,
        current_appeal: nil,
        current_credit: nil
      },
      Map.new(extra)
    )
  end

  defp agent(id, type, faction, upkeep) do
    %{id: id, type: type, name: "Agent #{id}", level: 3, faction: faction, owner_name: "Someone", upkeep: upkeep}
  end
end
