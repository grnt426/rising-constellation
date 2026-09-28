defmodule Data.Game.Faction do
  use TypedStruct
  use Util.MakeEnumerable

  def jason(), do: [except: [:initial_character_spec2, :initial_character_skills]]

  typedstruct enforce: true do
    field(:key, atom())
    field(:culture, atom())
    field(:initial_character_type, atom())
    field(:initial_character_spec1, atom())
    field(:initial_character_spec2, atom())
    field(:initial_character_skills, [number()])
    field(:traditions, [%{}])
    field(:theme, String.t())
    field(:color, String.t())
    # false for bot-held factions (the Wave Defense Rebellion): they exist in
    # the catalog so the engine and the in-game client can render them, but
    # player-facing faction pickers must not offer them.
    field(:playable, boolean(), default: true)
  end

  @doc "The catalog factions a player can choose, in declaration order."
  def playable(factions), do: Enum.filter(factions, & &1.playable)

  def specs do
    "Elixir." <> module = Atom.to_string(__MODULE__)
    module = "#{module}.Content"

    [
      %{metadata: [], content_name: "faction", module: module, sources: nil}
    ]
  end
end
