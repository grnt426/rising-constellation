defmodule RC.Archive.PureTest do
  use ExUnit.Case, async: true

  alias RC.Archive.{EventStats, Importer, SnapshotStats}

  @start ~U[2026-08-22 16:00:00.000000Z]

  defp at(days, hours \\ 0), do: DateTime.add(@start, days * 86_400 + hours * 3_600, :second)
  defp name(iid, ts), do: "nightly-x-snapshot-#{iid}-#{DateTime.to_unix(ts)}1234"

  describe "parse_snapshot_name/1" do
    test "reads instance id and unix timestamp, ignoring prefixes and random suffix" do
      assert {121, ts} = Importer.parse_snapshot_name("nightly-20260823T084843Z-snapshot-121-17874748189878")
      assert DateTime.to_unix(ts) == 1_787_474_818
    end

    test "rejects other files" do
      assert Importer.parse_snapshot_name("rc-db-20260823.dump") == nil
    end
  end

  describe "day_of/2" do
    test "day 1 is the first 24h after start" do
      assert EventStats.day_of(at(0, 1), @start) == 1
      assert EventStats.day_of(at(1, 0), @start) == 2
      assert EventStats.day_of(NaiveDateTime.add(DateTime.to_naive(@start), 3 * 86_400 + 5), @start) == 4
      assert EventStats.day_of(DateTime.add(@start, -60, :second), @start) == 1
    end
  end

  describe "select_samples/5" do
    test "keeps the latest pre-victory snapshot per day and ignores other instances" do
      ended = at(2, 20)

      paths = [
        name(121, at(0, 16)),
        name(121, at(0, 20)),
        name(121, at(2, 10)),
        name(121, at(2, 19)),
        # post-victory, same day: must not replace the pre-victory sample
        name(121, at(2, 22)),
        name(99, at(1, 1))
      ]

      picks = Importer.select_samples(paths, 121, @start, ended, 3)

      assert Map.keys(picks) |> Enum.sort() == [1, 3]
      assert picks[1].ts == at(0, 20)
      assert picks[3].ts == at(2, 19)
      refute picks[3].post_victory
    end

    test "falls back to the earliest post-victory snapshot when the last day has none" do
      ended = at(2, 1)
      paths = [name(121, at(1, 5)), name(121, at(2, 9)), name(121, at(2, 6))]

      picks = Importer.select_samples(paths, 121, @start, ended, 3)

      assert picks[2].ts == at(1, 5)
      assert picks[3].ts == at(2, 6)
      assert picks[3].post_victory
    end
  end

  describe "SnapshotStats.extract/1" do
    defp value(v), do: %{__struct__: Core.Value, value: v, details: %{}}
    defp dv(v, change, details), do: %{__struct__: Core.DynamicValue, value: v, change: change, details: details}
    defp part(v), do: %{reason: :x, value: v}
    defp agent(type, data), do: %{module: :m, state: %{type: type, agent_id: 1, data: data}}

    defp system(id, status, owner_faction, defense) do
      %{
        id: id,
        status: status,
        owner: owner_faction && %{faction: owner_faction},
        defense: value(defense),
        counter_intelligence: value(10),
        remove_contact: dv(20_000, 4.0, %{}),
        happiness: value(50),
        workforce: 30,
        habitation: value(40),
        production: value(100),
        credit: value(12),
        technology: value(3),
        ideology: value(1),
        radar: value(2),
        mobility: value(5),
        fighter_lvl: value(1),
        corvette_lvl: value(0),
        frigate_lvl: value(0),
        capital_lvl: value(0),
        siege: nil,
        bodies: [
          %{tiles: [%{building_status: :built, building_key: :monument_dome}], bodies: []}
        ]
      }
    end

    defp player(id, faction, credit_parts) do
      %{
        id: id,
        registration_id: id * 10,
        name: "p#{id}",
        faction: faction,
        is_active: true,
        credit:
          dv(1_000, Enum.sum(Enum.flat_map(credit_parts, fn {_, ps} -> Enum.map(ps, & &1.value) end)), credit_parts),
        technology: dv(10, 1, %{}),
        ideology: dv(5, 1, %{}),
        max_policies: 4,
        patents: [:citadel],
        doctrines: [:agent, :spy_1],
        policies: [:agent],
        stellar_systems: [],
        dominions: [],
        characters: [],
        character_deck: []
      }
    end

    test "aggregates income, per-system averages, malware, fleets and unlocks per faction" do
      snapshot = %{
        instance_data: [],
        agents_data: [
          %{module: Spatial.Supervisor, state: []},
          agent(:faction, %{id: 1, key: :tetrarchy, contacts: %{}}),
          agent(:faction, %{
            id: 2,
            key: :myrmezir,
            contacts: %{
              # 2 informers on a tetrarchy system, 1 on a neutral one
              1 => %{details: %{informer: [part(1), part(1)], explorer: [part(1)]}},
              3 => %{details: %{informer: [part(1)]}}
            }
          }),
          agent(:player, player(1, :tetrarchy, %{system: [part(300)], character_wages: [part(-100)]})),
          agent(:player, player(2, :myrmezir, %{system: [part(50)]})),
          agent(:stellar_system, system(1, :inhabited_player, :tetrarchy, 10)),
          agent(:stellar_system, system(2, :inhabited_player, :tetrarchy, 30)),
          agent(:stellar_system, system(3, :inhabited_neutral, nil, 0)),
          agent(:stellar_system, system(4, :inhabited_dominion, :myrmezir, 7)),
          agent(:character, %{
            id: 9,
            type: :admiral,
            status: :on_board,
            level: 5,
            owner: %{faction: :tetrarchy},
            army: %{
              maintenance: value(120),
              tiles: [
                %{ship_status: :filled, ship: %{key: :frigate_2v2, level: 3, experience: 40.0}},
                %{ship_status: :filled, ship: %{key: :fighter_1, level: 1, experience: 10.0}},
                %{ship_status: :empty, ship: nil}
              ]
            }
          })
        ]
      }

      stats = SnapshotStats.extract(snapshot)
      t = stats.factions["tetrarchy"]
      m = stats.factions["myrmezir"]

      assert t["systems"] == 2
      assert m["dominions"] == 1
      assert t["credit_gross"] == 300
      assert t["credit_expense"] == -100
      assert t["credit_net"] == 200
      assert t["credit_src_character_wages"] == -100
      assert t["sys_avg_defense"] == 20.0
      assert t["sys_avg_cybersecurity"] == 4.0
      assert t["dom_avg_defense"] == nil
      assert m["dom_avg_defense"] == 7.0
      assert t["sys_avg_malware"] == 1.0
      assert t["malware_suffered"] == 2
      assert m["malware_planted_enemy"] == 2
      assert m["malware_planted_neutral"] == 1
      assert t["ships_total"] == 2
      assert t["ships_frigate"] == 1
      assert t["ships_avg_xp"] == 25.0
      assert t["fleet_maintenance"] == 120
      assert t["agents_admiral"] == 1
      assert t["megastructures_monument_dome"] == 2
      assert t["avg_lex_slots"] == 4.0
      assert stats.unlocks["lex"]["spy_1"] == %{"tetrarchy" => 1, "myrmezir" => 1}
      assert stats.system_codes[4] == {"myrmezir", "dominion"}
      assert stats.galaxy == nil
    end
  end
end
