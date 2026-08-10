defmodule Data.Game.FactionBuilding do
  use TypedStruct
  use Util.MakeEnumerable

  @moduledoc """
  Faction buildings: constructions ordered by a cabinet seat into a
  system's 2×2 build-slot station, paid (construction AND upkeep) from
  the faction treasury, gated by a faction patent. Benefits land on the
  system itself unless the building says otherwise. See
  docs/faction-buildings.md.

  `shape` is `%{cols, rows}` on the 2×2 grid — a building may span
  several slots. `labor` is production points; construction advances at
  the host system's production rate on a track parallel to the player's
  own queue. `upkeep` is per unit-time, billed on the faction tick.

  Content is speed-independent for now, same reasoning as
  `Data.Game.FactionPatent`.
  """

  def jason(), do: []

  typedstruct enforce: true do
    field(:key, atom())
    # cabinet seat that may order/cancel/demolish it (:military | :economy)
    field(:seat, atom())
    # faction patent required before this building may be ordered
    field(:patent, atom() | nil)
    field(:shape, %{cols: integer(), rows: integer()})
    # at most one per system
    field(:unique, boolean())
    # dispatch marker for bespoke behavior (:gateway | :agent_training |
    # :cyber_command | nil for pure-bonus buildings)
    field(:effect, atom() | nil)
    field(:levels, [
      %{
        level: integer(),
        cost: %{credit: integer(), technology: integer(), ideology: integer()},
        labor: integer(),
        upkeep: %{credit: number(), technology: number(), ideology: number()},
        bonus: [%Core.Bonus{}]
      }
    ])
  end

  def specs do
    "Elixir." <> module = Atom.to_string(__MODULE__)
    module = "#{module}.Content"

    [
      %{metadata: [], content_name: "faction_building", module: module, sources: nil}
    ]
  end
end
