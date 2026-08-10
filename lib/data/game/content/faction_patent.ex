defmodule Data.Game.FactionPatent.Content do
  @moduledoc """
  First slice of the faction research tree — every node here works
  through the existing bonus pipeline. The marquee capability nodes
  (Gateway Network, SLSD Command Uplink) are reserved for the phase
  that builds their systems; see docs/faction-government.md §5.2.

      research_compact
      ├── deep_space_relay ── counterintel_grid ── cyber_warfare_program
      ├── standardized_freight ── chartered_shipyards
      └── orbital_engineering ── gateway_theory

  The three capability nodes (orbital_engineering, gateway_theory,
  cyber_warfare_program) carry no passive bonus — they gate faction
  buildings (`Data.Game.FactionBuilding.patent`), the station-slot
  constructions described in docs/faction-buildings.md.
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
      },
      %Data.Game.FactionPatent{
        key: :orbital_engineering,
        ancestor: :research_compact,
        cost: 2_400,
        bonus: []
      },
      %Data.Game.FactionPatent{
        key: :gateway_theory,
        ancestor: :orbital_engineering,
        cost: 12_000,
        bonus: []
      },
      %Data.Game.FactionPatent{
        key: :cyber_warfare_program,
        ancestor: :counterintel_grid,
        cost: 6_400,
        bonus: []
      }
    ]
  end
end
