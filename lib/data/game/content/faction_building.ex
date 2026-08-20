defmodule Data.Game.FactionBuilding.Content do
  @moduledoc """
  The founding trio of faction buildings — one per interaction class:
  a fundamental-mechanic changer (Gateway), a system-local drip
  (Training Center), and a sector-wide sensor (Cyber Command). Numbers
  from the July 2026 user design; Cyber Command costs are declared
  placeholders (marked TBD in docs/faction-buildings.md).

  Labor sizing anchors: gateway ≈16h at 800 production, training
  center ≈6h at 400 production (Legacy speed, 1 ut = 3 wall-minutes,
  so 16h = 320 ut × 800 prod/ut = 256_000 labor).
  """

  def data do
    [
      %Data.Game.FactionBuilding{
        key: :gateway,
        seat: :military,
        patent: :gateway_theory,
        shape: %{cols: 2, rows: 2},
        unique: true,
        effect: :gateway,
        levels: [
          %{
            level: 1,
            cost: %{credit: 2_000_000, technology: 75_000, ideology: 20_000},
            labor: 256_000,
            upkeep: %{credit: 500, technology: 50, ideology: 0},
            bonus: []
          }
        ]
      },
      %Data.Game.FactionBuilding{
        key: :training_center,
        seat: :economy,
        patent: :orbital_engineering,
        shape: %{cols: 2, rows: 1},
        unique: true,
        effect: :agent_training,
        levels: [
          %{
            level: 1,
            cost: %{credit: 300_000, technology: 12_000, ideology: 10_000},
            labor: 48_000,
            upkeep: %{credit: 100, technology: 20, ideology: 30},
            bonus: []
          },
          %{
            level: 2,
            cost: %{credit: 450_000, technology: 18_000, ideology: 15_000},
            labor: 72_000,
            upkeep: %{credit: 150, technology: 30, ideology: 45},
            bonus: []
          },
          %{
            level: 3,
            cost: %{credit: 675_000, technology: 27_000, ideology: 22_500},
            labor: 108_000,
            upkeep: %{credit: 225, technology: 45, ideology: 68},
            bonus: []
          },
          %{
            level: 4,
            cost: %{credit: 1_010_000, technology: 40_500, ideology: 33_750},
            labor: 162_000,
            upkeep: %{credit: 340, technology: 68, ideology: 100},
            bonus: []
          },
          %{
            level: 5,
            cost: %{credit: 1_520_000, technology: 60_750, ideology: 50_625},
            labor: 243_000,
            upkeep: %{credit: 510, technology: 100, ideology: 150},
            bonus: []
          }
        ]
      },
      %Data.Game.FactionBuilding{
        key: :cyber_command,
        seat: :military,
        patent: :cyber_warfare_program,
        shape: %{cols: 2, rows: 2},
        unique: true,
        effect: :cyber_command,
        levels: [
          %{
            level: 1,
            cost: %{credit: 500_000, technology: 25_000, ideology: 5_000},
            labor: 100_000,
            upkeep: %{credit: 200, technology: 40, ideology: 0},
            bonus: []
          }
        ]
      }
    ]
  end
end
