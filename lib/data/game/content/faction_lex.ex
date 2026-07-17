defmodule Data.Game.FactionLex.Content do
  @moduledoc """
  First slice of the faction law tree — purchasable with treasury
  ideology, enacted into limited law slots. The agency-heavy laws from
  the design doc (War Bonds, Lend-Lease, Colonial Charter, Claimed
  Sector, Emergency Powers) arrive with the systems they lean on; see
  docs/faction-government.md §5.3.

      assembly_charter
      ├── civic_pride ── sanctuary_accord
      └── mobilization_act ── war_footing
  """

  def data do
    [
      %Data.Game.FactionLex{
        key: :assembly_charter,
        ancestor: nil,
        cost: 600,
        bonus: [
          %Core.Bonus{from: :direct, to: :player_ideology, type: :add, value: 2}
        ]
      },
      %Data.Game.FactionLex{
        key: :civic_pride,
        ancestor: :assembly_charter,
        cost: 1_200,
        bonus: [
          %Core.Bonus{from: :direct, to: :sys_happiness, type: :add, value: 3}
        ]
      },
      %Data.Game.FactionLex{
        key: :sanctuary_accord,
        ancestor: :civic_pride,
        cost: 2_400,
        bonus: [
          %Core.Bonus{from: :sys_defense, to: :sys_defense, type: :mul, value: 0.1}
        ]
      },
      %Data.Game.FactionLex{
        key: :mobilization_act,
        ancestor: :assembly_charter,
        cost: 1_200,
        bonus: [
          %Core.Bonus{from: :sys_mobility, to: :sys_mobility, type: :mul, value: 0.1}
        ]
      },
      %Data.Game.FactionLex{
        key: :war_footing,
        ancestor: :mobilization_act,
        cost: 2_400,
        bonus: [
          %Core.Bonus{from: :army_invasion, to: :army_invasion, type: :mul, value: 0.1}
        ]
      }
    ]
  end
end
