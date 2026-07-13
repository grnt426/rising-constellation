defmodule Sim.Balance do
  @moduledoc """
  Candidate balance changes for what-if testing, as **named override sets** for
  the sim. These are SIM-ONLY — they patch the cached `:sim` dataset in memory,
  they do NOT touch the game's content files. Edit the maps in `presets/0` to
  tune a change, then apply it:

      Sim.Balance.install(:corvette_rework)
      # equivalently:
      Sim.Setup.install([speed: :fast, mode: :prod], Sim.Balance.changes(:corvette_rework))

  Each override is `%{base_ship_key => %{field => value}}` and applies to the
  base ship and all its stack variants (e.g. `:corvette_1` patches
  `corvette_1`/`corvette_1v2`/`corvette_1v3`). Valid fields are
  `Data.Game.Ship` struct keys: `:unit_energy_strikes`, `:unit_explosive_strikes`,
  `:unit_shield`, `:unit_interception` (flak), `:unit_hull`, `:unit_handling`,
  `:unit_raid_coef`, `:credit_cost`, `:technology_cost`, etc.

  To make a validated change PERMANENT in the actual game, port it into
  `lib/data/game/content/ship-{fast,medium,slow}.ex` — these presets are only
  for sim experiments.
  """

  @doc """
  Named override sets. **Edit these maps to tune candidate balance changes.**
  """
  def presets do
    %{
      # Control group — vanilla stats, no changes.
      baseline: %{},

      # Early-game corvette rework (validated in sim — gives a real
      # rock-paper-scissors: 8x interceptor > light corv > MT corv > 8x interceptor,
      # with heavy corv as an anti-light flanker):
      #
      #   * light corvette -> anti-MT specialist. No bombing; its single 30
      #     EXPLOSIVE strike bypasses shields (pierces the MT shield-tank), but
      #     one strike/unit means swarms overwhelm it. Countered by 8x fighter
      #     swarms and by heavy corvette.
      #
      #   * MT corvette -> anti-swarm shield-tank. Shield walls energy fighters;
      #     weak energy offense; no flak + hull 175 means explosive corvettes
      #     punch through it. Dethroned as the universal generalist.
      corvette_rework: %{
        corvette_1: %{
          unit_raid_coef: 0.0,
          unit_energy_strikes: [],
          unit_explosive_strikes: [30],
          unit_shield: 25,
          unit_hull: 60,
          unit_interception: 10
        },
        corvette_3: %{
          unit_energy_strikes: [5, 5, 5],
          unit_explosive_strikes: [],
          unit_shield: 25,
          unit_interception: 0,
          unit_hull: 175
        }
      },

      # Fighter rebalance:
      #   * interceptor pays for its hull dominance (hull 20).
      #   * light fighter trades energy for explosive (1x5 energy + 2x4 explosive)
      #     -> a shield-piercing punch where the energy interceptor is weak,
      #     carving a distinct niche.
      fighter_rework: %{
        fighter_2: %{unit_energy_strikes: [5], unit_explosive_strikes: [4, 4]},
        fighter_4: %{unit_hull: 25}
      },

      # Handling (dodge) rebalance — dodge was the dominant defensive stat.
      # New absolute values = baseline minus: -10 default; -15 light fighter &
      # interceptor; -20 fighter-bomber. (Corvettes treated as part of "everyone".)
      handling_nerf: %{
        fighter_1: %{unit_handling: 80},
        fighter_2: %{unit_handling: 50},
        fighter_3: %{unit_handling: 40},
        fighter_4: %{unit_handling: 60},
        corvette_1: %{unit_handling: 30},
        corvette_2: %{unit_handling: 20},
        corvette_3: %{unit_handling: 10}
      },

      # Hard-counter rock-paper-scissors, found by Sim.AutoBalance (seed 1).
      # A clean, non-dominant cycle at the ship level:
      #   tank (MT) >> fighter swarm >> glass-alpha (light corv) >> tank (MT)
      # with soft counters within each class (lightftr > intcp > fbomber;
      # light corv > heavy corv). Mono-fleet win matrix verified (loss 0.25):
      # all 7 cross-class hard counters land >=80%; within-class pairs ~55-75%.
      # NOTE: armor came out 0 everywhere — the cycle rides the existing
      # shield/explosive/hull mechanics, not the new armor field. Scout
      # (fighter_1) is intentionally left at baseline (the weak picket).
      hard_counter_rps: %{
        # light fighter — mixed energy+explosive swarm; hard-counters light corv
        fighter_2: %{
          unit_handling: 62,
          unit_hull: 12,
          unit_shield: 8,
          unit_interception: 0,
          unit_armor: 0,
          unit_energy_strikes: [6, 6],
          unit_explosive_strikes: [5, 5]
        },
        # fighter-bomber — explosive swarm; hard-counters light corv, ~even heavy corv
        fighter_3: %{
          unit_handling: 54,
          unit_hull: 15,
          unit_shield: 0,
          unit_interception: 9,
          unit_armor: 0,
          unit_energy_strikes: [7],
          unit_explosive_strikes: [8, 8]
        },
        # interceptor — nimble pure-energy dogfighter; beats fbomber, loses to corvettes
        fighter_4: %{
          unit_handling: 67,
          unit_hull: 19,
          unit_shield: 0,
          unit_interception: 0,
          unit_armor: 0,
          unit_energy_strikes: [6, 6],
          unit_explosive_strikes: []
        },
        # light corvette — glass-alpha; one big explosive shot pierces tanks, dies to swarm
        corvette_1: %{
          unit_handling: 33,
          unit_hull: 71,
          unit_shield: 40,
          unit_interception: 5,
          unit_armor: 0,
          unit_energy_strikes: [],
          unit_explosive_strikes: [23]
        },
        # heavy corvette — mid shield tank with a moderate explosive shot
        corvette_2: %{
          unit_handling: 25,
          unit_hull: 107,
          unit_shield: 17,
          unit_interception: 10,
          unit_armor: 0,
          unit_energy_strikes: [],
          unit_explosive_strikes: [15]
        },
        # multi-turret corvette — the shield/hull tank that hard-counters fighters
        corvette_3: %{
          unit_handling: 22,
          unit_hull: 142,
          unit_shield: 30,
          unit_interception: 3,
          unit_armor: 0,
          unit_energy_strikes: [4, 4, 4],
          unit_explosive_strikes: []
        }
      }
    }
  end

  @doc "Fetch a named preset's override map (raises if unknown)."
  def changes(name), do: Map.fetch!(presets(), name)

  @doc """
  Merge several presets into one override map (for combining independent
  changes, e.g. `merge([:corvette_rework, :fighter_rework, :handling_nerf])`).
  Deep-merges per-ship field maps; later presets win on a field clash.
  """
  def merge(names) do
    Enum.reduce(names, %{}, fn name, acc ->
      Map.merge(acc, changes(name), fn _ship, fields1, fields2 -> Map.merge(fields1, fields2) end)
    end)
  end

  @doc "List the available preset names."
  def names, do: Map.keys(presets())

  @doc "Install the `:sim` dataset with a named preset's overrides applied."
  def install(name, metadata \\ [speed: :fast, mode: :prod]) do
    Sim.Setup.install(metadata, changes(name))
  end
end
