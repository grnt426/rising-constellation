defmodule Daily.DailyCopyTest do
  @moduledoc """
  The daily page and the in-game Mutators panel render objectives and
  mutators through the client i18n (`data.objective.<key>.name`,
  `data.mutator.<key>.name`); a catalog entry without locale copy leaks the
  raw i18n key into the UI (the 2026-07-30 daily shipped
  `data.objective.fleet_in_being_raiders.name` verbatim).

  These assertions keep the locale files in lockstep with the engine
  catalogs — adding an objective or mutator without copy in every locale
  fails here.
  """
  use ExUnit.Case, async: true

  # Unlike traditions, the de mutator/objective sections are fully
  # maintained, so all three locales are checked.
  @locales ~w(en fr de)

  defp copy(locale, section) do
    "front/src/locales/#{locale}/data.json"
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["data", section])
  end

  defp assert_copy(section, keys) do
    for locale <- @locales, key <- keys do
      entries = copy(locale, section)

      assert Map.has_key?(entries, key),
             "#{locale}/data.json is missing copy for #{section} #{key}"

      for field <- ~w(name description) do
        assert is_binary(entries[key][field]) and entries[key][field] != "",
               "#{locale}/data.json: #{section} #{key} has no #{field}"
      end
    end
  end

  test "every daily objective has copy in every locale" do
    assert_copy("objective", Enum.map(Daily.Objective.catalog(), &Atom.to_string(&1.key)))
  end

  test "every mutator has copy in every locale" do
    assert_copy("mutator", Enum.map(Data.Game.Mutator.catalog(), &Atom.to_string(&1.key)))
  end
end
