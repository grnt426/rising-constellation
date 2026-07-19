defmodule Data.FactionTraditionCopyTest do
  @moduledoc """
  Guards the faction-tradition copy against re-acquiring hardcoded numbers.

  The locale files used to spell the bonus out in prose ("Production: +30")
  while the engine held the real figure in
  `lib/data/game/content/faction.ex`. The two drifted: Synelle advertised
  +30 production and granted +20 for as long as the public repo has
  existed. The number is now derived from the serialized `Core.Bonus` in
  `front/src/utils/bonus.js`, and the locale carries only a label.

  These assertions keep it that way — a translator re-adding "+30" to a
  label, or a new tradition shipping without copy, fails here.
  """
  use ExUnit.Case, async: true

  @locales ~w(en fr)
  # `de` is a partial translation with no tradition entries at all; it
  # falls back to `en` at runtime, so there is nothing to check.

  defp tradition_copy(locale) do
    "front/src/locales/#{locale}/data.json"
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["data", "tradition"])
  end

  defp tradition_keys do
    Data.Game.Faction.Content.data()
    |> Enum.flat_map(fn faction -> Enum.map(faction.traditions, &Atom.to_string(&1.key)) end)
  end

  test "every engine tradition has a label in every locale" do
    for locale <- @locales, key <- tradition_keys() do
      copy = tradition_copy(locale)

      assert Map.has_key?(copy, key),
             "#{locale}/data.json is missing copy for tradition #{key}"

      assert is_binary(copy[key]["bonus_label"]) and copy[key]["bonus_label"] != "",
             "#{locale}/data.json: tradition #{key} has no bonus_label"
    end
  end

  test "labels carry no hardcoded numbers" do
    for locale <- @locales, {key, entry} <- tradition_copy(locale) do
      label = entry["bonus_label"] || ""

      refute label =~ ~r/\d/,
             """
             #{locale}/data.json: tradition #{key} label #{inspect(label)} \
             contains a number. The figure is rendered from the engine's \
             Core.Bonus by front/src/utils/bonus.js — putting it in the copy \
             is what let Synelle advertise +30 while granting +20.
             """
    end
  end

  test "the old numeric `bonus` key is gone" do
    for locale <- @locales, {key, entry} <- tradition_copy(locale) do
      refute Map.has_key?(entry, "bonus"),
             "#{locale}/data.json: tradition #{key} still has the retired `bonus` key"
    end
  end
end
