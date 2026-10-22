defmodule Edict.AttachmentTest do
  use ExUnit.Case, async: true

  alias Edict.Attachment

  # a Flash map with two factions and a two-hour limit
  @map %{
    "speed" => "fast",
    "time_limit" => 120,
    "factions" => [%{"key" => "tetrarchy", "sector_number" => 1}, %{"key" => "myrmezir", "sector_number" => 1}],
    "systems" => Enum.map(1..40, &%{"key" => &1})
  }

  defp attached(map \\ @map, sources) do
    scripts =
      sources
      |> Enum.with_index(1)
      |> Enum.map(fn {source, i} ->
        %{"id" => i, "name" => "Script #{i}", "digest" => "d#{i}", "source" => source}
      end)

    Map.put(map, "scripts", scripts)
  end

  defp messages(source, map \\ @map) do
    [%{"diagnostics" => diagnostics}] = Attachment.check(attached(map, [source]))
    Enum.map(diagnostics, & &1["message"])
  end

  test "a script that suits the map checks clean" do
    assert messages("""
           setup {
             name = "Tithe"
             factions = 2
           }
           score player.credit
           on start {
             give("credit", 1000)
             notify(str(len(factions)) + " factions, led by " + factions[0].name)
           }
           every 1m {
             if find(factions, f => f.name == player.faction).rank == 1 {
               take("credit", 50)
             }
           }
           """) == []
  end

  test "a setup written for another world warns, field by field" do
    [factions] = messages("setup {\n  factions = 5\n}\nscore 1")
    assert factions =~ "written for 5 factions"
    assert factions =~ "this map has 2"

    [faction] = messages(~s|setup {\n  faction = "cardan"\n}\nscore 1|)
    assert faction =~ "cardan, which isn't on this map (tetrarchy, myrmezir)"

    [time] = messages("setup {\n  time_limit = 30m\n}\nscore 1")

    assert time ==
             ~s(It is timed for a 30m run, and this match lasts 2h. Its "at" and "every" timers don't stretch to fit: they count from the start of the match, so one set for the 30m mark goes off 1h30m before the match ends.)

    # a run longer than the match: its late timers never go off
    [longer] = messages("setup {\n  time_limit = 45m\n}\nscore 1", %{@map | "time_limit" => 30})
    assert longer =~ ~s(lasts 30m. Its "at" and "every" timers count from the start of the match)
    assert longer =~ "any set after the 30m mark never goes off"

    [rival] = messages("setup {\n  rival = true\n}\nscore 1")
    assert rival =~ "rival court"

    [daily] = messages(~s|setup {\n  systems = 4\n  neighbors = "neutral"\n}\nscore 1|)
    assert daily =~ "systems and neighbors only shape a daily"

    # nothing to say about fields left out, or that agree with the map
    assert messages(~s|setup {\n  factions = 2\n  faction = "myrmezir"\n}\nscore 1|) == []
  end

  test "patents the speed's tree lacks are named" do
    slow_only =
      Enum.find(Edict.Catalog.patent_names(), fn name ->
        key = Edict.Catalog.patent_key(name)
        key not in Enum.map(Data.Game.Patent.Content.Fast.data(), &Atom.to_string(&1.key))
      end)

    [warning] = messages(~s|setup {\n  grant_patents = ["#{slow_only}"]\n}\nscore 1|)
    assert warning =~ "#{slow_only} isn't a patent in Flash games"
    assert messages(~s|setup {\n  grant_patents = ["#{slow_only}"]\n}\nscore 1|, %{@map | "speed" => "slow"}) == []
  end

  test "the dry boot catches what only running shows: a fifth faction on a two-faction map" do
    [boot] =
      messages("""
      score 1
      on start {
        notify("The fifth house is " + factions[4].name)
      }
      """)

    assert boot =~ "When it starts for a tetrarchy player on this map, it fails"
    assert boot =~ "can't read .name"
  end

  test "a score or an on end that fails is caught too" do
    [score] = messages("score factions[3].victory_points")
    assert score =~ "fails"
    [on_end] = messages("score 1\non end {\n  notify(players[9].name)\n}")
    assert on_end =~ "fails"
  end

  test "a script with mistakes is flagged as an error, not run" do
    [d] = Attachment.check(attached(["score player.credt"])) |> hd() |> Map.fetch!("diagnostics")
    assert d["severity"] == "error"
    assert d["message"] =~ "1 mistake to fix"
  end

  test "two scripts discounting the same patent: the later one says the lower price applies" do
    [first, second] =
      Attachment.check(
        attached([
          ~s|setup {\n  name = "A"\n  patent_discounts = {armoring: 50%}\n}\nscore 1|,
          ~s|setup {\n  name = "B"\n  patent_discounts = {armoring: 20%}\n}\nscore 1|
        ])
      )

    assert first["diagnostics"] == []
    assert [%{"message" => m}] = second["diagnostics"]
    assert m =~ "Script 1 discounts armoring too (to 50%, this one to 20%)"
  end

  test "a match boots with every script's grants and mutators and the lowest discount" do
    mutator = hd(Edict.Catalog.mutator_keys())

    game_data =
      attached(Map.put(@map, "mutators", [%{"key" => "existing"}]), [
        ~s|setup {\n  grant_patents = ["armoring"]\n  patent_discounts = {armoring: 50%}\n  mutators = ["#{mutator}"]\n}\nscore 1|,
        ~s|setup {\n  grant_patents = ["armoring", "precision_cranes"]\n  patent_discounts = {armoring: 20%}\n}\nscore 1|
      ])

    prepared = Attachment.prepare_instance(game_data)
    setup = prepared["edict"]["setup"]
    assert setup["grant_patents"] == ["capital_1", Edict.Catalog.patent_key("precision_cranes")]
    assert setup["patent_discounts"] == %{"capital_1" => 0.2}
    assert setup["markup_free"] == true
    assert prepared["mutators"] == [%{"key" => "existing"}, %{"key" => mutator}]

    # nothing attached, nothing changed
    assert Attachment.prepare_instance(@map) == @map
  end

  test "only frozen entries with text count as attached" do
    assert Attachment.scripts(%{"scripts" => [%{"id" => 1}, "x", %{"source" => "score 1", "digest" => "d"}]}) ==
             [%{"source" => "score 1", "digest" => "d"}]

    refute Attachment.scripted?(%{})
  end

  test "the map's facts: mode by speed, factions, time limit in seconds" do
    assert %{mode: "flash", factions: ["tetrarchy", "myrmezir"], time_limit: 7200.0, systems: 40} =
             Attachment.facts(@map)

    assert Attachment.mode("slow") == "legacy"
    assert Attachment.mode(:medium) == "tactic"
  end
end
