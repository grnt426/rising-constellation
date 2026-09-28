defmodule Daily.ObjectiveRotationTest do
  @moduledoc """
  Pins the objective rotation (Daily.Rotation): shuffled decks with a
  cooldown from the first epoch on, the legacy independent roll frozen
  before it.
  """

  use ExUnit.Case, async: true

  alias Daily.Rotation

  @first_epoch hd(Rotation.epochs()).from

  defp dates(from, count), do: Enum.map(0..(count - 1), &Date.add(from, &1))

  test "dates before the first epoch keep their legacy objective" do
    # What production actually played; the Discord blast and leaderboards
    # re-derive these from the date, so they must never move.
    played = %{
      ~D[2026-09-08] => :tide_of_invention,
      ~D[2026-09-10] => :tide_of_invention,
      ~D[2026-09-11] => :tide_of_invention,
      ~D[2026-09-16] => :hegemon,
      ~D[2026-09-18] => :hegemon,
      ~D[2026-09-19] => :hegemon,
      ~D[2026-09-25] => :weight_of_faith,
      ~D[2026-09-26] => :weight_of_faith,
      ~D[2026-09-27] => :charter_of_prosperity
    }

    for {date, objective} <- played do
      assert Rotation.objective_for(date) == objective, "#{date} changed"
    end
  end

  test "no objective repeats within the cooldown, across the cut-over and for years after" do
    cooldown = Rotation.cooldown_days()
    # start a cooldown's worth before the epoch so the legacy→deck seam is covered
    start = Date.add(@first_epoch, -(cooldown - 1))
    picks = dates(start, 3 * 365) |> Enum.map(&{&1, Rotation.objective_for(&1)})

    # every window ends on a rotation day; its pick must be new to the window
    # (the legacy days before the epoch repeat freely — that's the bug)
    picks
    |> Enum.chunk_every(cooldown, 1, :discard)
    |> Enum.each(fn window ->
      {previous, [{_date, pick}]} = Enum.split(window, cooldown - 1)

      refute pick in Enum.map(previous, &elem(&1, 1)),
             "repeat within #{cooldown} days: #{inspect(window)}"
    end)
  end

  test "every deck plays each objective exactly once" do
    %{objectives: objectives} = hd(Rotation.epochs())
    n = length(objectives)

    for deck <- 0..19 do
      played = dates(Date.add(@first_epoch, deck * n), n) |> Enum.map(&Rotation.objective_for/1)
      assert Enum.sort(played) == Enum.sort(objectives), "deck #{deck}: #{inspect(played)}"
    end
  end

  test "is deterministic and accepts ISO strings" do
    date = Date.add(@first_epoch, 40)
    assert Rotation.objective_for(date) == Rotation.objective_for(Date.to_iso8601(date))
  end

  test "the generator's objective is the rotation's" do
    for date <- dates(Date.add(@first_epoch, -3), 30) do
      gd = Daily.Generator.for_date(date)
      assert gd["daily"]["objective"] == Atom.to_string(Rotation.objective_for(date))
    end
  end

  test "the latest epoch deals exactly the objective catalog" do
    # Adding an objective? Append a new epoch to Daily.Rotation, dated at a
    # rotation after your deploy — never edit an existing epoch's list, or
    # past days' objectives change.
    latest = List.last(Rotation.epochs())
    assert Enum.sort(latest.objectives) == Enum.sort(Daily.Objective.keys())
  end

  test "epochs are ascending, and each has at least a cooldown's worth of objectives" do
    froms = Enum.map(Rotation.epochs(), & &1.from)
    assert froms == Enum.sort(froms, Date)

    for epoch <- Rotation.epochs() do
      assert length(epoch.objectives) >= Rotation.cooldown_days()
      assert Enum.uniq(epoch.objectives) == epoch.objectives
      assert Enum.all?(epoch.objectives, &Daily.Objective.get/1)
    end
  end
end
