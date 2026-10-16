defmodule Daily.DestroyersBlueprintTest do
  @moduledoc """
  The Destroyer's Blueprint shipped unwinnable: its patent ends an 11-patent
  line worth about 625,000 technology with the per-patent markup, several
  times what a run banks. The day now grants the line up to the fourth
  shipyard, pins Open Science and keeps technology-income and patent-cost
  banes away; granted patents no longer raise prices on any day.
  """
  use RC.DataCase, async: false

  alias Daily.{Generator, Objective}
  alias Data.Game.Mutator

  @moduletag timeout: 180_000

  # The Destroyer's line, oldest first; all but the last link is granted.
  @granted_line [
    :citadel,
    :shipyard_1,
    :merge_fighter_1,
    :shipyard_2,
    :merge_fighter_2,
    :merge_corvette_1,
    :shipyard_3,
    :merge_fighter_3,
    :merge_corvette_2,
    :shipyard_4
  ]

  test "the objective grants the line, pins Open Science and bans the banes that undercut it" do
    objective = Objective.get(:destroyers_blueprint)

    assert Objective.granted_patents(objective) == [:shipyard_4]
    assert Objective.pinned_mutators(objective) == [:open_science]
    assert Objective.banned_axes(objective) == [:technology_income, :patent_cost]

    # other objectives carry none of it
    assert Objective.pinned_mutators(:golden_flow) == []
    assert Objective.banned_axes(:golden_flow) == []
  end

  test "every Destroyer day carries Open Science, one rolled boon and an allowed bane" do
    days =
      for offset <- 0..364,
          date = Date.add(~D[2026-06-20], offset) |> Date.to_iso8601(),
          gd = Generator.for_date(date),
          gd["daily"]["objective"] == "destroyers_blueprint",
          do: {date, gd}

    assert length(days) >= 5

    for {date, gd} <- days do
      [first | _] = keys = Enum.map(gd["mutators"], & &1["key"])
      mutators = Enum.map(keys, &Mutator.get/1)

      assert first == "open_science", "#{date}: #{inspect(keys)}"
      assert length(Enum.uniq(keys)) == 3
      assert Enum.count(mutators, &(&1.polarity == :positive)) == 2
      [bane] = Enum.filter(mutators, &(&1.polarity == :negative))
      refute bane.axis in [:technology_income, :patent_cost], "#{date}: bane #{bane.key}"
    end
  end

  test "days that pin and ban nothing roll exactly the mutators they always had" do
    # Recorded from the generator before pinned mutators existed.
    for {date, keys} <- [
          {"2026-06-26", ~w(cheap_steel bull_market failing_reactors)},
          {"2026-07-01", ~w(panopticon festival_days heavy_tithes)},
          {"2026-08-06", ~w(open_science veteran_shipwrights porous_borders)},
          {"2026-10-01", ~w(prodigies bull_market sullen_populace)}
        ] do
      assert Enum.map(Generator.for_date(date)["mutators"], & &1["key"]) == keys, date
    end
  end

  test "a live Destroyer day starts with the line and granted patents don't raise prices" do
    # 2026-10-16 is a Destroyer day that shipped unwinnable. Past dates never
    # change objective (Daily.Rotation), so it stays a fixture.
    date = "2026-10-16"
    assert Daily.definition_for(date).objective.key == :destroyers_blueprint

    profile = create_profile()
    {:ok, %{instance_id: iid}} = Daily.Boot.boot_persisted(profile, date)
    on_exit(fn -> Instance.Manager.destroy(iid) end)
    {:ok, :started, _} = Instance.Manager.call(iid, :start)

    assert Instance.Mutators.active?(iid, :open_science)

    {:ok, player} = Game.call(iid, :player, profile.id, :get_state)
    assert player.patents == @granted_line
    assert Instance.Player.Player.granted_patents(iid) == @granted_line
    assert Instance.Player.Player.priced_patent_count(player) == 0

    # First research of the day: base price, halved by Open Science, with no
    # markup for the ten granted patents (it would be 37.5 if they counted).
    :ok = Game.call(iid, :player, profile.id, {:purchase_patent, :infra_open_1})
    {:ok, after_first} = Game.call(iid, :player, profile.id, :get_state)
    assert_in_delta player.technology.value - after_first.technology.value, 50 * 0.5, 0.01

    # The next one carries the markup for the one patent researched.
    :ok = Game.call(iid, :player, profile.id, {:purchase_patent, :orbital_credit})
    {:ok, after_second} = Game.call(iid, :player, profile.id, :get_state)
    assert_in_delta after_first.technology.value - after_second.technology.value, 50 * 1.05 * 0.5, 0.01
    assert Instance.Player.Player.priced_patent_count(after_second) == 2
  end

  defp create_profile do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "destroyer-test@tetrarchyfalls.local",
        password: "destroyer-test-password",
        name: "DestroyerTest",
        role: :user,
        status: :active
      })

    {:ok, profile} = RC.Accounts.create_profile(%{account_id: account.id, name: "DestroyerTest", avatar: "todo"})
    profile
  end
end
