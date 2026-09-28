defmodule RC.Archive.ExportTest do
  use ExUnit.Case, async: true

  alias RC.Archive.{Export, ExportLimiter, FactionDay, Match, Player, Unlock, Xlsx}

  defp unzip(binary) do
    {:ok, files} = :zip.unzip(binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  describe "Xlsx.build/1" do
    test "writes a valid package with escaped inline strings, numbers and a bold header" do
      binary =
        Xlsx.build([
          {"Sheet/with:bad*chars and a very long name indeed",
           [["name", "score"], ["<Avok & co>", 14_900], ["=cmd()", 1.5], [nil, true]]},
          {"Second", [["a"]]}
        ])

      assert <<"PK", _::binary>> = binary
      files = unzip(binary)

      assert Map.has_key?(files, "[Content_Types].xml")
      assert Map.has_key?(files, "xl/styles.xml")
      assert files["xl/workbook.xml"] =~ ~s(name="Sheet with bad chars and a very")
      assert files["xl/workbook.xml"] =~ ~s(name="Second")

      sheet = files["xl/worksheets/sheet1.xml"]
      assert sheet =~ ~s(<c r="A1" t="inlineStr" s="1">)
      assert sheet =~ "&lt;Avok &amp; co&gt;"
      assert sheet =~ ~s(<c r="B2"><v>14900</v></c>)
      assert sheet =~ ~s(<c r="B3"><v>1.5</v></c>)
      # Formula-looking text stays a plain string.
      assert sheet =~ ~s[<t xml:space="preserve">=cmd()</t>]
      refute sheet =~ "<f>"
      assert sheet =~ ~s(<c r="B4" t="b"><v>1</v></c>)
      refute sheet =~ ~s(r="A4")
      assert sheet =~ ~s(state="frozen")
    end

    test "column letters" do
      assert Xlsx.column(1) == "A"
      assert Xlsx.column(26) == "Z"
      assert Xlsx.column(27) == "AA"
      assert Xlsx.column(703) == "AAA"
    end
  end

  describe "Export.sheets/1" do
    test "lays the archive out as tidy sheets" do
      match = %Match{
        instance_id: 121,
        name: "Citadel – Legacy",
        map_name: "Citadel",
        speed: "slow",
        started_at: ~U[2026-08-22 15:59:43.624519Z],
        ended_at: ~U[2026-09-13 12:54:48.000000Z],
        victory_type: "win_on_time",
        winner_faction: "tetrarchy",
        player_count: 2,
        system_count: 2,
        factions: [%{"key" => "tetrarchy", "rank" => 1, "victory_points" => 7}],
        summary: %{
          "days" => 2,
          "sample_days" => [2],
          "ut_per_hour" => 20,
          "totals" => %{"tetrarchy" => %{"battles" => 3}},
          "activity" => %{"5" => %{"raid" => 2}}
        },
        map: %{
          "faction_keys" => ["tetrarchy", "myrmezir"],
          "sectors" => [%{"id" => 0, "name" => "Zinavitzan", "victory_points" => 4}],
          "systems" => [
            %{"id" => 5, "name" => "Actar", "x" => 1.5, "y" => 2.0, "sector_id" => 0, "type" => "red_dwarf"}
          ],
          "days" => [%{"day" => 2, "sectors" => %{"0" => "tetrarchy"}, "systems" => [5]}]
        },
        faction_days: [
          %FactionDay{
            faction: "tetrarchy",
            day: 2,
            sampled_at: ~U[2026-08-24 08:00:00.000000Z],
            metrics: %{"credit_net" => 10.5, "track_conquest_milestones" => [0.0, 5.0]}
          },
          %FactionDay{faction: "tetrarchy", day: 1, sampled_at: nil, metrics: %{"battles" => 1}}
        ],
        players: [
          %Player{
            name: "Avok",
            faction: "tetrarchy",
            profile_id: 15,
            metrics: %{"final_points" => 900},
            series: [[1, 400, 2, 50], [2, 900, 3, 70]]
          }
        ],
        unlocks: [%Unlock{kind: "lex", key: "spy_1", faction: "tetrarchy", player_count: 1, first_day: 2}]
      }

      sheets = Map.new(Export.sheets(match))

      assert Enum.map(Export.sheets(match), &elem(&1, 0)) ==
               ["About", "Factions", "Faction days", "Players", "Player score by day", "Unlocks", "Sectors", "Systems"]

      assert ["day", "faction", "sampled_at", "battles", "credit_net", "track_conquest_milestones"] =
               hd(sheets["Faction days"])

      assert Enum.at(sheets["Faction days"], 1) == [1, "tetrarchy", nil, 1, nil, nil]
      assert Enum.at(sheets["Faction days"], 2) == [2, "tetrarchy", "2026-08-24T08:00:00Z", nil, 10.5, "0.0, 5.0"]
      assert Enum.at(sheets["Factions"], 1) |> List.last() == 3
      assert length(sheets["Player score by day"]) == 3
      assert Enum.at(sheets["Sectors"], 1) == [0, "Zinavitzan", 4, "tetrarchy"]
      assert Enum.at(sheets["Systems"], 1) == [5, "Actar", 1.5, 2.0, 0, "red_dwarf", 0, 2, 0, 0, 0, "myrmezir dominion"]

      assert Export.filename(match) == "legacy-archive-121-citadel-legacy.xlsx"
      assert <<"PK", _::binary>> = Export.to_xlsx(match)
    end
  end

  describe "ExportLimiter" do
    setup do
      name = :"limiter_#{System.unique_integer([:positive])}"
      start_supervised!({ExportLimiter, name: name})
      %{server: name}
    end

    test "one export per minute", %{server: s} do
      assert ExportLimiter.check(1, 0, s) == :ok
      assert ExportLimiter.check(1, 20_000, s) == {:error, 40}
      # Denied attempts are not recorded, so they don't push the window out.
      assert ExportLimiter.check(1, 59_999, s) == {:error, 1}
      assert ExportLimiter.check(1, 60_000, s) == :ok
      # Other accounts are independent.
      assert ExportLimiter.check(2, 60_001, s) == :ok
    end

    test "ten exports per rolling hour", %{server: s} do
      for i <- 0..9, do: assert(ExportLimiter.check(7, i * 61_000, s) == :ok)

      # 11th: minute window is clear but the oldest of the ten is only 610s old.
      assert ExportLimiter.check(7, 10 * 61_000, s) == {:error, 3_600 - 610}
      assert ExportLimiter.check(7, 3_600_000, s) == :ok
    end
  end
end
