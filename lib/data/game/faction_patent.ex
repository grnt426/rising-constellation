defmodule Data.Game.FactionPatent do
  use TypedStruct
  use Util.MakeEnumerable

  @moduledoc """
  Faction-level research: the treasury analogue of the player patent
  tree. Purchased by the government with treasury TECHNOLOGY (see
  `Instance.Faction.Government.purchase_patent/4`); once purchased its
  bonuses apply to every faction member permanently — patents are
  passive infrastructure, unlike lexes which must be enacted as laws.

  Content is speed-independent for now (treasury economics scale with
  the game already); per-speed variants can come at balance time.
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
      %{metadata: [], content_name: "faction_patent", module: module, sources: nil}
    ]
  end
end
