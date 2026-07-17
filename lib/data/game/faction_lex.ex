defmodule Data.Game.FactionLex do
  use TypedStruct
  use Util.MakeEnumerable

  @moduledoc """
  Faction laws: the treasury analogue of the player doctrine tree.
  Purchased by the government with treasury IDEOLOGY, then ENACTED into
  a limited number of law slots (`government_max_laws`) with a change
  cooldown (`government_law_cooldown`) — the faction-level mirror of
  the player policy model. Only enacted laws apply their bonuses.
  """

  def jason(), do: []

  typedstruct enforce: true do
    field(:key, atom())
    field(:ancestor, atom() | nil)
    field(:cost, integer())
    field(:bonus, [%Core.Bonus{}])
  end

  def specs do
    "Elixir." <> module = Atom.to_string(__MODULE__)
    module = "#{module}.Content"

    [
      %{metadata: [], content_name: "faction_lex", module: module, sources: nil}
    ]
  end
end
