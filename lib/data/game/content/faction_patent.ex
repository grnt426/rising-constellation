defmodule Data.Game.FactionPatent.Content do
  @moduledoc """
  First slice of the faction research tree — every node here works
  through the existing bonus pipeline. The marquee capability nodes
  (Gateway Network, SLSD Command Uplink) are reserved for the phase
  that builds their systems; see docs/faction-government.md §5.2.

      research_compact
      ├── deep_space_relay ── counterintel_grid
      └── standardized_freight ── chartered_shipyards
  """

  def data do
    [
      %Data.Game.FactionPatent{
        key: :research_compact,
        ancestor: nil,
        cost: 800,
        bonus: [
          %Core.Bonus{from: :direct, to: :player_technology, type: :add, value: 2}
        ]
      },
      %Data.Game.FactionPatent{
        key: :deep_space_relay,
        ancestor: :research_compact,
        cost: 1_600,
        bonus: [
          %Core.Bonus{from: :direct, to: :sys_radar, type: :add, value: 0.5}
        ]
      },
      %Data.Game.FactionPatent{
        key: :counterintel_grid,
        ancestor: :deep_space_relay,
        cost: 3_200,
        bonus: [
          %Core.Bonus{from: :direct, to: :sys_ci, type: :add, value: 10}
        ]
      },
      %Data.Game.FactionPatent{
        key: :standardized_freight,
        ancestor: :research_compact,
        cost: 1_600,
        bonus: [
          %Core.Bonus{from: :army_maintenance, to: :army_maintenance, type: :mul, value: -0.05}
        ]
      },
      %Data.Game.FactionPatent{
        key: :chartered_shipyards,
        ancestor: :standardized_freight,
        cost: 3_200,
        bonus: [
          %Core.Bonus{from: :army_repair, to: :army_repair, type: :mul, value: 0.15}
        ]
      }
    ]
  end
end
