defmodule Headless.Policies.Tunable do
  @moduledoc """
  Genome-driven policy: the same mechanical capabilities as the hand-built
  Colonizer, but every PRIORITY is a weight and every THRESHOLD a scalar,
  searchable by `mix headless.search`.

  Design split (docs/game-ai.md §7):

    * **Legality is code** — engine rules stay hard-wired (lane-graph BFS,
      `:filled` ship checks, idle-gates, takeability, tile eligibility).
      These aren't strategy; a genome that must rediscover the rules wastes
      its search budget on physics.
    * **Strategy is genome** — what to build/research/buy first, how much
      to reserve, how far to reach for a good system. No hand-coded
      sequencing: the orderings the Colonizer needed three debugging rounds
      to get right (hire before expansion lex, income before splurge) are
      exactly what the optimizer should discover — or refute.

  The genome is a flat string-keyed map of floats (JSON-serializable).
  `default/0` approximates the hand-built Colonizer; `random/1` and
  `mutate/2` drive the search.
  """

  @behaviour Headless.Bot.Policy

  alias Headless.Bot.Considerations
  alias Headless.Bot.Nav
  alias Headless.Bot.Opener
  alias Headless.Econ
  alias Headless.Budget
  alias Headless.Flags
  alias Headless.Policies.HomeDev
  alias Headless.Strategist

  # {key, biome, patent_gate, uniqueness, tile_kind, credit_cost} — the
  # COMPLETE fast-mode buildable catalog (all 34 buildings, verified against
  # building-fast data 2026-07-04). V2 rule (game-ai-v2.md §3): nothing is
  # pre-judged out of the option space — every building gets a weight gene.
  @catalog [
    {:infra_open, :open, :infra_open_1, :unique_body, :infrastructure, 12_000},
    {:infra_dome, :dome, :infra_open_1, :unique_body, :infrastructure, 15_000},
    {:mine_dome, :dome, :infra_open_1, :none, :normal, 3360},
    {:hab_dome, :dome, :infra_dome_1, :none, :normal, 3800},
    {:hab_open_poor, :open, nil, :none, :normal, 2900},
    {:hab_open_rich, :open, :infra_dome_1, :none, :normal, 3400},
    {:factory_orbital, :orbital, :infra_open_1, :none, :normal, 5040},
    {:high_factory_dome, :dome, :dome_industries, :unique_body, :normal, 53_000},
    {:lift_open, :open, :open_credit, :unique_body, :normal, 14_000},
    {:university_open, :open, nil, :unique_body, :normal, 3360},
    {:research_open, :open, :open_research, :unique_body, :normal, 84_000},
    {:research_orbital, :orbital, :orbital_research, :unique_body, :normal, 6720},
    {:ideo_open, :open, :citadel, :unique_body, :normal, 3360},
    {:monument_dome, :dome, :dome_ideo, :unique_system, :normal, 7280},
    {:ideo_credit_open, :open, :open_island, :unique_body, :normal, 16_800},
    {:market_open, :open, :open_credit, :none, :normal, 4480},
    {:finance_open, :open, :open_mobility, :unique_body, :normal, 62_000},
    {:spatioport_dome, :dome, :dome_mobility, :unique_body, :normal, 16_000},
    {:spatioport_orbital, :orbital, :dome_mobility, :unique_body, :normal, 21_000},
    {:defense_global_dome, :dome, :dome_defense_2, :unique_system, :normal, 7000},
    {:defense_local_open, :open, :open_defense, :unique_body, :normal, 11_000},
    {:defense_local_dome, :dome, :open_defense, :unique_body, :normal, 11_000},
    {:defense_local_orbital, :orbital, :dome_happiness, :unique_body, :normal, 4000},
    {:happy_pot_open, :open, :open_happiness, :unique_body, :normal, 16_800},
    {:happy_pot_dome, :dome, :dome_happiness, :unique_body, :normal, 6720},
    {:happy_pot_orbital, :orbital, :open_research, :unique_body, :normal, 8400},
    {:shipyard_1_orbital, :orbital, :shipyard_1, :unique_system, :normal, 5600},
    {:shipyard_2_orbital, :orbital, :shipyard_2, :unique_system, :normal, 9900},
    {:shipyard_3_orbital, :orbital, :shipyard_3, :unique_system, :normal, 14_300},
    {:shipyard_4_orbital, :orbital, :shipyard_4, :unique_system, :normal, 23_000},
    {:military_school_dome, :dome, :dome_academy, :unique_body, :normal, 21_000},
    {:radar_orbital, :orbital, :open_defense, :unique_system, :normal, 8400},
    {:counterintelligence_open, :open, :dome_defense_2, :unique_system, :normal, 8400}
  ]

  # Fleet BLUEPRINTS — whole-fleet compositions the fleet-builder picks from
  # (the genome chooses via aggression/mix/investment, never individual
  # ships). `ships` is the tile fill-order, cycled to the effective army
  # size; `patents` gates availability (union of the composition's ship
  # patents); shipyard buildings are pre-checked per ship and engine-
  # validated at order time. GENERATED from `mix sim.blueprints` arena
  # champions (tmp/fleet_arena/blueprints.json, fast-mode PROD data — never
  # the beta/rebalance overrides): one champion per strategic goal per
  # availability tier, goal mapped to aggression (defense 0.15 / intercept
  # 0.45 / raid_soft 0.7 / raid_hard 0.95), levels stripped. Tiers listed
  # HIGHEST first: `pick_blueprint`'s stable sort makes equal-aggression
  # ties resolve to the best tier the bot's patents allow. Tiers whose
  # champion was the empty fleet (raiding impossible at scout/fighter tech)
  # are omitted. The lone colony transport stays its own "fleet" via the
  # colonizer pipeline. Regenerate with tmp/gen_blueprints.exs after an
  # arena refresh.
  @blueprints [
    # HAND-CRAFTED ROLE BLUEPRINTS (not arena-bred): the arena optimizes
    # pure combat, so its champions carry no troop transports — leaving
    # conquest inexpressible below the capital tier (the invasion gate in
    # fleet_employment rightly refuses troopless conquests). These invasion
    # columns close that gap until the arena breeds a :conquest goal.
    %{key: :invasion_column_late, aggression: 0.97,
      ships: [:transport_2, :frigate_1, :frigate_2, :corvette_2v2, :fighter_4v2, :transport_2, :frigate_1, :corvette_2v2],
      patents: [:corvette_2, :fighter_4, :frigate_2, :frigate_3, :merge_fighter_1, :merge_fighter_corvette, :shipyard_3, :transport_2]},
    %{key: :invasion_column_mid, aggression: 0.75,
      ships: [:transport_2, :corvette_1v2, :corvette_2v2, :fighter_4v2, :fighter_4v2, :transport_2, :corvette_1v2, :fighter_2v2],
      patents: [:corvette_1, :corvette_2, :fighter_2, :fighter_4, :merge_fighter_1, :merge_fighter_corvette, :transport_2]},
    %{key: :t8_capitals_defense, aggression: 0.15,
      ships: [:capital_2, :capital_2, :capital_2, :capital_2, :capital_2, :capital_2, :frigate_2v2, :frigate_3, :capital_3, :corvette_3v2, :fighter_4v3, :fighter_3v2, :corvette_2, :frigate_1v2, :corvette_3v3, :corvette_2v2],
      patents: [:capital_2, :capital_3, :corvette_2, :corvette_3, :fighter_3, :fighter_4, :frigate_2, :frigate_3, :merge_corvette_2, :merge_fighter_1, :merge_fighter_corvette, :merge_frigate_1, :shipyard_3]},
    %{key: :t8_capitals_raid_soft, aggression: 0.7,
      ships: [:capital_1, :frigate_4, :capital_2, :capital_2, :frigate_2v2, :frigate_2v2, :capital_2, :frigate_2, :frigate_2v2, :corvette_1v3, :frigate_2, :corvette_2v3, :corvette_2v3, :frigate_2v2, :fighter_3v4, :capital_2, :frigate_2v2, :frigate_3v2],
      patents: [:capital_1, :capital_2, :corvette_1, :corvette_2, :fighter_3, :frigate_2, :frigate_3, :frigate_4, :merge_corvette_2, :merge_fighter_1, :merge_fighter_3, :merge_fighter_corvette, :merge_frigate_1]},
    %{key: :t8_capitals_raid_hard, aggression: 0.95,
      ships: [:capital_1, :capital_1, :capital_1, :capital_2, :capital_1, :capital_1, :capital_2, :frigate_2v2, :corvette_1v3, :fighter_3v2, :capital_2, :frigate_1, :capital_2, :fighter_3v3, :corvette_3v2, :corvette_2v3, :frigate_2v2, :capital_1],
      patents: [:capital_1, :capital_2, :corvette_1, :corvette_2, :corvette_3, :fighter_3, :frigate_2, :merge_corvette_2, :merge_fighter_1, :merge_fighter_corvette, :merge_frigate_1, :shipyard_3]},
    %{key: :t8_capitals_intercept, aggression: 0.45,
      ships: [:capital_1, :frigate_3v2, :capital_2, :capital_2, :frigate_2v2, :capital_2, :capital_1, :frigate_3, :capital_1, :corvette_3v3, :fighter_2, :corvette_3v3, :corvette_3v2, :frigate_2v2, :fighter_3v2, :frigate_3v2, :fighter_4v4, :fighter_1v3],
      patents: [:capital_1, :capital_2, :corvette_3, :fighter_2, :fighter_3, :fighter_4, :frigate_2, :frigate_3, :merge_corvette_2, :merge_fighter_1, :merge_fighter_3, :merge_fighter_corvette, :merge_frigate_1, :shipyard_1]},
    %{key: :t7_armadas_defense, aggression: 0.15,
      ships: [:fighter_4v4, :frigate_3, :corvette_3v2, :corvette_3v3, :corvette_3v3, :fighter_4v4, :fighter_4v4, :fighter_4, :fighter_2v3, :frigate_1, :fighter_4v2, :corvette_1v3, :corvette_3v2, :fighter_2v4, :fighter_3v2],
      patents: [:corvette_1, :corvette_3, :fighter_2, :fighter_3, :fighter_4, :frigate_3, :merge_corvette_2, :merge_fighter_1, :merge_fighter_3, :merge_fighter_corvette, :shipyard_3]},
    %{key: :t7_armadas_raid_soft, aggression: 0.7,
      ships: [:fighter_4v4, :fighter_3v4, :corvette_3v3, :frigate_3, :corvette_2v3, :fighter_4v4, :frigate_2, :corvette_3v3, :corvette_2v2, :fighter_1, :corvette_2v3, :corvette_2v3, :frigate_2, :corvette_2v3, :corvette_2v3, :corvette_2v3],
      patents: [:corvette_2, :corvette_3, :fighter_3, :fighter_4, :frigate_2, :frigate_3, :merge_corvette_2, :merge_fighter_1, :merge_fighter_3, :merge_fighter_corvette, :shipyard_1]},
    %{key: :t7_armadas_raid_hard, aggression: 0.95,
      ships: [:fighter_4v4, :frigate_2, :corvette_3v3, :fighter_4v4, :frigate_2, :corvette_2v3, :corvette_2v3, :frigate_2, :corvette_2v2, :fighter_4v4, :corvette_2v3, :frigate_4, :fighter_3v4, :corvette_1v2, :frigate_1],
      patents: [:corvette_1, :corvette_2, :corvette_3, :fighter_3, :fighter_4, :frigate_2, :frigate_4, :merge_corvette_2, :merge_fighter_1, :merge_fighter_3, :merge_fighter_corvette, :shipyard_3]},
    %{key: :t7_armadas_intercept, aggression: 0.45,
      ships: [:corvette_3v2, :frigate_4, :corvette_3v3, :frigate_1, :frigate_3, :fighter_4v4, :fighter_2v4, :corvette_1v3, :fighter_4v4, :corvette_1v3, :frigate_2, :frigate_2, :corvette_2v3, :fighter_1, :fighter_2, :fighter_4v2, :fighter_1v3],
      patents: [:corvette_1, :corvette_2, :corvette_3, :fighter_2, :fighter_4, :frigate_2, :frigate_3, :frigate_4, :merge_corvette_2, :merge_fighter_1, :merge_fighter_3, :merge_fighter_corvette, :shipyard_1, :shipyard_3]},
    %{key: :t6_frigates_defense, aggression: 0.15,
      ships: [:frigate_3, :frigate_3, :frigate_3, :fighter_2v3, :frigate_1, :corvette_3v2, :corvette_3, :frigate_1, :fighter_1, :fighter_4v3, :frigate_2, :fighter_4v3, :corvette_1v2, :frigate_2, :frigate_4],
      patents: [:corvette_1, :corvette_3, :fighter_2, :fighter_4, :frigate_2, :frigate_3, :frigate_4, :merge_fighter_1, :merge_fighter_corvette, :shipyard_1, :shipyard_3]},
    %{key: :t6_frigates_raid_soft, aggression: 0.7,
      ships: [:frigate_2, :corvette_3v2, :frigate_3, :fighter_4v3, :corvette_1v2, :corvette_1v2, :frigate_2, :fighter_3v3, :corvette_2v2, :frigate_2, :frigate_2, :corvette_2, :fighter_3v3, :corvette_1v2, :corvette_2v2, :fighter_3v3, :corvette_1],
      patents: [:corvette_1, :corvette_2, :corvette_3, :fighter_3, :fighter_4, :frigate_2, :frigate_3, :merge_fighter_1, :merge_fighter_corvette]},
    %{key: :t6_frigates_raid_hard, aggression: 0.95,
      ships: [:frigate_2, :frigate_2, :frigate_1, :frigate_2, :frigate_3, :frigate_2, :frigate_2, :frigate_2, :frigate_4, :fighter_3, :frigate_2, :fighter_4v3, :fighter_2v3, :frigate_2, :frigate_2, :frigate_2, :frigate_2],
      patents: [:fighter_2, :fighter_3, :fighter_4, :frigate_2, :frigate_3, :frigate_4, :merge_fighter_1, :merge_fighter_corvette, :shipyard_3]},
    %{key: :t6_frigates_intercept, aggression: 0.45,
      ships: [:corvette_3v2, :frigate_3, :corvette_3v2, :frigate_1, :fighter_2v3, :frigate_1, :frigate_2, :frigate_2, :fighter_2v3, :frigate_1, :frigate_4, :fighter_4v3, :corvette_1v2, :frigate_4, :corvette_2, :fighter_3v2, :fighter_2v3],
      patents: [:corvette_1, :corvette_2, :corvette_3, :fighter_2, :fighter_3, :fighter_4, :frigate_2, :frigate_3, :frigate_4, :merge_fighter_1, :merge_fighter_corvette, :shipyard_3]},
    %{key: :t5_strike_groups_defense, aggression: 0.15,
      ships: [:corvette_1v2, :corvette_1v2, :corvette_3v2, :fighter_4v3, :corvette_1v2, :corvette_3, :corvette_3v2, :fighter_4v3, :fighter_2v3, :fighter_4v3, :corvette_1v2, :fighter_3v3],
      patents: [:corvette_1, :corvette_3, :fighter_2, :fighter_3, :fighter_4, :merge_fighter_1, :merge_fighter_corvette]},
    %{key: :t5_strike_groups_raid_soft, aggression: 0.7,
      ships: [:corvette_3v2, :corvette_3v2, :corvette_1v2, :fighter_2v3, :corvette_1v2, :fighter_3v3, :fighter_1, :corvette_1v2, :corvette_1v2, :corvette_2v2, :corvette_2v2, :fighter_4v3, :corvette_2v2, :corvette_1, :fighter_3v3],
      patents: [:corvette_1, :corvette_2, :corvette_3, :fighter_2, :fighter_3, :fighter_4, :merge_fighter_1, :merge_fighter_corvette, :shipyard_1]},
    %{key: :t5_strike_groups_raid_hard, aggression: 0.95,
      ships: [:fighter_4v3, :corvette_2v2, :fighter_4v3, :corvette_3v2, :corvette_2v2, :corvette_3v2, :corvette_2v2, :corvette_1v2, :fighter_2v2, :corvette_2v2, :fighter_3v3, :fighter_4v3, :corvette_1v2, :fighter_3v3],
      patents: [:corvette_1, :corvette_2, :corvette_3, :fighter_2, :fighter_3, :fighter_4, :merge_fighter_1, :merge_fighter_corvette]},
    %{key: :t5_strike_groups_intercept, aggression: 0.45,
      ships: [:fighter_2v3, :corvette_3v2, :corvette_3v2, :fighter_3v3, :fighter_4v3, :fighter_4v3, :fighter_3, :fighter_2v3, :corvette_3v2, :fighter_3v3, :corvette_3v2, :fighter_4, :fighter_1v3, :fighter_2],
      patents: [:corvette_3, :fighter_2, :fighter_3, :fighter_4, :merge_fighter_1, :merge_fighter_corvette, :shipyard_1]},
    %{key: :t4_corvettes_defense, aggression: 0.15,
      ships: [:fighter_2v2, :fighter_2v2, :fighter_4v2, :fighter_4v2, :fighter_4v2, :fighter_2v2, :fighter_2, :fighter_2, :fighter_4v2],
      patents: [:fighter_2, :fighter_4, :merge_fighter_1]},
    %{key: :t4_corvettes_raid_soft, aggression: 0.7,
      ships: [:fighter_4v2, :fighter_2v2, :corvette_1, :fighter_3, :corvette_2, :fighter_4v2, :corvette_1, :corvette_2, :corvette_2, :fighter_3v2, :corvette_2, :fighter_3v2, :corvette_2, :fighter_3v2, :corvette_2],
      patents: [:corvette_1, :corvette_2, :fighter_2, :fighter_3, :fighter_4, :merge_fighter_1]},
    %{key: :t4_corvettes_raid_hard, aggression: 0.95,
      ships: [:fighter_2v2, :corvette_1, :fighter_4v2, :corvette_1, :corvette_2, :fighter_4v2, :fighter_3v2, :corvette_1, :corvette_2, :fighter_3, :fighter_1, :fighter_4, :corvette_2, :corvette_1, :fighter_1],
      patents: [:corvette_1, :corvette_2, :fighter_2, :fighter_3, :fighter_4, :merge_fighter_1, :shipyard_1]},
    %{key: :t4_corvettes_intercept, aggression: 0.45,
      ships: [:fighter_4v2, :fighter_4v2, :corvette_1, :fighter_4v2, :fighter_4, :fighter_2, :fighter_4, :corvette_1, :fighter_1, :fighter_4v2],
      patents: [:corvette_1, :fighter_2, :fighter_4, :merge_fighter_1, :shipyard_1]},
    %{key: :t3_wings_defense, aggression: 0.15,
      ships: [:fighter_4v2, :fighter_4v2, :fighter_4v2, :fighter_4, :fighter_1v2, :fighter_4v2, :fighter_4v2],
      patents: [:fighter_4, :merge_fighter_1, :shipyard_1]},
    %{key: :t3_wings_raid_soft, aggression: 0.7,
      ships: [:fighter_4v2, :fighter_4v2, :fighter_3, :fighter_4v2, :fighter_2v2, :fighter_3v2, :fighter_2v2, :fighter_3v2, :fighter_3],
      patents: [:fighter_2, :fighter_3, :fighter_4, :merge_fighter_1]},
    %{key: :t3_wings_raid_hard, aggression: 0.95,
      ships: [:fighter_4v2, :fighter_4v2, :fighter_4v2, :fighter_4v2, :fighter_2v2, :fighter_3v2, :fighter_4, :fighter_4v2, :fighter_2v2, :fighter_3v2],
      patents: [:fighter_2, :fighter_3, :fighter_4, :merge_fighter_1]},
    %{key: :t3_wings_intercept, aggression: 0.45,
      ships: [:fighter_4v2, :fighter_4v2, :fighter_4v2, :fighter_4v2, :fighter_4v2, :fighter_4v2, :fighter_1],
      patents: [:fighter_4, :merge_fighter_1, :shipyard_1]},
    %{key: :t2_fighters_defense, aggression: 0.15,
      ships: [:fighter_2, :fighter_1, :fighter_2, :fighter_2, :fighter_2, :fighter_1, :fighter_3],
      patents: [:fighter_2, :fighter_3, :shipyard_1]},
    %{key: :t2_fighters_raid_hard, aggression: 0.95,
      ships: [:fighter_2, :fighter_2, :fighter_2, :fighter_2, :fighter_1, :fighter_2, :fighter_3, :fighter_2, :fighter_3, :fighter_3],
      patents: [:fighter_2, :fighter_3, :shipyard_1]},
    %{key: :t2_fighters_intercept, aggression: 0.45,
      ships: [:fighter_2, :fighter_2, :fighter_2, :fighter_2, :fighter_2, :fighter_2, :fighter_1],
      patents: [:fighter_2, :shipyard_1]},
    %{key: :t1_scouts_defense, aggression: 0.15,
      ships: [:fighter_1, :fighter_1, :fighter_1, :fighter_1],
      patents: [:shipyard_1]},
    %{key: :t1_scouts_raid_hard, aggression: 0.95,
      ships: [:fighter_1, :fighter_1],
      patents: [:shipyard_1]},
    %{key: :t1_scouts_intercept, aggression: 0.45,
      ships: [:fighter_1, :fighter_1, :fighter_1, :fighter_1],
      patents: [:shipyard_1]},
  ]

  # Ship costs + required shipyard building for affordability/buildability
  # pre-checks: {key, credit, tech, shipyard_building} (fast/prod data).
  @ship_costs %{
    capital_1: {200_000, 8_000, :shipyard_4_orbital},
    capital_2: {250_000, 15_000, :shipyard_4_orbital},
    capital_3: {230_000, 10_000, :shipyard_4_orbital},
    corvette_1: {4_300, 80, :shipyard_2_orbital},
    corvette_1v2: {8_600, 160, :shipyard_2_orbital},
    corvette_1v3: {17_300, 320, :shipyard_2_orbital},
    corvette_2: {4_300, 100, :shipyard_2_orbital},
    corvette_2v2: {8_600, 200, :shipyard_2_orbital},
    corvette_2v3: {17_300, 400, :shipyard_2_orbital},
    corvette_3: {8_600, 750, :shipyard_2_orbital},
    corvette_3v2: {17_300, 1_500, :shipyard_2_orbital},
    corvette_3v3: {34_600, 3_000, :shipyard_2_orbital},
    fighter_1: {900, 0, :shipyard_1_orbital},
    fighter_1v2: {1_800, 0, :shipyard_1_orbital},
    fighter_1v3: {2_900, 0, :shipyard_1_orbital},
    fighter_2: {1_400, 0, :shipyard_1_orbital},
    fighter_2v2: {2_700, 25, :shipyard_1_orbital},
    fighter_2v3: {4_300, 50, :shipyard_1_orbital},
    fighter_2v4: {8_600, 100, :shipyard_1_orbital},
    fighter_3: {1_400, 0, :shipyard_1_orbital},
    fighter_3v2: {2_700, 25, :shipyard_1_orbital},
    fighter_3v3: {4_300, 50, :shipyard_1_orbital},
    fighter_3v4: {8_600, 100, :shipyard_1_orbital},
    fighter_4: {1_400, 0, :shipyard_1_orbital},
    fighter_4v2: {2_700, 25, :shipyard_1_orbital},
    fighter_4v3: {4_300, 50, :shipyard_1_orbital},
    fighter_4v4: {8_600, 100, :shipyard_1_orbital},
    frigate_1: {9_200, 200, :shipyard_3_orbital},
    frigate_1v2: {22_000, 400, :shipyard_3_orbital},
    frigate_2: {21_600, 3_000, :shipyard_3_orbital},
    frigate_2v2: {43_200, 6_000, :shipyard_3_orbital},
    frigate_3: {21_600, 2_500, :shipyard_3_orbital},
    frigate_3v2: {43_200, 5_000, :shipyard_3_orbital},
    frigate_4: {21_600, 2_400, :shipyard_3_orbital},
    transport_2: {18_000, 3_000, :none}
  }

  # {key, tech_cost, ancestor} — purchasable patents (fast tree).
  @patents [
    {:citadel, 50, nil},
    {:infra_open_1, 400, :citadel},
    {:transport_1, 600, :citadel},
    {:shipyard_1, 300, :citadel},
    {:fighter_2, 600, :shipyard_1},
    {:fighter_3, 600, :shipyard_1},
    {:fighter_4, 800, :fighter_2},
    {:merge_fighter_1, 800, :shipyard_1},
    {:shipyard_2, 900, :merge_fighter_1},
    {:corvette_1, 1000, :shipyard_2},
    {:corvette_2, 1500, :shipyard_2},
    {:corvette_3, 4000, :corvette_2},
    {:merge_fighter_corvette, 1000, :shipyard_2},
    {:shipyard_3, 2000, :merge_fighter_corvette},
    {:frigate_3, 4000, :shipyard_3},
    {:frigate_2, 5000, :frigate_3},
    {:frigate_4, 4000, :shipyard_3},
    {:merge_fighter_3, 4500, :shipyard_3},
    {:merge_corvette_2, 5000, :merge_fighter_3},
    {:shipyard_4, 6500, :merge_corvette_2},
    {:capital_1, 8000, :shipyard_4},
    {:capital_2, 10_000, :capital_1},
    {:capital_3, 8000, :shipyard_4},
    {:merge_frigate_1, 7500, :shipyard_4},
    {:transport_2, 4200, :transport_1},
    {:dome_happiness, 1000, :infra_open_1},
    {:orbital_research, 1200, :infra_open_1},
    {:infra_dome_1, 2000, :dome_happiness},
    {:open_island, 1200, :infra_open_1},
    {:open_defense, 4500, :infra_dome_1},
    {:dome_defense_2, 7000, :open_defense},
    {:open_research, 4500, :infra_dome_1},
    {:open_happiness, 7000, :open_research},
    {:dome_ideo, 10_000, :open_happiness},
    {:dome_industries, 14_000, :dome_ideo},
    {:open_credit, 4500, :infra_dome_1},
    {:dome_mobility, 7000, :open_credit},
    {:open_mobility, 12_000, :dome_mobility},
    {:dome_academy, 2800, :corvette_3}
  ]

  # {key, ideology_cost, ancestor} — purchasable lexes/doctrines (fast mode,
  # ancestors verified in doctrine-fast.ex; :doctrine_locked otherwise). The
  # expansion ladder is agent → system_1 → dominion_1 → sys_dom_2 →
  # system_4 — three colonies means climbing it (≥10k base ideology, and
  # doctrine costs INFLATE with each owned doctrine, so lex-shopping taxes
  # expansion). Capacity lexes (agent/admiral_1) make fleet size an emergent
  # genome choice: hiring fills whatever cap the weights buy.
  # The COMPLETE fast-mode lex tree (40 doctrines, verified against
  # doctrine-fast data 2026-07-05) — V2 rule: nothing pre-judged out.
  @doctrines [
    {:agent, 50, nil},
    # Expansion ladder
    {:system_1, 1200, :agent},
    {:dominion_1, 3000, :system_1},
    {:sys_dom_2, 6000, :dominion_1},
    {:system_4, 8000, :sys_dom_2},
    {:dominion_3, 10_000, :system_4},
    # Economy / polarization branches
    {:speaker_1, 300, :agent},
    {:tech_2, 900, :speaker_1},
    {:tech_pola, 8000, :tech_2},
    {:ideo_2, 800, :speaker_1},
    {:stab_2, 2000, :ideo_2},
    {:ideo_pola, 8000, :stab_2},
    {:credit_1, 700, :speaker_1},
    {:credit_2, 2800, :credit_1},
    {:spy_2, 3500, :credit_2},
    {:credit_3, 5000, :spy_2},
    {:mobility_1, 8000, :credit_3},
    {:mobility_2, 11_000, :mobility_1},
    {:credit_pop, 6000, :credit_3},
    {:credit_pola_1, 9000, :credit_pop},
    # Fleet command ladder (capacity, raid/fleet/repair upgrades)
    {:admiral_1, 400, :agent},
    {:upgrade_raid, 1000, :admiral_1},
    {:admiral_2, 3000, :upgrade_raid},
    {:prod_2, 4800, :admiral_2},
    {:admiral_4, 6400, :prod_2},
    {:reduce_maintenance_2, 9000, :admiral_4},
    {:upgrade_fleet, 10_000, :reduce_maintenance_2},
    {:upgrade_repair, 7500, :reduce_maintenance_2},
    # Covert branches: speaker mastery, spy offense, spy DEFENSE
    {:defense_1, 700, :admiral_1},
    {:speaker_2, 1800, :defense_1},
    {:speaker_4, 6600, :speaker_2},
    {:speaker_dominion, 8500, :speaker_4},
    {:spy_def_1, 4000, :defense_1},
    {:spy_def_2, 7000, :spy_def_1},
    {:spy_1, 1500, :defense_1},
    {:infiltration, 3000, :spy_1},
    {:spy_4, 6000, :infiltration},
    {:assassinate, 7000, :spy_4},
    {:spy_bonus, 10_000, :assassinate}
  ]

  @transport_credit 12_000
  @transport_tech 2_000

  # --- genome ----------------------------------------------------------------

  @doc "Weight/scalar keys and their sane ranges (for random/mutate/clamp)."
  def spec do
    weights =
      Enum.map(@catalog, fn {k, _, _, _, _, _} -> {"w_build_#{k}", {0.0, 10.0}} end) ++
        Enum.map(@patents, fn {k, _, _} -> {"w_patent_#{k}", {0.0, 10.0}} end) ++
        Enum.map(@doctrines, fn {k, _, _} -> {"w_doc_#{k}", {0.0, 10.0}} end)

    scalars = [
      # Which opening-book variant to run (trunc → index; see
      # Headless.Bot.Opener). The ONLY opening choice evolution makes —
      # the book itself is code.
      # 4 variants now (governor / scout / colonial / exobiology).
      {"opener_variant", {0.0, 3.99}},
      {"credit_floor", {1_000.0, 20_000.0}},
      # (V3: reserve_first_colony / reserve_followup_colony / hire_reserve
      # retired — budget-pool rollover replaced the reservation mechanism.)
      # GROWTH-CURVE steering (player knowledge, user 2026-07-12): growth =
      # (base + stability, maxed at 25) × housing headroom × a pop factor
      # that decays hard toward 120 — so the payoff window is pop 0→~70 and
      # players push past that only for workforce or pop victory points.
      # w_growth = how aggressively to chase the curve (scales the happiness/
      # housing build boosts and gates the growth patents); growth_pop_target
      # = the per-system population where the push stops.
      {"w_growth", {0.0, 10.0}},
      {"growth_pop_target", {40.0, 120.0}},
      # V3 personality: colonies before the Strategist shifts this bot from
      # :expansion to :consolidation (docs/game-ai-v3.md).
      {"expansion_colony_target", {2.0, 9.0}},
      # Development ladder (human doctrine 3b): every system chases this
      # production value after its growth gates are satisfied — build
      # speed compounds everything. Read only behind the dev_ladder flag.
      # (lane_recovery_ut and agent_train_level were round-2 genes whose
      # flags lost their A/B 2026-07-19; orphaned copies in archive
      # genomes are inert.)
      {"prod_floor", {80.0, 250.0}},
      {"w_mission_infiltrate", {0.0, 10.0}},
      {"w_mission_destabilize", {0.0, 10.0}},
      {"w_mission_make_dominion", {0.0, 10.0}},
      # Counter-agent play: hunt radar-detected foreign agents — Erased
      # assassinate (removal), Siderians convert (seduction).
      {"w_mission_assassinate", {0.0, 10.0}},
      {"w_mission_convert", {0.0, 10.0}},
      # >= 0.5: destabilize dispatch may STACK agents on a target already
      # being worked (skip the reserved-target exclusion) — the "earthquake"
      # play: several Siderians ganging one system to drive it negative.
      {"covert_focus", {0.0, 1.0}},
      # REACTION genes: threat signals (code) scale weight groups THIS
      # decision by ×(1+r). The shadow reaction is TWO-PHASE (user design
      # 2026-07-05): a BURST while an enemy sits at visibility stage 2+ and
      # we have no counterintelligence installed anywhere (the interrupt —
      # stays high until serviced, then drops), plus a small SUSTAIN scaled
      # by stage above 1 (stage 3 ≈ committed shadow specialist, keep
      # leaning). Stage 1 is noise — trivially reached by accident — and
      # never reacted to. r_raid_high_pop / r_pressure_sprawl are level
      # signals: continuous pressures, not events.
      {"r_shadow_burst", {0.0, 6.0}},
      {"r_shadow_sustain", {0.0, 3.0}},
      {"r_raid_high_pop", {0.0, 4.0}},
      {"r_pressure_sprawl", {0.0, 4.0}},
      # Catalog batch (2026-07-05): siege response, closing sprint, force
      # preservation, track sandbagging.
      {"r_siege_defense", {0.0, 6.0}},
      # "Get to work" (user model 2026-07-06): OPEN dominion slots are paid
      # capacity going to waste — propaganda/flip weights scale with how
      # many sit unused. (Open SYSTEM slots are code-gated: they trigger
      # transport building + dispatch directly.)
      {"r_expand_slots", {0.0, 4.0}},
      {"r_sprint_lead", {0.0, 4.0}},
      {"r_sprint_trail", {0.0, 4.0}},
      # Recall a fleet whose surviving-unit fraction drops below this.
      {"fleet_retreat_hp", {0.0, 0.8}},
      # >= 0.5: hold infiltration just under the next visibility milestone
      # until a squad of idle Erased can cross it in one burst.
      {"sandbag", {0.0, 1.0}},
      {"w_governor", {0.0, 10.0}},
      {"w_raid_enemy", {0.0, 10.0}},
      {"w_conquest", {0.0, 10.0}},
      {"w_defend", {0.0, 10.0}},
      {"w_train_navarch", {0.0, 10.0}},
      {"w_train_covert", {0.0, 10.0}},
      {"w_flip_dominion", {0.0, 10.0}},
      {"w_undo_dominion", {0.0, 10.0}},
      {"army_size", {1.0, 12.0}},
      {"reaction_stance", {0.0, 3.0}},
      # Fleet-builder genes: WHICH blueprint (by aggression proximity), how
      # varied across admirals, and how much to over/under-invest relative
      # to army_size. Individual ship choice is never in the genome.
      {"blueprint_aggression", {0.0, 1.0}},
      {"blueprint_mix", {0.0, 1.0}},
      {"fleet_investment", {0.5, 2.0}},
      # Fraction of the commissioned fleet that must be BUILT before the
      # employment layer will spend it on a mission.
      {"fleet_readiness", {0.25, 1.0}},
      # Archetype commitment: each multiplies a whole weight FAMILY (see
      # @families). Pushing one high and others low = committed
      # specialization; middling values = generalist. Evolution decides.
      {"focus_expansion", {0.25, 2.0}},
      {"focus_military", {0.25, 2.0}},
      {"focus_shadows", {0.25, 2.0}},
      {"focus_economy", {0.25, 2.0}},
      # Trust in the Headless.Econ bottleneck/ROI module (0 = off, exact
      # legacy behavior — inert onboarding for existing champions; 3 =
      # full trust). The module is code; only faith in it evolves.
      {"w_econ_roi", {0.0, 3.0}}
    ]

    Map.new(weights ++ scalars)
  end

  @families %{
    "expansion" =>
      ~w(w_doc_system_1 w_doc_dominion_1 w_doc_sys_dom_2 w_doc_system_4 w_doc_dominion_3 w_flip_dominion w_undo_dominion w_mission_make_dominion),
    "military" =>
      ~w(w_patent_shipyard_1 w_patent_fighter_2 w_patent_fighter_3 w_patent_fighter_4 w_patent_merge_fighter_1 w_patent_shipyard_2 w_patent_corvette_1 w_patent_corvette_2 w_patent_corvette_3 w_patent_merge_fighter_corvette w_patent_shipyard_3 w_patent_frigate_2 w_patent_frigate_3 w_patent_frigate_4 w_patent_merge_fighter_3 w_patent_merge_corvette_2 w_patent_shipyard_4 w_patent_capital_1 w_patent_capital_2 w_patent_capital_3 w_patent_merge_frigate_1 w_patent_transport_2 w_patent_dome_academy w_patent_open_defense w_patent_dome_defense_2 w_doc_upgrade_raid w_doc_admiral_2 w_doc_prod_2 w_doc_admiral_4 w_doc_reduce_maintenance_2 w_doc_upgrade_fleet w_doc_upgrade_repair w_raid_enemy w_conquest w_defend w_train_navarch w_build_shipyard_1_orbital w_build_shipyard_2_orbital w_build_shipyard_3_orbital w_build_shipyard_4_orbital w_build_defense_global_dome w_build_defense_local_open w_build_defense_local_dome w_build_defense_local_orbital w_build_military_school_dome w_build_radar_orbital w_build_counterintelligence_open),
    "shadows" =>
      ~w(w_doc_defense_1 w_doc_spy_1 w_doc_speaker_2 w_doc_speaker_4 w_doc_speaker_dominion w_doc_infiltration w_doc_spy_2 w_doc_spy_4 w_doc_assassinate w_doc_spy_bonus w_doc_spy_def_1 w_doc_spy_def_2 w_mission_infiltrate w_mission_destabilize w_mission_assassinate w_mission_convert w_train_covert w_build_counterintelligence_open w_build_radar_orbital),
    "economy" =>
      ~w(w_build_university_open w_build_factory_orbital w_build_ideo_open w_build_market_open w_build_lift_open w_build_finance_open w_build_high_factory_dome w_build_research_open w_build_ideo_credit_open w_build_monument_dome w_build_spatioport_dome w_build_spatioport_orbital w_patent_open_credit w_patent_open_island w_patent_open_research w_patent_open_happiness w_patent_dome_ideo w_patent_dome_industries w_patent_dome_mobility w_patent_open_mobility w_doc_credit_1 w_doc_credit_2 w_doc_tech_2 w_doc_ideo_2)
  }

  # Fold the focus multipliers into the flat weights once at init — the
  # policy then reads plain numbers; mutation still acts on the raw genes.
  defp apply_focus(genome) do
    Enum.reduce(@families, genome, fn {family, keys}, acc ->
      factor = Map.get(acc, "focus_#{family}", 1.0)
      Enum.reduce(keys, acc, fn key, a -> Map.update(a, key, 0.0, &(&1 * factor)) end)
    end)
  end

  @doc "A genome approximating the hand-built Colonizer's behavior."
  def default do
    %{
      "w_build_infra_open" => 9.0,
      "w_build_infra_dome" => 3.0,
      "w_build_university_open" => 8.0,
      "w_build_factory_orbital" => 7.0,
      "w_build_ideo_open" => 6.0,
      "w_build_mine_dome" => 3.0,
      "w_build_hab_open_poor" => 2.0,
      "w_build_hab_open_rich" => 1.0,
      "w_build_research_orbital" => 1.0,
      "w_build_happy_pot_dome" => 0.5,
      "w_patent_citadel" => 9.0,
      "w_patent_infra_open_1" => 8.0,
      "w_patent_transport_1" => 5.0,
      "w_patent_dome_happiness" => 1.0,
      "w_patent_orbital_research" => 1.0,
      "w_patent_infra_dome_1" => 1.0,
      "w_doc_agent" => 9.0,
      "w_doc_admiral_1" => 1.0,
      "w_doc_system_1" => 7.0,
      "w_doc_dominion_1" => 3.0,
      "w_doc_sys_dom_2" => 3.0,
      "w_doc_system_4" => 1.0,
      "w_doc_speaker_1" => 1.0,
      "w_doc_tech_2" => 1.0,
      "w_doc_ideo_2" => 1.0,
      "w_doc_credit_1" => 1.0,
      "w_doc_credit_2" => 1.0,
      "w_doc_stab_2" => 1.0,
      "w_doc_defense_1" => 1.0,
      "w_doc_spy_1" => 1.0,
      "w_doc_speaker_2" => 1.0,
      "w_doc_infiltration" => 1.0,
      "w_mission_infiltrate" => 2.0,
      "w_mission_destabilize" => 2.0,
      "w_mission_make_dominion" => 1.0,
      "w_mission_assassinate" => 1.0,
      "w_mission_convert" => 1.0,
      "covert_focus" => 0.2,
      "r_shadow_burst" => 2.5,
      "r_shadow_sustain" => 0.8,
      "r_raid_high_pop" => 1.0,
      "r_pressure_sprawl" => 1.0,
      "r_siege_defense" => 2.5,
      "r_expand_slots" => 2.0,
      "r_sprint_lead" => 1.0,
      "r_sprint_trail" => 1.0,
      "fleet_retreat_hp" => 0.35,
      "sandbag" => 0.0,
      "w_governor" => 2.0,
      "w_patent_shipyard_1" => 1.0,
      "w_patent_fighter_2" => 0.4,
      "w_patent_merge_fighter_1" => 0.3,
      "w_patent_shipyard_2" => 0.3,
      "w_patent_corvette_1" => 0.3,
      "w_build_shipyard_1_orbital" => 1.0,
      "blueprint_aggression" => 0.4,
      "blueprint_mix" => 0.3,
      "fleet_investment" => 1.0,
      "w_raid_enemy" => 1.0,
      "w_conquest" => 1.0,
      "w_train_navarch" => 1.0,
      "w_train_covert" => 1.0,
      "w_flip_dominion" => 1.0,
      "w_undo_dominion" => 0.4,
      "army_size" => 4.0,
      "reaction_stance" => 1.5,
      "focus_expansion" => 1.0,
      "focus_military" => 1.0,
      "focus_shadows" => 1.0,
      "focus_economy" => 1.0,
      "w_defend" => 0.4,
      "fleet_readiness" => 0.6,
      "opener_variant" => 0.0,
      "credit_floor" => 6_000.0,
      # Chase the growth curve at moderate aggression, stop at the ~70-pop
      # knee where the 120-cap factor has halved the rate (player wisdom).
      "w_growth" => 6.0,
      "growth_pop_target" => 70.0,
      "expansion_colony_target" => 4.0,
      "prod_floor" => 150.0,
      # Inert by default: existing champions keep their exact behavior
      # (mutate/1 backfills at this value); evolution turns the ROI
      # module up where it pays.
      "w_econ_roi" => 0.0,
      "targets" => default_targets()
    }
  end

  # --- structural genes: evolvable targeting (game-ai-v2.md §2) --------------
  #
  # `genome["targets"]` maps each decision point to a LIST of
  # [consideration, weight] pairs (see Headless.Bot.Considerations).
  # Candidates are ranked by weighted sum. Structure evolves by
  # complexification: defaults are MINIMAL (the V1 behaviors), and
  # mutations add/remove/replace considerations from the library.

  @target_points ~w(colonize raid conquest defend infiltrate destabilize)

  def target_points, do: @target_points

  @doc "Minimal seed structure — reproduces V1's hard-coded targeting."
  def default_targets do
    %{
      "colonize" => [["strength", 1.0], ["proximity", 1.0]],
      "raid" => [["proximity", 1.0]],
      "conquest" => [["proximity", 1.0]],
      "defend" => [["population", 1.0]],
      "infiltrate" => [["proximity", 1.0]],
      "destabilize" => [["proximity", 1.0]]
    }
  end

  # The genome's target structure, seeding V1-era genomes that predate it.
  defp targets_of(g), do: Map.get(g, "targets") || default_targets()

  defp random_targets do
    Map.new(@target_points, fn point ->
      considerations = Enum.take_random(Headless.Bot.Considerations.names(), :rand.uniform(3))
      considerations = if considerations == [], do: ["proximity"], else: considerations
      {point, Enum.map(considerations, fn c -> [c, 0.25 + :rand.uniform() * 1.5] end)}
    end)
  end

  # One structural op on one random decision point: add a library
  # consideration (complexification), remove one (only if >1 remain), or
  # replace one. Weights inside lists get the same gaussian treatment as
  # flat genes.
  defp mutate_targets(targets, sigma) do
    perturbed =
      Map.new(targets, fn {point, list} ->
        {point,
         Enum.map(list, fn [c, w] ->
           [c, (w + :rand.normal() * sigma * 2.0) |> max(0.0) |> min(3.0)]
         end)}
      end)

    if :rand.uniform() < 0.3 do
      point = Enum.random(@target_points)
      list = Map.get(perturbed, point, [["proximity", 1.0]])
      present = MapSet.new(list, fn [c, _] -> c end)
      absent = Enum.reject(Headless.Bot.Considerations.names(), &MapSet.member?(present, &1))

      list =
        case {Enum.random([:add, :remove, :replace]), absent, list} do
          {:add, [_ | _], _} -> [[Enum.random(absent), 0.5 + :rand.uniform()] | list]
          {:remove, _, [_, _ | _]} -> List.delete_at(list, :rand.uniform(length(list)) - 1)
          {:replace, [_ | _], [_ | _]} -> List.replace_at(list, :rand.uniform(length(list)) - 1, [Enum.random(absent), 0.5 + :rand.uniform()])
          _ -> list
        end

      Map.put(perturbed, point, list)
    else
      perturbed
    end
  end

  def random(rng \\ &:rand.uniform/0) do
    spec()
    |> Map.new(fn {key, {lo, hi}} -> {key, lo + rng.() * (hi - lo)} end)
    |> Map.put("targets", random_targets())
  end

  @doc """
  Fill any spec gene MISSING from `genome` with a RANDOM value from its range,
  preserving existing genes and targets. This is how a newly-added gene should
  onboard into an existing population (user methodology 2026-07-11): seeding
  the whole range gives the GA immediate variance to select on. Defaulting a
  fresh gene to one value (or leaving it absent → the policy's 0.0 fallback)
  leaves variance ≈ 0, so the gene is effectively inert until random mutation
  happens to reintroduce it — "added" in name only. Idempotent: once seeded and
  saved, the gene is present and left alone. (Distinct from mutate/1's
  inert-default backfill, which deliberately does NOT change an old champion's
  phenotype; seeding is the opt-in diversity path for genes we WANT explored.)
  """
  def seed_missing(genome, rng \\ &:rand.uniform/0) do
    Enum.reduce(spec(), genome, fn {key, {lo, hi}}, acc ->
      if Map.has_key?(acc, key), do: acc, else: Map.put(acc, key, lo + rng.() * (hi - lo))
    end)
  end

  @doc "Gaussian mutation on flat genes + one structural op on the target lists."
  def mutate(genome, sigma \\ 0.15) do
    defaults = default()

    spec()
    |> Map.new(fn {key, {lo, hi}} ->
      # INERT-BY-DEFAULT onboarding (user concern 2026-07-06): a champion
      # bred before a gene existed must not involuntarily change phenotype
      # when mutated — missing genes backfill at the DELIBERATE default
      # (usually inert for reactions), never the range midpoint. New
      # capabilities reach old lineages only when mutation actively pushes
      # the gene, or via seeds/randoms that carry it on purpose.
      base = Map.get(genome, key) || Map.get(defaults, key) || (lo + hi) / 2
      value = base + :rand.normal() * sigma * (hi - lo)
      {key, value |> max(lo) |> min(hi)}
    end)
    |> Map.put("targets", mutate_targets(targets_of(genome), sigma))
  end

  @doc "Total consideration count across all decision points (structural size)."
  def structure_size(genome) do
    genome |> targets_of() |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end

  # --- policy ------------------------------------------------------------------

  @impl true
  def init(ctx) do
    # Experiment flags ride in through a reserved params key — per-bot
    # treatment assignment, not heredity (Headless.Flags). The marathon
    # sets it on the evolver's params only; archives never store it.
    {flags, params} = Map.pop(Map.get(ctx, :params, %{}), "_flags", %{})

    %{
      genome: apply_focus(Map.merge(default(), params)),
      flags: flags,
      # Lazily created on the first decision — the opener book needs the
      # faction, which only the view knows.
      opener: nil,
      dispatched: nil,
      target_scores: nil,
      reactions_set: MapSet.new(),
      tick: 0,
      last_transform: -1_000,
      last_doctrine_try: -1_000,
      blocks: %{}
    }
  end

  @impl true
  def decide(view, mem) do
    mem = %{mem | tick: mem.tick + 1}

    # A player conquered down to zero systems is (nearly) dead — there is no
    # home to act from, and most stages pattern-match on owning at least one
    # system. Idle gracefully instead of crashing the driver (this took the
    # whole marathon down the first night warfare actually worked).
    if view.player.stellar_systems == [] do
      {[], mem}
    else
      do_decide(view, mem)
    end
  end

  # Policy/lex changes are rate-limited: some swaps are engine-refused for
  # reasons the policy can't observe (e.g. :not_enough_admirals_slot when a
  # swap would drop a capacity lex that active characters depend on), and
  # retrying every decision burned hundreds of calls per game.
  @doctrine_dwell 15

  # V2.1 opener gate: while the faction's opening book runs, it owns
  # every decision — the evolved weights take over only at handover
  # (game-ai-v2.md §V2.1). The book is code; the genome chose the variant.
  defp do_decide(view, mem) do
    opener = Map.get(mem, :opener) || Opener.new(mem.genome, view)
    {opener_actions, opener} = Opener.step(opener, view)
    mem = Map.put(mem, :opener, opener)

    if opener.done,
      do: decide_main(view, mem),
      else: {opener_actions, mem}
  end

  defp decide_main(view, mem) do
    # Reactive modulation: observable threats scale weight groups for THIS
    # decision only (mem.genome stays pristine — reactions are behavior,
    # not heredity). Stages read the modulated copy via active_genome/1.
    # Econ patent pressure rides the same per-decision copy: patents that
    # gate wanted buildings get boosted by ROI-module trust.
    # V3: the Strategist classifies the game phase and applies the phase's
    # code-level directives (the former apply_expansion_priority arms).
    # Phase is recorded in mem for telemetry (bot checkpoints/tallies).
    phase = Strategist.phase(view, mem)
    mem = Map.put(mem, :phase, phase)

    mem =
      Map.put(
        mem,
        :genome_active,
        mem.genome
        |> apply_reactions(view)
        |> Strategist.steer(phase, view, Map.get(mem, :flags) || %{})
        |> Econ.patent_pressure(view, @catalog)
      )
    g = active_genome(mem)

    # V3 pillar 2: reconcile the budget ledger and allocate this decision's
    # inflow across the pools by phase splits × focus_* leans. Every spend
    # node below draws from its pool — saving is pool rollover, not
    # reservation.
    mem = Budget.allocate(mem, view, phase, g)

    # V3 pillar 3: settle colony-task lifecycles (completions/losses) before
    # the ship/mission nodes open or advance new ones.
    mem = colony_task_maintenance(view, mem)

    {mission, mem} = mission_actions(view, mem)
    {covert, mem} = employ_agents(view, mem)
    {military, mem} = fleet_employment(view, mem)
    {reactions, mem} = reaction_actions(view, mem)
    {dominion, mem} = dominion_actions(view, mem)

    {doctrines, mem} =
      if mem.tick - Map.get(mem, :last_doctrine_try, -@doctrine_dwell) >= @doctrine_dwell do
        case doctrine_actions(view, mem) do
          {[], mem} -> {[], mem}
          {actions, mem} -> {actions, %{mem | last_doctrine_try: mem.tick}}
        end
      else
        {[], mem}
      end

    {patents, mem} = patent_action(view, mem)
    {ships, mem} = ship_actions(view, mem)
    {roster, mem} = roster_actions(view, mem)
    {warships, mem} = fleet_commission(view, mem)
    {builds, mem} = build_actions(view, mem)

    actions =
      patents ++
        doctrines ++
        roster ++
        ships ++
        warships ++
        dominion ++
        builds ++
        mission ++
        covert ++
        military ++
        reactions

    {actions, mem}
  end

  # --- budget pool domains ------------------------------------------------------

  # Which pool pays for each patent/lex (V3 pillar 2). Ship-line and
  # defense patents are military; the transports are expansion; everything
  # else (infra/research/happiness/credit chains) is economy.
  @military_patents ~w(shipyard_1 shipyard_2 shipyard_3 shipyard_4 fighter_2 fighter_3 fighter_4
                       merge_fighter_1 merge_fighter_corvette merge_fighter_3 merge_corvette_2
                       merge_frigate_1 corvette_1 corvette_2 corvette_3 frigate_2 frigate_3
                       frigate_4 capital_1 capital_2 capital_3 open_defense dome_defense_2 dome_academy)a
  @expansion_patents ~w(transport_1 transport_2)a

  defp patent_pool(key) when key in @expansion_patents, do: :expansion
  defp patent_pool(key) when key in @military_patents, do: :military
  defp patent_pool(_key), do: :economy

  # Lexes: the system/dominion cap ladder plus base agent capacity and the
  # first admiral slot serve expansion; the fleet-command ladder is
  # military; the covert branches covert; the economy branches economy.
  @expansion_doctrines ~w(agent system_1 dominion_1 sys_dom_2 system_4 dominion_3 admiral_1)a
  @military_doctrines ~w(upgrade_raid admiral_2 prod_2 admiral_4 reduce_maintenance_2 upgrade_fleet upgrade_repair)a
  @covert_doctrines ~w(defense_1 speaker_2 speaker_4 speaker_dominion spy_def_1 spy_def_2 spy_1
                       infiltration spy_4 assassinate spy_bonus)a

  defp doctrine_pool(key) when key in @expansion_doctrines, do: :expansion
  defp doctrine_pool(key) when key in @military_doctrines, do: :military
  defp doctrine_pool(key) when key in @covert_doctrines, do: :covert
  defp doctrine_pool(_key), do: :economy

  # --- expansion critical path ------------------------------------------------
  #
  # V3: the critical-path arms (expansion chain, tech bootstrap, research
  # rung, growth rungs, parallel admirals) moved to Headless.Strategist,
  # organized per game phase (docs/game-ai-v3.md, Phase 1 of the
  # migration). decide_main applies them via Strategist.steer/3.

  # V3 pillar 2: the soft tech reservation (reserve_first_colony /
  # reserve_followup_colony, 2026-07-11) is retired — the expansion pool's
  # rollover IS the colony-ship savings account now, and no other pool can
  # drain it (Headless.Budget).

  # --- V3 pillar 3: colony-task lifecycle (docs/game-ai-v3.md) -----------------
  #
  # Every transport order opens an implicit ColonyTask keyed by admiral;
  # dispatch and completion stamp the two durations that decompose
  # first-colony latency: WAIT (order -> dispatch = ship build + idle at
  # dock) and VOYAGE (dispatch -> claim = travel + colonization). Rolled
  # into results.jsonl as stats.colony_cycle — the measurement behind the
  # sys-plateau investigation (bots spend ~2/3 of decisions pre-first-
  # colony; this says which half of the cycle eats the clock).
  defp colony_task_maintenance(view, mem) do
    tasks = Map.get(mem, :colony_tasks, %{})

    {tasks, log} =
      Enum.reduce(tasks, {%{}, Map.get(mem, :colony_log, [])}, fn {admiral_id, task}, {keep, log} ->
        case view.characters[admiral_id] do
          # Admiral gone (killed, dismissed mid-task): the task is lost.
          nil ->
            {keep, log}

          admiral ->
            # DT-1a: stamp the moment the ship exists — splits WAIT into
            # BUILD (order -> built, production-bound) and IDLE (built ->
            # dispatch, dispatch-gate-bound), the decomposition that decides
            # whether to attack production siting or dispatch logic.
            task =
              if task[:built_ut] == nil and has_transport?(admiral) and is_number(view.now_ut),
                do: Map.put(task, :built_ut, view.now_ut),
                else: task

            if task[:dispatched_ut] != nil and
                 not (has_transport?(admiral) or transport_pending?(admiral)) do
              # Dispatched and the transport is gone — colonization consumed
              # it; the task is complete.
              built = task[:built_ut] || task[:dispatched_ut]

              entry = %{
                wait: task[:dispatched_ut] - task[:ordered_ut],
                build: built - task[:ordered_ut],
                idle: task[:dispatched_ut] - built,
                voyage: (view.now_ut || task[:dispatched_ut]) - task[:dispatched_ut]
              }

              {keep, [entry | log]}
            else
              {Map.put(keep, admiral_id, task), log}
            end
        end
      end)

    mem |> Map.put(:colony_tasks, tasks) |> Map.put(:colony_log, log)
  end

  defp open_colony_task(mem, admiral_id, now_ut) when is_number(now_ut) do
    tasks = Map.get(mem, :colony_tasks, %{})
    Map.put(mem, :colony_tasks, Map.put(tasks, admiral_id, %{ordered_ut: now_ut}))
  end

  defp open_colony_task(mem, _admiral_id, _now_ut), do: mem

  defp stamp_colony_dispatch(mem, admiral_id, now_ut) when is_number(now_ut) do
    tasks = Map.get(mem, :colony_tasks, %{})
    task = Map.get(tasks, admiral_id, %{ordered_ut: now_ut})
    Map.put(mem, :colony_tasks, Map.put(tasks, admiral_id, Map.put(task, :dispatched_ut, now_ut)))
  end

  defp stamp_colony_dispatch(mem, _admiral_id, _now_ut), do: mem

  # --- reactions --------------------------------------------------------------

  # The per-decision genome: reactive modulation applied, falling back to
  # the raw genome outside decide (init, external readers).
  defp active_genome(mem), do: Map.get(mem, :genome_active) || mem.genome

  @shadow_defense_keys ~w(w_build_counterintelligence_open w_build_radar_orbital w_patent_open_defense w_patent_dome_defense_2 w_patent_infra_dome_1 w_patent_dome_happiness w_mission_assassinate w_mission_convert)

  # Threat signals are CODE (observable facts); how hard to react is GENOME.
  #
  # Shadow reaction shape (two-phase, per user analysis): the BURST is an
  # interrupt — it holds while the threat exists AND the empire has zero
  # counterintelligence (queued or built); installing one acknowledges the
  # interrupt and the burst drops away, leaving the stage-scaled SUSTAIN
  # ("prefer the intel building over another credit building") for as long
  # as the enemy stays on the track. Statelessly derived every decision, so
  # a demolished counterintel or a new stage crossing re-raises it.
  defp apply_reactions(g, view) do
    signals = threat_signals(view)
    stage = signals.enemy_shadow_stage

    shadow_r =
      if stage >= 2 do
        burst = if counterintel_present?(view), do: 0.0, else: Map.get(g, "r_shadow_burst", 0.0)
        burst + Map.get(g, "r_shadow_sustain", 0.0) * (stage - 1)
      else
        0.0
      end

    g
    |> boost(shadow_r > 0.0, @shadow_defense_keys, shadow_r)
    |> boost(signals.pop_ratio > 1.3, ~w(w_raid_enemy), Map.get(g, "r_raid_high_pop", 0.0))
    |> boost(
      signals.sprawl_ratio > 1.3,
      ~w(w_mission_make_dominion w_conquest),
      Map.get(g, "r_pressure_sprawl", 0.0)
    )
    # Own system under siege: the defend weight spikes; employment_target
    # triages besieged systems first (catalog #25).
    |> boost(signals.besieged?, ~w(w_defend), Map.get(g, "r_siege_defense", 0.0))
    # Open dominion slots = paid capacity going unused: the propaganda /
    # flip pipeline gets a "get to work" push proportional to how many.
    |> boost(
      signals.open_dominion_slots > 0,
      ~w(w_mission_make_dominion w_flip_dominion),
      Map.get(g, "r_expand_slots", 0.0) * min(signals.open_dominion_slots, 3)
    )
    # Closing sprint (catalog #42): in the endgame, a leader converts
    # everything into VP-now plays; a trailer gambles on swings.
    |> boost(
      signals.endgame? and signals.leading?,
      ~w(w_mission_infiltrate w_mission_make_dominion w_flip_dominion),
      Map.get(g, "r_sprint_lead", 0.0)
    )
    |> boost(
      signals.endgame? and not signals.leading?,
      ~w(w_conquest w_raid_enemy w_mission_destabilize),
      Map.get(g, "r_sprint_trail", 0.0)
    )
    |> sandbag_gate(view, g)
  end

  # Track sandbagging (catalog #13): with the gene on, hold infiltration
  # just below the next visibility milestone until >= 3 Erased are idle and
  # ready — then release, crossing the threshold in one burst instead of
  # telegraphing the climb to every reaction layer watching stage crossings.
  defp sandbag_gate(g, view, raw_g) do
    with true <- Map.get(raw_g, "sandbag", 0.0) >= 0.5,
         %{factions: factions} <- view.victory,
         %{visibility_track: %{points: points, index: index, milestones: milestones}} <-
           Enum.find(factions, &(&1.key == view.player.faction)),
         true <- is_list(milestones),
         next when is_number(next) <- Enum.at(milestones, index),
         true <- points >= 0.85 * next,
         true <- length(idle_spies(view)) < 3 do
      Map.put(g, "w_mission_infiltrate", 0.0)
    else
      _ -> g
    end
  end

  defp idle_spies(view) do
    view
    |> on_board_of_type(:spy)
    |> Enum.filter(&(&1.action_status == :idle and queue_empty?(&1)))
  end

  # Interrupt acknowledgement: any counterintelligence ordered or standing
  # anywhere in the empire.
  defp counterintel_present?(view) do
    Enum.any?(view.systems, fn {_id, system} ->
      system.bodies
      |> HomeDev.flatten_bodies()
      |> Enum.any?(fn body ->
        Enum.any?(body.tiles, fn t ->
          t.building_key == :counterintelligence_open and t.building_status != :empty
        end)
      end)
    end)
  end

  defp boost(g, false, _keys, _r), do: g
  defp boost(g, _true, _keys, r) when r <= 0.0, do: g

  defp boost(g, true, keys, r) do
    Enum.reduce(keys, g, fn k, acc -> Map.update(acc, k, 0.0, &(&1 * (1 + r))) end)
  end

  defp threat_signals(view) do
    my_faction = view.player.faction

    {enemy_tracks, my_vp, best_enemy_vp, time_left} =
      case view.victory do
        %{factions: factions, ut_time_left: t} ->
          mine = Enum.find(factions, &(&1.key == my_faction))
          enemies = Enum.reject(factions, &(&1.key == my_faction))

          {enemies, (mine && mine.victory_points) || 0,
           enemies |> Enum.map(& &1.victory_points) |> Enum.max(fn -> 0 end), t || 9.0e9}

        _ ->
          {[], 0, 0, 9.0e9}
      end

    systems = view.galaxy.stellar_systems
    my_pop = systems |> Enum.filter(&(&1.faction == my_faction)) |> Enum.map(& &1.population) |> Enum.sum()
    my_count = Enum.count(systems, &(&1.faction == my_faction))

    {enemy_pop, enemy_count} =
      systems
      |> Enum.filter(&(&1.faction != nil and &1.faction != my_faction))
      |> Enum.reduce({0.0, 0}, fn s, {p, c} -> {p + s.population, c + 1} end)

    %{
      enemy_shadow_stage:
        enemy_tracks
        |> Enum.map(fn f -> get_in(f.visibility_track, [:index]) || 0 end)
        |> Enum.max(fn -> 0 end),
      pop_ratio: enemy_pop / max(my_pop, 1.0),
      sprawl_ratio: enemy_count / max(my_count, 1),
      besieged?: Enum.any?(view.systems, fn {_id, s} -> s.siege != nil end),
      open_dominion_slots:
        max(trunc(view.player.max_dominions.value) - Enum.count(view.systems, fn {_id, s} -> s.status == :inhabited_dominion end), 0),
      # Last ~20% of a full Fast game (2400 UT).
      endgame?: time_left < 500,
      leading?: my_vp > best_enemy_vp
    }
  end

  # --- weighted choices ----------------------------------------------------------

  # Highest-weighted affordable patent whose ancestor is owned, ranked by
  # EFFECTIVE weight (V2.1 desire propagation): a zero-weight prerequisite
  # under a wanted descendant is a stepping stone, not a wall. Effective
  # weight < 0.5 means "never buy" — pruning now requires the whole
  # subtree to be unwanted.
  defp patent_action(view, mem) do
    g = active_genome(mem)
    player = view.player
    eff = effective_weights(g, @patents, "w_patent_")

    # Strict priority with saving PER POOL (V3): each pool targets its own
    # highest-weight unlocked patent and saves toward it independently.
    # A single global target caused cross-pool head-of-line blocking — the
    # transport patent (expansion pool, trickling) stalled the growth
    # patents (economy pool, funded), collapsing stability to 2-4 within
    # one restart (2026-07-15). Up to one purchase per pool per decision.
    @patents
    |> Enum.reject(fn {key, _, _} -> key in player.patents end)
    |> Enum.filter(fn {key, _cost, ancestor} ->
      Map.get(eff, key, 0.0) >= 0.5 and (ancestor == nil or ancestor in player.patents)
    end)
    |> Enum.group_by(fn {key, _, _} -> patent_pool(key) end)
    |> Enum.reduce({[], mem}, fn {pool, candidates}, {actions, m} ->
      {key, cost, _} = Enum.max_by(candidates, fn {key, _, _} -> Map.get(eff, key, 0.0) end)

      if Budget.afford?(m, pool, :technology, cost),
        do: {[{:purchase_patent, key} | actions], Budget.spend(m, pool, :technology, cost)},
        else: {actions, m}
    end)
  end

  # Highest-weighted affordable doctrine by EFFECTIVE weight (V2.1 desire
  # propagation — `system_1` is the ancestor of every dominion lex, so a
  # zero there must not sever the ladder). Activation below still uses RAW
  # weights: stepping stones get bought, not seated in scarce slots.
  defp doctrine_actions(view, mem) do
    g = active_genome(mem)
    player = view.player
    owned = player.doctrines
    active = player.policies
    eff = effective_weights(g, @doctrines, "w_doc_")

    # Strict priority with saving PER POOL (V3, see patent_action — same
    # cross-pool head-of-line fix). Doctrine costs INFLATE per owned
    # doctrine beyond the base price the ledger knows — the allocator's
    # reconcile absorbs the drift, and a genuinely unaffordable purchase is
    # engine-refused as before.
    #
    # (A raw-ideology "cap-rung guarantee" bypass was A/B-tested here
    # 2026-07-18/19 and LOST decisively — col/eval 1.41 vs 1.78: firing
    # ~4×/game, it bought the ladder eagerly and starved every other
    # ideology consumer. Pool discipline stays.)
    {purchase, mem} =
      @doctrines
      |> Enum.reject(fn {key, _, _} -> key in owned end)
      |> Enum.filter(fn {key, _cost, ancestor} ->
        Map.get(eff, key, 0.0) >= 0.5 and (ancestor == nil or ancestor in owned)
      end)
      |> Enum.group_by(fn {key, _, _} -> doctrine_pool(key) end)
      |> Enum.reduce({[], mem}, fn {pool, candidates}, {actions, m} ->
        {key, cost, _} = Enum.max_by(candidates, fn {key, _, _} -> Map.get(eff, key, 0.0) end)

        if Budget.afford?(m, pool, :ideology, cost),
          do: {[{:purchase_doctrine, key} | actions], Budget.spend(m, pool, :ideology, cost)},
          else: {actions, m}
      end)

    wanted_active =
      owned
      |> Enum.sort_by(fn key -> -Map.get(g, "w_doc_#{key}", 0.0) end)
      |> Enum.take(player.max_policies)

    activation =
      cond do
        owned == [] ->
          []

        Enum.sort(wanted_active) != Enum.sort(active) ->
          [{:update_policies, wanted_active}]

        # All slots match the top-weighted owned set, but a wanted doctrine
        # is still benched — buy a slot. (The earlier "only when the top-K
        # set mismatches" version never bought slots when the #1 weight was
        # already active; evolution literally routed around it by
        # down-weighting :agent. Bugs become selection pressure.)
        length(owned) > player.max_policies and
            Enum.any?(owned -- active, &(Map.get(g, "w_doc_#{&1}", 0.0) >= 0.5)) ->
          [{:purchase_policy_slot}]

        true ->
          []
      end

    {purchase ++ activation, mem}
  end

  # V2.1 desire propagation: effective weight = max(own, 0.9 × best
  # descendant), recursively over the prerequisite tree. A genome that
  # wants capital_1 at 10.0 no longer strands it behind a 0.00 shipyard_1
  # — the ancestor carries the descendant's desire at a small depth
  # discount, so ladders get climbed in order and zero means "never for
  # its own sake" instead of "sever the branch".
  @desire_discount 0.9

  defp effective_weights(g, entries, prefix) do
    children = Enum.group_by(entries, fn {_k, _c, anc} -> anc end, fn {k, _c, _a} -> k end)

    entries
    |> Enum.reduce(%{}, fn {key, _, _}, memo -> elem(effective_weight(key, g, prefix, children, memo), 1) end)
  end

  defp effective_weight(key, g, prefix, children, memo) do
    case memo do
      %{^key => v} ->
        {v, memo}

      _ ->
        own = Map.get(g, "#{prefix}#{key}", 0.0)

        {best_child, memo} =
          children
          |> Map.get(key, [])
          |> Enum.reduce({0.0, memo}, fn child, {best, m} ->
            {v, m} = effective_weight(child, g, prefix, children, m)
            {max(best, v), m}
          end)

        v = max(own, @desire_discount * best_child)
        {v, Map.put(memo, key, v)}
    end
  end

  # Roster management across all three agent types. Caps come from lexes
  # (the genome's capacity choices); mission weights gate whether a type is
  # wanted on the map. Governors are installed from spare deck characters of
  # ANY type (passive bonuses). At most one activation and one hire per
  # decision.
  @agent_types [:admiral, :spy, :speaker]

  defp roster_actions(view, mem) do
    g = active_genome(mem)
    {hire, mem} = hire_action(view, mem)
    {activate_action(view, g) ++ governor_action(view, g) ++ hire, mem}
  end

  defp wants_on_board?(:admiral, _g), do: true

  # A covert agent is worth activating if the genome weights ANY of its
  # missions — not just one. The old single-mission gate benched entire
  # agent types: myrmezir wants speakers for make_dominion (its core sector-
  # flip play) but the gate only checked destabilize, so 75% of its speakers
  # sat un-activated in the deck (instrumentation 2026-07-09).
  defp wants_on_board?(:spy, g),
    do: Map.get(g, "w_mission_infiltrate", 0.0) >= 0.5 or Map.get(g, "w_mission_assassinate", 0.0) >= 0.5

  defp wants_on_board?(:speaker, g),
    do:
      Map.get(g, "w_mission_destabilize", 0.0) >= 0.5 or Map.get(g, "w_mission_make_dominion", 0.0) >= 0.5 or
        Map.get(g, "w_mission_convert", 0.0) >= 0.5

  defp cap(player, :admiral), do: player.max_admirals.value
  defp cap(player, :spy), do: player.max_spies.value
  defp cap(player, :speaker), do: player.max_speakers.value

  defp active_of_type(view, type),
    do: view.characters |> Map.values() |> Enum.filter(&(&1.type == type))

  defp deck_of_type(player, type) do
    Enum.filter(player.character_deck, fn
      %{character: %{type: ^type}, cooldown: nil} -> true
      _ -> false
    end)
  end

  defp activate_action(view, g) do
    player = view.player
    [%{id: home_id} | _] = player.stellar_systems

    Enum.find_value(@agent_types, [], fn type ->
      deck = deck_of_type(player, type)

      if wants_on_board?(type, g) and deck != [] and
           length(active_of_type(view, type)) < cap(player, type) do
        [{:activate_character, hd(deck).character.id, :on_board, home_id}]
      end
    end)
  end

  # Install a governor (any agent type — passive bonuses) at an owned system
  # lacking one, from spare deck characters that on-board missions don't
  # need.
  defp governor_action(view, g) do
    player = view.player

    with true <- Map.get(g, "w_governor", 0.0) >= 0.5,
         {system_id, _} <- Enum.find(view.systems, fn {_id, s} -> s.governor == nil end),
         %{character: %{id: char_id, type: type}} <- spare_deck_character(view, g),
         true <- length(active_of_type(view, type)) < cap(player, type) do
      [{:activate_character, char_id, :governor, system_id}]
    else
      _ -> []
    end
  end

  # Governors are NAVARCHS (user doctrine 2026-07-09): a spare admiral runs a
  # system for its passive bonuses; Erased and Siderians belong on missions,
  # not benched on governor duty (instrumentation showed myrmezir's speakers
  # spent 30% of the match as governors and never destabilized anyone). Fall
  # back to a genuinely spare covert agent only when its type is entirely
  # unwanted by this genome AND some of it is already on the map.
  defp spare_deck_character(view, g) do
    player = view.player

    case deck_of_type(player, :admiral) do
      [admiral | _] ->
        admiral

      [] ->
        [:spy, :speaker]
        |> Enum.flat_map(&deck_of_type(player, &1))
        |> Enum.find(fn %{character: %{type: type}} ->
          not wants_on_board?(type, g) and length(active_of_type(view, type)) >= 1
        end)
    end
  end

  # COLONIZER-FIRST HIRING (user directive 2026-07-12): era telemetry showed
  # median ONE Navarch per bot all game (max 8) while admiral-cap lexes were
  # bought ~5×/eval and frontier bots idled 1.1M+ credits at 3 systems —
  # bots bought the cap but never hired into it, so colonization stayed a
  # serial build→sail→claim loop (colonize_no_ready_transport outnumbered
  # syscap 54:1). While a system slot is open and the admiral cap has room,
  # hire an admiral UNCONDITIONALLY (no hire_reserve gate — market_character
  # already requires raw affordability, and each admiral is a parallel
  # colonization lane). Falls through to the generic weighted hire loop when
  # no admiral is needed or the market has none — with block telemetry so
  # the next "why no hire" question is a query, not a debugging session.
  defp hire_action(view, mem) do
    g = active_genome(mem)
    player = view.player
    open_slots = trunc(player.max_systems.value) - length(player.stellar_systems)
    n_admirals = length(active_of_type(view, :admiral)) + length(deck_of_type(player, :admiral))

    # ONE COLONIZATION LANE PER OPEN SLOT — not "fill the admiral cap".
    # The cap-scoped version claimed the single hire-per-decision whenever
    # any slot was open (i.e. most of the game), starving covert hiring
    # entirely: 2nd-half win rate collapsed 44%->28% within 3h of deploying
    # it (2026-07-13) while winners' colonies rose — colonizers improved,
    # covert niches broke. Need-scoped, the arm yields the hire slot back
    # to the weighted loop once every open slot has an admiral to work it.
    #
    # (An income-velocity lane gate — human doctrine 2a — was A/B-tested
    # here 2026-07-18/19 and LOST: fit -19, col -0.22, zero-colony +6pts.
    # At bot income levels the gate mostly produced fewer colonies; revisit
    # only with cycle telemetry showing an idle-lane cost.)
    admiral_target = min(cap(player, :admiral), open_slots)

    if open_slots > 0 and n_admirals < admiral_target do
      case market_admiral(view, mem) do
        {:ok, candidate} -> {[{:hire_character, candidate.id}], spend_hire(mem, :expansion, candidate)}
        {:blocked, why} -> generic_hire(view, block(mem, why), g)
      end
    else
      generic_hire(view, mem, g)
    end
  end

  # A hire consumes all three resources from the sponsoring pool.
  defp spend_hire(mem, pool, candidate) do
    mem
    |> Budget.spend(pool, :credit, Map.get(candidate, :credit_cost, 0))
    |> Budget.spend(pool, :technology, Map.get(candidate, :technology_cost, 0))
    |> Budget.spend(pool, :ideology, Map.get(candidate, :ideology_cost, 0))
  end

  # Which pool sponsors a generic hire: extra admirals (beyond the
  # colonization lanes) are military; covert agents are covert.
  defp hire_pool(:admiral), do: :military
  defp hire_pool(_type), do: :covert

  # Why can't we hire an admiral RIGHT NOW? The market always stocks
  # admirals (slots refill on purchase — user 2026-07-13), so "no admiral"
  # is almost never the truth: the block must name the unaffordable
  # RESOURCE. The original :hire_no_market_admiral label hid that admirals
  # cost TECHNOLOGY (common 400-700, higher ranks ×21/×36) — the same pool
  # the ship (2000) and every forced patent drain — repeating the exact
  # conflation the transport_unaffordable split was supposed to bury.
  defp market_admiral(%{market: nil}, _mem), do: {:blocked, :hire_admiral_market_empty}

  defp market_admiral(view, mem) do
    admirals =
      view.market.slots
      |> Enum.flat_map(& &1.data)
      |> Enum.flat_map(& &1.data)
      |> Enum.map(& &1.character)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.type == :admiral))

    cheapest = Enum.min_by(admirals, &Map.get(&1, :credit_cost, 0), fn -> nil end)

    cond do
      cheapest == nil ->
        {:blocked, :hire_admiral_market_empty}

      not Budget.afford?(mem, :expansion, :technology, Map.get(cheapest, :technology_cost, 0)) ->
        {:blocked, :hire_admiral_no_tech}

      not Budget.afford?(mem, :expansion, :credit, Map.get(cheapest, :credit_cost, 0)) ->
        {:blocked, :hire_admiral_no_credit}

      not Budget.afford?(mem, :expansion, :ideology, Map.get(cheapest, :ideology_cost, 0)) ->
        {:blocked, :hire_admiral_no_ideology}

      true ->
        {:ok, cheapest}
    end
  end

  # One weighted hire per decision, paid from the type's sponsoring pool
  # (V3 — replaces the hire_reserve gene gate: pool discipline is the
  # spending brake now, and covert hires can't be starved by admiral needs
  # because they draw from different pools).
  defp generic_hire(view, mem, g) do
    player = view.player

    @agent_types
    |> Enum.find_value(fn type ->
      wanted =
        wants_on_board?(type, g) or
          (Map.get(g, "w_governor", 0.0) >= 0.5 and Enum.any?(view.systems, fn {_, s} -> s.governor == nil end))

      below_cap = length(active_of_type(view, type)) + length(deck_of_type(player, type)) < cap(player, type)
      pool = hire_pool(type)

      with true <- wanted and below_cap,
           candidate when candidate != nil <- market_character(view, type),
           true <- Budget.afford?(mem, pool, :credit, Map.get(candidate, :credit_cost, 0)),
           true <- Budget.afford?(mem, pool, :technology, Map.get(candidate, :technology_cost, 0)),
           true <- Budget.afford?(mem, pool, :ideology, Map.get(candidate, :ideology_cost, 0)) do
        {candidate, pool}
      else
        _ -> nil
      end
    end)
    |> case do
      nil -> {[], mem}
      {candidate, pool} -> {[{:hire_character, candidate.id}], spend_hire(mem, pool, candidate)}
    end
  end

  # Order a transport for the COLONIZER admiral (lowest id) when it lacks
  # one, at whatever OWNED system it is docked (colonies become production
  # sites as they develop). Warfleet admirals get warships instead — see
  # warship_actions.
  defp ship_actions(view, mem) do
    # SLOT-GATED (user model 2026-07-06): players plan colony ships around
    # WHEN the next system slot unlocks — the ship is the cheap part, the
    # lex slot is the scarce part. So transports are only ordered while
    # open system slots exceed the transports already owned/being built,
    # and the pipeline self-serializes: slot opens -> transport -> sail.
    #
    # Every non-order names its gate in mem.blocks (same telemetry the
    # colonization pipeline earned on 2026-07-06 — the ship path's lack of
    # it cost a full debugging session on 2026-07-07).
    #
    # NO queue_idle? gate: that is an engine rule for BUILDINGS only —
    # ship orders enqueue regardless (fleet_commission batches 18 at once).
    # The defensive idle-check this used to carry deadlocked expansion the
    # moment the Econ ROI module kept build queues permanently busy.
    player = view.player
    open_slots = trunc(player.max_systems.value) - length(player.stellar_systems)

    committed =
      view
      |> on_board_admirals()
      |> Enum.count(fn a -> has_transport?(a) or transport_pending?(a) end)

    # FIRST-COLONY GUARANTEE (hard-coded 2026-07-19 after winning its 24h
    # A/B: zero-colony 22% vs 29%, col/eval +0.08, fit +7): with ZERO
    # colonies the pools' trickle must not be what blocks the first
    # transport — the first colony is the whole game (82% of zero-colony
    # games die at funnel stage 5 with every prerequisite met). When the
    # RAW stock covers the ship, order it regardless of pool balances;
    # pool discipline resumes the moment the first colony exists.
    guarantee? =
      length(player.stellar_systems) <= 1 and
        player.technology.value >= @transport_tech and
        player.credit.value >= @transport_credit

    cond do
      open_slots <= 0 ->
        {[], block(mem, :transport_no_slot)}

      open_slots <= committed ->
        {[], block(mem, :transport_all_committed)}

      :transport_1 not in player.patents ->
        # Emitting anyway would be refused :patent_not_unlocked — the
        # patent chain is Econ.patent_pressure's job; blocking here makes
        # the starvation visible instead of 600 wasted engine calls.
        {[], block(mem, :transport_patent_locked)}

      # Affordability split by RESOURCE (2026-07-11), now against the
      # EXPANSION POOL (V3): the pool's rollover is the ship's savings
      # account — development spending literally cannot touch it.
      not Budget.afford?(mem, :expansion, :technology, @transport_tech) and not guarantee? ->
        {[], block(mem, :transport_no_tech)}

      not Budget.afford?(mem, :expansion, :credit, @transport_credit) and not guarantee? ->
        {[], block(mem, :transport_no_credit)}

      true ->
        # DT-1b SHIPYARD-HUB ROUTING (2026-07-16): a transport built at the
        # admiral's current dock takes production-time proportional to THAT
        # system's output — and after a colonization the admiral is docked
        # at the fresh colony (near-zero production), the worst possible
        # build site. Cycle telemetry showed the ship WAIT at 220 UT vs 125
        # UT of voyage. Admirals docked somewhere producing < half of the
        # empire's best system sail to the hub first and order there.
        hub =
          view.systems
          |> Enum.max_by(fn {_id, s} -> s.production.value end, fn -> nil end)

        {stay, rehome} =
          view
          |> transportless_admirals()
          |> Enum.split_with(fn admiral ->
            case {hub, view.systems[admiral.system]} do
              {nil, _} -> true
              {_, nil} -> true
              {{hub_id, hub_sys}, here} ->
                hub_id == admiral.system or here.production.value >= hub_sys.production.value * 0.5
            end
          end)

        travels =
          case hub do
            nil ->
              []

            {hub_id, _} ->
              Enum.flat_map(rehome, fn admiral ->
                case Nav.path_hops(view.galaxy, admiral.system, hub_id) do
                  nil -> []
                  hops -> [{:queue_travel, admiral.id, hops}]
                end
              end)
          end

        # PARALLEL colonization (user directive 2026-07-09): build a
        # transport for EVERY idle colonizer admiral this decision, up to
        # the open slots not yet committed AND what the expansion pool
        # affords (credit AND tech per ship).
        pool_room =
          min(
            trunc(Budget.balance(mem, :expansion, :credit) / @transport_credit),
            trunc(Budget.balance(mem, :expansion, :technology) / @transport_tech)
          )

        room = min(open_slots - committed, pool_room)
        # The guarantee funds exactly ONE ship past the pool's means.
        room = if guarantee?, do: max(room, 1), else: room

        orders =
          stay
          |> Enum.take(max(room, 0))
          |> Enum.flat_map(fn admiral ->
            with sys when sys != nil <- view.systems[admiral.system],
                 tile when tile != nil <- free_army_tile(admiral) do
              [{:order_ship, admiral.system, admiral.id, tile.id, :transport_1}]
            else
              _ -> []
            end
          end)

        case {orders, travels} do
          {[], []} ->
            {[], block(mem, :transport_no_admiral)}

          _ ->
            mem =
              Enum.reduce(orders, mem, fn {:order_ship, _sys, admiral_id, _tile, _key}, m ->
                m
                |> Budget.spend(:expansion, :credit, @transport_credit)
                |> Budget.spend(:expansion, :technology, @transport_tech)
                |> open_colony_task(admiral_id, view.now_ut)
              end)

            # Telemetry: count each order the guarantee funded PAST the
            # pool's means — the flag's direct effect size.
            mem =
              if guarantee? and orders != [] and pool_room < 1,
                do: block(mem, :transport_first_guarantee),
                else: mem

            # Rehoming volume is telemetry, not failure — but count it so
            # "how often do colonizers commute" is a query.
            mem =
              Enum.reduce(travels, mem, fn _t, m -> block(m, :transport_rehoming) end)

            {orders ++ travels, mem}
        end
    end
  end

  # Every idle on-board admiral without a transport (or one inbound) and
  # without a combat army — the colonizer fleet.
  defp transportless_admirals(view) do
    view
    |> on_board_admirals()
    |> Enum.reject(&(has_transport?(&1) or transport_pending?(&1)))
    |> Enum.filter(fn a -> a.action_status in [:idle, :docking] and army_committed(a) <= 1 end)
  end

  defp colonizer_admiral(view) do
    view |> on_board_admirals() |> Enum.min_by(& &1.id, fn -> nil end)
  end

  # FLEET COMMISSION (game-ai-v2.md §1): when a warfleet admiral needs a
  # fleet, enqueue the WHOLE blueprint in one decision — as many ships as
  # current resources allow (the engine deducts credit/tech per order; the
  # production queue has no idle requirement). Building a fleet is one
  # strategic intention, not 18 sequential decisions; unaffordable
  # remainder tops up in later waves under the same (gene-stable)
  # blueprint choice. The genome decides fleet DOCTRINE (which blueprint,
  # how big, how varied); the arena-bred blueprint decides ships.
  defp fleet_commission(view, mem) do
    g = active_genome(mem)
    player = view.player
    size = min(trunc(Map.get(g, "army_size", 4.0) * Map.get(g, "fleet_investment", 1.0)), 18)

    eligible =
      Enum.filter(@blueprints, fn bp -> Enum.all?(bp.patents, &(&1 in player.patents)) end)

    with false <- eligible == [],
         admiral when admiral != nil <-
           view
           |> warfleet_admirals()
           |> Enum.find(fn a ->
             a.action_status in [:idle, :docking] and army_committed(a) < size and
               Enum.any?(a.army.tiles, &(&1.ship_status == :empty))
           end),
         system when system != nil <- view.systems[admiral.system],
         blueprint <- pick_blueprint(eligible, g, admiral) do
      committed = army_committed(admiral)

      empty_tiles =
        admiral.army.tiles
        |> Enum.filter(&(&1.ship_status == :empty))
        |> Enum.take(size - committed)

      # V3: warships draw from the MILITARY pool (credit and tech), so a
      # fleet build-out can't eat the expansion pool's ship savings or the
      # economy pool's development budget.
      {orders, mem} =
        empty_tiles
        |> Enum.with_index(committed)
        |> Enum.reduce({[], mem}, fn {tile, i}, {acc, m} ->
          ship_key = Enum.at(blueprint.ships, rem(i, length(blueprint.ships)))
          {credit_cost, tech_cost, shipyard} = Map.get(@ship_costs, ship_key, {0, 0, :shipyard_1_orbital})

          if Budget.afford?(m, :military, :credit, credit_cost) and
               Budget.afford?(m, :military, :technology, tech_cost) and
               shipyard_built?(system, shipyard) do
            m =
              m
              |> Budget.spend(:military, :credit, credit_cost)
              |> Budget.spend(:military, :technology, tech_cost)

            {[{:order_ship, admiral.system, admiral.id, tile.id, ship_key} | acc], m}
          else
            {acc, m}
          end
        end)

      {Enum.reverse(orders), mem}
    else
      _ -> {[], mem}
    end
  end

  # Tiles already spoken for: planned (ordered, producing) or filled.
  defp army_committed(admiral), do: Enum.count(admiral.army.tiles, &(&1.ship_status != :empty))

  # Surviving-unit fraction across the army — computable without ship data
  # (each ship's units list keeps dead entries at hull ~0). 1.0 = pristine.
  defp army_health(admiral) do
    {alive, total} =
      admiral.army.tiles
      |> Enum.filter(&(&1.ship_status == :filled and is_map(&1.ship)))
      |> Enum.flat_map(& &1.ship.units)
      |> Enum.reduce({0, 0}, fn u, {a, t} -> {if(u.hull > 0.001, do: a + 1, else: a), t + 1} end)

    if total == 0, do: 1.0, else: alive / total
  end

  defp at_own_system?(view, admiral), do: Map.has_key?(view.systems, admiral.system)

  defp nearest_own_system(view, admiral) do
    systems = view.galaxy.stellar_systems
    here = Enum.find(systems, fn s -> s.id == admiral.system end)
    own = MapSet.new(Map.keys(view.systems))

    systems
    |> Enum.filter(&MapSet.member?(own, &1.id))
    |> Enum.min_by(fn s -> if here, do: dist2(s.position, here.position), else: 0 end, fn -> nil end)
    |> case do
      nil -> nil
      s -> s.id
    end
  end

  # Closest blueprint to the aggression gene; with high blueprint_mix,
  # admirals alternate between the two closest (deterministic by id — no
  # per-decision randomness, so a fleet's blueprint is stable).
  defp pick_blueprint(eligible, g, admiral) do
    target = Map.get(g, "blueprint_aggression", 0.4)

    ranked = Enum.sort_by(eligible, fn bp -> abs(bp.aggression - target) end)

    if Map.get(g, "blueprint_mix", 0.0) >= 0.5 and length(ranked) > 1 and rem(admiral.id, 2) == 1,
      do: Enum.at(ranked, 1),
      else: hd(ranked)
  end

  # Transports need no shipyard (the only unyarded ship class).
  defp shipyard_built?(_system, :none), do: true

  defp shipyard_built?(system, shipyard_key) do
    system.bodies
    |> HomeDev.flatten_bodies()
    |> Enum.any?(fn body ->
      Enum.any?(body.tiles, fn t -> t.building_key == shipyard_key and t.building_status != :empty end)
    end)
  end

  defp warfleet_admirals(view) do
    case view |> on_board_admirals() |> Enum.sort_by(& &1.id) do
      [] -> []
      [_colonizer | rest] -> rest
    end
  end

  defp army_fill(admiral), do: Enum.count(admiral.army.tiles, &(&1.ship != nil))
  defp free_army_tile(admiral), do: Enum.find(admiral.army.tiles, &(&1.ship == nil))

  # The wide-play dominion cycle: at max systems with dominion capacity
  # free, flip the WEAKEST owned system into a dominion (frees a system
  # slot for a better colony — "squeeze, flip, repeat"); or flip a dominion
  # back when system slots are free. Three governors (§4 lessons — refused
  # attempts carry no in-game cost, so the GA can't breed the spam out):
  #   * cost gate — transforms cost 10k ideology + 4k per prior transform
  #     (constant-fast.ex); don't attempt while poor;
  #   * one direction per genome — the HIGHER of the two flip genes wins,
  #     so a genome can never ping-pong flip/unflip the same system;
  #   * dwell time — at most one transform attempt per 25 decisions.
  @transform_base_cost 10_000
  @transform_step_cost 4_000
  @transform_dwell 25

  defp dominion_actions(view, mem) do
    g = active_genome(mem)
    player = view.player
    dominions = Map.get(player, :dominions, []) || []
    cost = @transform_base_cost + @transform_step_cost * Map.get(player, :transformed_system_count, 0)

    flip_w = Map.get(g, "w_flip_dominion", 0.0)
    undo_w = Map.get(g, "w_undo_dominion", 0.0)

    direction =
      cond do
        flip_w < 0.5 and undo_w < 0.5 -> nil
        flip_w >= undo_w -> :flip
        true -> :undo
      end

    ready? =
      direction != nil and player.ideology.value >= cost and
        mem.tick - Map.get(mem, :last_transform, -@transform_dwell) >= @transform_dwell

    action =
      cond do
        not ready? ->
          []

        direction == :flip and length(player.stellar_systems) >= player.max_systems.value and
          length(player.stellar_systems) > 1 and length(dominions) < player.max_dominions.value ->
          {system_id, _} = Enum.min_by(view.systems, fn {_id, s} -> owned_strength(s) end, fn -> {nil, nil} end)
          if system_id != nil and system_id != home_id(player), do: [{:to_dominion, system_id}], else: []

        direction == :undo and dominions != [] and
            length(player.stellar_systems) < player.max_systems.value ->
          [{:to_system, hd(dominions).id}]

        true ->
          []
      end

    mem = if action != [], do: %{mem | last_transform: mem.tick}, else: mem
    {action, mem}
  end

  defp home_id(player), do: player.stellar_systems |> List.first() |> Map.get(:id)

  defp owned_strength(system) do
    system.bodies
    |> HomeDev.flatten_bodies()
    |> Enum.map(fn b ->
      Map.get(b, :industrial_factor, 0) + Map.get(b, :technological_factor, 0) + Map.get(b, :activity_factor, 0)
    end)
    |> Enum.sum()
  end

  # FLEET EMPLOYMENT (game-ai-v2.md §1+§2): spend built, idle fleets on the
  # highest-weighted mission whose evolvable target ranking finds a target.
  # `fleet_readiness` gates spending a half-built commission; targets are
  # ranked by the genome's consideration lists, not hard-coded nearest.
  # Neutral training raids keep proximity ranking — they're XP errands, not
  # strategy. Defense is a reposition (move-only) to the best-scored owned
  # system; the reaction stance does the fighting.
  defp fleet_employment(view, mem) do
    g = active_genome(mem)
    size = min(trunc(Map.get(g, "army_size", 4.0) * Map.get(g, "fleet_investment", 1.0)), 18)
    need = max(1, ceil(size * Map.get(g, "fleet_readiness", 0.6)))
    retreat_below = Map.get(g, "fleet_retreat_hp", 0.35)
    targets = Map.get(g, "targets") || default_targets()

    idle_fleets =
      view
      |> warfleet_admirals()
      |> Enum.filter(fn a ->
        army_fill(a) > 0 and a.action_status == :idle and queue_empty?(a) and not has_transport?(a)
      end)

    # FORCE PRESERVATION first (catalog #21): a mauled fleet goes home to
    # repair before anyone considers spending it. Own-system fleets stay
    # put (they repair where they are).
    wounded =
      Enum.find(idle_fleets, fn a ->
        army_health(a) < retreat_below and not at_own_system?(view, a)
      end)

    with %{} = admiral <- wounded,
         home when home != nil <- nearest_own_system(view, admiral),
         hops when hops != nil and hops != [] <- Nav.path_hops(view.galaxy, admiral.system, home) do
      {[{:queue_travel, admiral.id, hops}], mem}
    else
      _ ->
        ready =
          Enum.find(idle_fleets, fn a ->
            army_fill(a) >= need and army_health(a) >= retreat_below
          end)

        employ_fleet(view, mem, g, targets, ready)
    end
  end

  defp employ_fleet(view, mem, g, targets, ready) do

    options =
      [
        {"w_conquest", "conquest", "conquest", :enemy_or_neutral},
        {"w_raid_enemy", "raid", "raid", :enemy},
        {"w_defend", :move_only, "defend", :own},
        {"w_train_navarch", "raid", :nearest, :neutral}
      ]
      |> Enum.filter(fn {w, _, _, _} -> Map.get(g, w, 0.0) >= 0.5 end)
      |> Enum.sort_by(fn {w, _, _, _} -> -Map.get(g, w, 0.0) end)

    with admiral when admiral != nil <- ready,
         {action, target} <-
           Enum.find_value(options, fn {_, action, point, scope} ->
             # Conquest needs invasion power (troop transports): a fleet of
             # pure warships besieges forever and can never take the system.
             # Physically futile dispatches are legality, not strategy.
             if action == "conquest" and not invasion_capable?(admiral) do
               nil
             else
               case employment_target(view, admiral, point, scope, targets) do
                 nil -> nil
                 target -> {action, target}
               end
             end
           end),
         hops when hops != nil <- Nav.path_hops(view.galaxy, admiral.system, target) do
      case action do
        :move_only -> {[{:queue_travel, admiral.id, hops}], mem}
        type -> {[{:queue_travel_action, admiral.id, hops, type, target}], mem}
      end
    else
      _ -> {[], mem}
    end
  end

  defp invasion_capable?(admiral) do
    case admiral.army do
      %{invasion_coef: %{value: v}} -> v > 0
      _ -> false
    end
  end

  defp employment_target(view, admiral, point, scope, targets) do
    my_faction = view.player.faction

    # Siege triage (catalog #25): while any owned system is besieged,
    # defense means THAT system — relieving an active siege isn't a
    # preference to learn, it's what defense is.
    besieged =
      view.systems
      |> Enum.filter(fn {_id, s} -> s.siege != nil end)
      |> Enum.map(fn {id, _} -> id end)
      |> MapSet.new()

    candidates =
      view.galaxy.stellar_systems
      |> Enum.filter(fn s -> s.id != admiral.system end)
      |> Enum.filter(fn s ->
        case scope do
          :enemy -> s.faction != nil and s.faction != my_faction
          :neutral -> s.status == :inhabited_neutral
          :enemy_or_neutral -> (s.faction != nil and s.faction != my_faction) or s.status == :inhabited_neutral
          :own -> s.faction == my_faction
        end
      end)

    candidates =
      if scope == :own and MapSet.size(besieged) > 0 do
        case Enum.filter(candidates, &MapSet.member?(besieged, &1.id)) do
          [] -> candidates
          under_attack -> under_attack
        end
      else
        candidates
      end

    case point do
      :nearest ->
        here = Enum.find(view.galaxy.stellar_systems, fn s -> s.id == admiral.system end)

        candidates
        |> Enum.min_by(fn s -> if here, do: dist2(s.position, here.position), else: 0 end, fn -> nil end)
        |> case do
          nil -> nil
          s -> s.id
        end

      point ->
        Considerations.rank(view, admiral.system, candidates, Map.get(targets, point, [["proximity", 1.0]]))
    end
  end

  # Set each on-board admiral's combat reaction once (gene bucketed into the
  # engine's stances).
  defp reaction_actions(view, mem) do
    stance =
      case trunc(Map.get(active_genome(mem), "reaction_stance", 1.5)) do
        0 -> :passive
        1 -> :defend
        2 -> :attack_enemies
        _ -> :attack_everyone
      end

    case view
         |> on_board_admirals()
         |> Enum.find(&(not MapSet.member?(mem.reactions_set, &1.id))) do
      nil ->
        {[], mem}

      admiral ->
        {[{:update_reaction, admiral.id, stance}], %{mem | reactions_set: MapSet.put(mem.reactions_set, admiral.id)}}
    end
  end

  # Weighted building choice: among ALL legally-buildable candidates in each
  # idle system, take the highest genome weight (≥0.5).
  # Build score = static genome weight + trust-scaled bottleneck bonus
  # (Headless.Econ). The bonus is PER SYSTEM — a housing-bound colony and
  # a labor-surplus core world want different buildings on the same
  # decision — and additive, so the module can promote a building the
  # genome never valued past the 0.5 want-threshold (and demote one that
  # can't pay off right now, e.g. an unstaffable refinery).
  # Idle capital far above the floor is waste (traced champions sat on
  # 1M+ credits with empty tiles). In SURPLUS, drop the want-threshold so
  # any legal tile gets filled — ranked by this static development value so
  # the fill is useful (tech/infra first, then production/housing), not
  # random or defense spam. The value is small enough not to override the
  # genome's own preferences outside surplus.
  @surplus_margin 20_000
  @dev_value %{
    infra_open: 2.0,
    infra_dome: 2.0,
    university_open: 1.5,
    research_orbital: 1.5,
    research_open: 1.4,
    factory_orbital: 1.3,
    mine_dome: 1.3,
    high_factory_dome: 1.2,
    market_open: 1.1,
    lift_open: 1.1,
    hab_open_poor: 1.0,
    hab_open_rich: 1.0,
    hab_dome: 1.0,
    ideo_open: 0.8,
    ideo_credit_open: 0.8,
    monument_dome: 0.6,
    finance_open: 1.1
  }

  # Direct sys_happiness deltas per building (fast-mode data 2026-07-12;
  # body_pop/body_act-scaled ones approximated at typical values). Happiness
  # is the POPULATION-GROWTH GATE: growth goes negative below 0 happiness,
  # and base is only 12 in Fast — so the ungated poor hab (-5 each) that
  # bots spam is a death spiral: pop flatlines at ~25, university tech
  # (0.6/pop) stays tiny, the tech patents stay unreachable, and the whole
  # golden-line gap follows. Checkpoint proof: median pop 23->27 over a
  # full game vs the human's 100->390.
  @happy_delta %{
    infra_open: 12.0,
    infra_dome: 12.0,
    monument_dome: 20.0,
    defense_global_dome: 10.0,
    happy_pot_open: 25.0,
    happy_pot_dome: 12.0,
    happy_pot_orbital: 8.0,
    ideo_credit_open: 4.0,
    hab_open_poor: -5.0,
    mine_dome: -5.0,
    finance_open: -32.0
  }

  # Keep a safety margin above the happiness death line (0): below this,
  # negative-delta buildings are barred and positive ones get a rescue
  # boost, so systems settle in sustained-growth territory instead of
  # building themselves into misery.
  @happy_floor 15.0

  # THE GROWTH CURVE (player knowledge, user 2026-07-12): pop growth =
  # (base + stability×0.002, stability useful to 25) × (habitation+0.75−pop)
  # ×0.1 × a factor decaying to 0.2 at pop 120. Players therefore hold
  # stability ABOVE 24 and housing headroom ABOVE 10 while pop < ~70, then
  # stop pushing (diminishing returns). The genes w_growth /
  # growth_pop_target control aggression and the stop point.
  @growth_happy_target 24.0
  @hab_headroom 10.0

  # DT-3b refinement (2026-07-17): the growth formula is MULTIPLICATIVE —
  # (habitation + 0.75 − pop) × stability factor — and housing binds FIRST
  # on a young system: at cp25 bots sat at hab = pop = 36 (zero headroom,
  # zero growth) because the 24-stability bar blocked the only early
  # housing (poor hab, −5). Below @early_pop the bar drops to
  # @early_happy_floor: housing first at modest stability, then the 24
  # line once the base is built — the sequencing a human opening plays.
  # The floor is 6, NOT lower: a floor of 2 let poor habs flood (26/eval)
  # and crowding/mine drift pushed stability NEGATIVE by cp50 (measured
  # -1, pop 39 < baseline). At 6, a poor hab needs stability 11+, which
  # forces the alternation — infra (+12) first from the post-opener 7,
  # then habs down to ~9, then the next stability producer.
  @early_pop 45.0
  @early_happy_floor 6.0

  # Direct sys_habitation gains per building (fast-mode data) — the housing
  # counterpart of @happy_delta, for the headroom boost.
  @hab_gain %{
    infra_open: 8.0,
    infra_dome: 8.0,
    hab_open_poor: 9.0,
    hab_dome: 6.0,
    hab_open_rich: 5.0
  }

  # SMART SITING (2026-07-17): which body rating each rating-scaled
  # building should chase — the multiplier the game data pays per unit
  # (research_open 22×tec, ideo_credit 7×act, university/ideo 0.6×pop…).
  # Buildings not listed keep first-fit siting.
  @siting %{
    research_orbital: :technological_factor,
    research_open: :technological_factor,
    high_factory_dome: :technological_factor,
    university_open: :population,
    ideo_open: :population,
    happy_pot_open: :activity_factor,
    happy_pot_dome: :activity_factor,
    happy_pot_orbital: :activity_factor,
    ideo_credit_open: :activity_factor,
    hab_open_rich: :activity_factor,
    lift_open: :industrial_factor,
    factory_orbital: :industrial_factor,
    mine_dome: :industrial_factor
  }

  # R3-B DEVELOPMENT LADDER (flag dev_ladder, human doctrine 3b): humans
  # think in system SPECIALIZATIONS and build in a fixed order — (1) just
  # enough housing/stability that pop grows (the existing growth kit),
  # (2) a production floor in EVERY system regardless of role ("100-200
  # prod minimum": build speed compounds everything), (3) blend in the
  # specialization the system's body ratings suggest, (4) cap houses at
  # ~4 per body so high-modifier planets keep room for what they're good
  # at. The floor sits BELOW all growth-kit floors (11.1-11.25) and above
  # the tech bootstrap (11.0): growth gates first, then production, then
  # everything else.
  @dev_ladder_floor 11.05
  @hab_per_body_cap 4
  @prod_keys ~w(factory_orbital mine_dome lift_open high_factory_dome)a
  @hab_cap_keys ~w(hab_open_poor hab_dome hab_open_rich)a
  @spec_builds %{
    tec: ~w(research_open research_orbital high_factory_dome university_open)a,
    act: ~w(ideo_credit_open happy_pot_open happy_pot_dome happy_pot_orbital market_open finance_open ideo_open)a,
    ind: ~w(factory_orbital mine_dome lift_open high_factory_dome)a
  }

  # A system's specialization: the body-factor axis it is best at, decided
  # once at first sight and cached in policy mem (governor passives and
  # slow body composition make this stable; re-deciding per tick would
  # flap on construction noise).
  defp system_spec(mem, system_id, bodies) do
    specs = Map.get(mem, :system_specs, %{})

    case Map.get(specs, system_id) do
      nil ->
        sums =
          Enum.reduce(bodies, %{tec: 0, act: 0, ind: 0}, fn b, a ->
            %{
              a
              | tec: a.tec + num(Map.get(b, :technological_factor, 0)),
                act: a.act + num(Map.get(b, :activity_factor, 0)),
                ind: a.ind + num(Map.get(b, :industrial_factor, 0))
            }
          end)

        spec = sums |> Enum.max_by(fn {_k, v} -> v end) |> elem(0)
        {spec, Map.put(mem, :system_specs, Map.put(specs, system_id, spec))}

      spec ->
        {spec, mem}
    end
  end

  # Body ratings can be :hidden (unscouted internals) — rank those 0.
  defp num(v) when is_number(v), do: v
  defp num(_), do: 0

  # Bodies with capacity for another house (built or building) under the
  # per-body cap.
  defp under_hab_cap(bodies) do
    Enum.filter(bodies, fn body ->
      habs =
        Enum.count(body.tiles, fn t ->
          t.building_key in @hab_cap_keys or Map.get(t, :construction_key) in @hab_cap_keys
        end)

      habs < @hab_per_body_cap
    end)
  end

  defp build_actions(view, mem) do
    g = active_genome(mem)
    player = view.player
    trust = Econ.trust(g)
    empire = if trust > 0.0, do: Econ.empire_signals(view, g, @catalog)
    ladder? = Flags.on?(mem, "dev_ladder")
    pfloor = Map.get(g, "prod_floor", 150.0)
    # V3: buildings draw from the ECONOMY pool; surplus-fill mode keys on
    # the pool's balance rather than the raw stock.
    surplus? = Budget.balance(mem, :economy, :credit) > @surplus_margin
    threshold = if surplus?, do: 0.01, else: 0.5
    wg = Map.get(g, "w_growth", 6.0)
    pop_target = Map.get(g, "growth_pop_target", 70.0)

    {orders, mem} =
      view.systems
      |> Enum.filter(fn {_id, system} -> HomeDev.queue_idle?(system) end)
      |> Enum.reduce({[], mem}, fn {system_id, system}, {acc, m} ->
        bodies = HomeDev.flatten_bodies(system.bodies)
        {spec, m} = if ladder?, do: system_spec(m, system_id, bodies), else: {nil, m}
        prod_low? = ladder? and system.production.value < pfloor
        signals = if trust > 0.0, do: Econ.system_signals(system)
        happy = system.happiness.value
        pop = system.population.value
        # Growth mode per system: below the genome's pop target, hold the
        # stability line at 24 (growth-max) instead of the bare floor, and
        # chase housing headroom; past the target, only the safety floor.
        growth? = wg >= 0.5 and pop < pop_target

        hfloor =
          cond do
            growth? and pop < @early_pop -> @early_happy_floor
            growth? -> @growth_happy_target
            true -> @happy_floor
          end

        headroom_low? = growth? and system.habitation.value - pop < @hab_headroom

        score = fn key ->
          base = Map.get(g, "w_build_#{key}", 0.0)
          econ = if trust > 0.0, do: trust * Econ.bonus(signals, key, empire), else: 0.0
          fill = if surplus?, do: Map.get(@dev_value, key, 0.0), else: 0.0
          # Gene-scaled growth boosts (at the default w_growth 6.0 the
          # happiness rescue equals the old fixed 0.6×delta): stability
          # producers while below the line, housing while headroom is thin.
          happy_boost =
            if happy < hfloor, do: max(Map.get(@happy_delta, key, 0.0), 0.0) * 0.1 * wg, else: 0.0

          hab_boost =
            if headroom_low?, do: Map.get(@hab_gain, key, 0.0) * 0.12 * wg, else: 0.0

          # DT-3 GROWTH KIT (2026-07-16): on a system pinned below the
          # stability line or out of housing headroom, the kit buildings
          # get a CODE FLOOR above the tech bootstrap's 11.0 — per-system
          # population was the last unmoved gold deficit precisely because
          # gene-scaled boosts lost the one-build-at-a-time queue to forced
          # tech builds. Patent/affordability filters still apply, so an
          # unaffordable kit piece never blocks the queue.
          kit =
            cond do
              # Early window: HOUSING outranks everything (headroom is the
              # binding growth factor); poor habs qualify here — the low
              # early bar admits them.
              growth? and pop < @early_pop and headroom_low? and
                  key in [:hab_open_poor, :hab_dome, :hab_open_rich, :infra_open, :infra_dome] ->
                11.25

              growth? and happy < hfloor and key in [:infra_open, :infra_dome, :happy_pot_dome] ->
                11.2

              growth? and headroom_low? and key in [:hab_dome, :hab_open_rich, :infra_open, :infra_dome] ->
                11.1

              true ->
                0.0
            end

          # R3-B: production floor while the system is under prod_floor
          # (growth-kit floors above still win), specialization blend
          # (a boost, not a floor — "we aren't trading away everything")
          # once it isn't.
          dev_floor = if prod_low? and key in @prod_keys, do: @dev_ladder_floor, else: 0.0

          spec_boost =
            if ladder? and not prod_low? and key in Map.get(@spec_builds, spec, []),
              do: 2.0,
              else: 0.0

          boosted = base + econ + fill + happy_boost + hab_boost + spec_boost
          boosted |> max(kit) |> max(dev_floor) |> max(0.0)
        end

        @catalog
        |> Enum.filter(fn {key, _, patent, _, _, cost} ->
          score.(key) >= threshold and
            (patent == nil or patent in player.patents) and
            Budget.afford?(m, :economy, :credit, cost) and
            # Delta-aware stability bar, NEGATIVE-delta buildings only: a
            # building may spend happiness only down to the line (poor hab at
            # −5 needs 29 in growth mode, 20 after; finance at −32 effectively
            # waits for a mature system). Positive/neutral buildings are never
            # barred — they ARE the rescue when the system is below the line.
            (Map.get(@happy_delta, key, 0.0) >= 0 or
               happy + Map.get(@happy_delta, key, 0.0) >= hfloor)
        end)
        |> Enum.flat_map(fn {key, biome, _, limit, tile_kind, _} = entry ->
          # R3-B hab cap: houses only site on bodies still under the
          # per-body cap — high-modifier planets keep their tiles for
          # what they're good at (human doctrine 3b).
          site_bodies =
            if ladder? and key in @hab_cap_keys, do: under_hab_cap(bodies), else: bodies

          case find_slot(site_bodies, biome, key, limit, tile_kind, Map.get(@siting, key)) do
            {nil, _} -> []
            {body, tile} -> [{entry, body, tile}]
          end
        end)
        |> Enum.max_by(fn {{key, _, _, _, _, _}, _, _} -> score.(key) end, fn -> nil end)
        |> case do
          nil ->
            {acc, m}

          {{key, _, _, _, _, cost}, body, tile} ->
            {[{:order_building, system_id, body.uid, tile.id, key} | acc],
             Budget.spend(m, :economy, :credit, cost)}
        end
      end)

    {orders, mem}
  end

  # --- mission (same legality plumbing as Colonizer) -------------------------------

  # Dispatch EVERY idle admiral holding a built transport, each to a
  # distinct target, while system slots remain (the reserved set grows per
  # dispatch so two colonizers never race the same system; targets already
  # being traveled to by busy admirals are pre-reserved from their queue
  # end-positions). NOTE: this is already fully batched — with a single
  # hired Navarch it still degenerates to one dispatch per ship cycle,
  # which is why hire_action's colonizer-first arm exists.
  defp mission_actions(view, mem) do
    g = active_genome(mem)
    player = view.player

    ready_admirals =
      view
      |> on_board_admirals()
      |> Enum.filter(fn a -> has_transport?(a) and a.action_status == :idle and queue_empty?(a) end)

    # Block telemetry (user directive 2026-07-06: colonization MUST happen,
    # so every non-dispatch names its gate — readable in policy_mem.blocks
    # and rolled into results.jsonl).
    cond do
      ready_admirals == [] ->
        {[], block(mem, :colonize_no_ready_transport)}

      length(player.stellar_systems) >= player.max_systems.value ->
        {[], block(mem, :colonize_syscap)}

      true ->
        mem = ensure_target_scores(view, mem)

        # Targets already inbound for busy admirals — the base reservation.
        reserved0 =
          view
          |> on_board_admirals()
          |> Enum.map(fn a -> a.actions && Map.get(a.actions, :virtual_position) end)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        # PARALLEL colonization: dispatch EVERY ready transport this
        # decision, each to a DISTINCT target (the reserved set grows as we
        # go so two colonizers never race the same system).
        {orders, mem, _reserved} =
          Enum.reduce(ready_admirals, {[], mem, reserved0}, fn admiral, {orders, mem, reserved} ->
            case pick_target(view, mem, g, admiral, reserved) do
              nil ->
                {orders, block(mem, :colonize_no_target), reserved}

              target ->
                case Nav.path_hops(view.galaxy, admiral.system, target) do
                  nil ->
                    {orders, block(%{mem | target_scores: Map.delete(mem.target_scores, target)}, :colonize_no_path),
                     reserved}

                  hops ->
                    mem =
                      %{mem | dispatched: target}
                      |> stamp_colony_dispatch(admiral.id, view.now_ut)

                    {[{:queue_mission, admiral.id, hops, target} | orders], mem, MapSet.put(reserved, target)}
                end
            end
          end)

        {orders, mem}
    end
  end

  defp block(mem, key), do: %{mem | blocks: Map.update(mem.blocks, key, 1, &(&1 + 1))}

  # --- covert missions --------------------------------------------------------

  # Send idle covert agents at enemy systems: spies infiltrate (informers →
  # the visibility/shadows victory track), speakers encourage hate
  # (destabilization — slows the opponent). Same travel-then-act plumbing as
  # colonization; targets other agents are traveling to are reserved via
  # queue end-positions. One dispatch per decision.
  # Covert dispatch options, by descending genome weight:
  #   spies    — infiltrate enemies (visibility/shadows VP) or NEUTRALS
  #              (safe XP training);
  #   speakers — destabilize enemies (encourage_hate), train on neutrals,
  #              or capture neutrals as dominions by propaganda
  #              (make_dominion).
  # Agents at/below this level prefer risk-free EXPLORATION (safe XP + map
  # reveal); higher-level agents are dedicated to real tasks.
  @low_level 2

  # UNIFIED AGENT-EMPLOYMENT NODE (user doctrine 2026-07-09). Replaces the
  # old one-covert-agent-per-decision dispatch — instrumentation showed
  # Siderians spent 70% idle in the deck, 30% benched as governors, and 80%
  # wandering to NEUTRAL systems, almost never destabilizing enemies. Every
  # idle spy and speaker now gets its single best action THIS decision,
  # chosen by ROLE:
  #   speaker — flip a NEUTRAL to a dominion (make_dominion; how sectors go
  #             to faction control) > destabilize an enemy world
  #             (encourage_hate) > seduce a caught enemy agent (conversion);
  #   spy     — remove a caught enemy agent (assassination) > infiltrate an
  #             enemy (visibility VP).
  # Level-aware: the lowest-level idle agent is earmarked for EXPLORATION,
  # guaranteeing at least one explorer while high-level agents take real
  # tasks. Defensive posture: a spy sitting in an owned system holds it as a
  # guard while an enemy fleet is on the board (guard duty is not idleness).
  defp employ_agents(view, mem) do
    g = active_genome(mem)
    stack? = Map.get(g, "covert_focus", 0.0) >= 0.5
    targets = Map.get(g, "targets") || default_targets()
    flags = Map.get(mem, :flags) || %{}

    idle =
      [:spy, :speaker]
      |> Enum.flat_map(&on_board_of_type(view, &1))
      |> Enum.filter(&(&1.action_status == :idle and queue_empty?(&1)))
      |> Enum.sort_by(&(-&1.level))

    explorer_id =
      if any_exploring?(view) or idle == [], do: nil, else: idle |> List.last() |> Map.get(:id)

    enemy_fleet? = Enum.any?(view.radar_blips, &(&1.faction != view.player.faction))

    reserved0 =
      view.characters
      |> Map.values()
      |> Enum.map(fn c -> c.actions && Map.get(c.actions, :virtual_position) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {actions, _reserved} =
      Enum.reduce(idle, {[], reserved0}, fn agent, {acts, reserved} ->
        case employ_one(view, g, agent, reserved, targets, stack?, agent.id == explorer_id, enemy_fleet?, flags) do
          nil -> {acts, reserved}
          {action, target} -> {[action | acts], MapSet.put(reserved, target)}
        end
      end)

    {actions, mem}
  end

  defp employ_one(view, g, agent, reserved, targets, stack?, explorer?, enemy_fleet?, flags) do
    cond do
      # Guard duty: a high-level spy already in an owned system holds it
      # while an enemy fleet is detected — don't peel it off to a mission.
      agent.type == :spy and enemy_fleet? and agent.level > @low_level and owns_system?(view, agent.system) ->
        nil

      # The earmarked explorer scouts; but once the map is fully revealed it
      # falls through to a real task rather than idling a slot.
      explorer? ->
        explore_action(view, agent, reserved) || covert_task(view, g, agent, reserved, targets, stack?, flags)

      true ->
        case covert_task(view, g, agent, reserved, targets, stack?, flags) do
          nil -> if agent.level <= @low_level, do: explore_action(view, agent, reserved), else: nil
          found -> found
        end
    end
  end

  # {action, reserved_target} for the agent's highest-weight viable role, or
  # nil. Counter-agent play (assassinate/convert) uses the :hunt scope —
  # foreign agents caught in our systems; the rest score enemy/neutral
  # systems via the genome's consideration lists.
  defp covert_task(view, g, agent, reserved, targets, stack?, _flags) do
    # Tall-dominion gate (hard-coded 2026-07-19 after winning its 24h A/B:
    # win 48.7% vs 44.6%; human doctrine 2d): dominion taxes are low —
    # take only what the slots hold. A make_dominion trip with no free
    # slot is a wasted voyage.
    #
    # (A train-on-neutrals doctrine — human 3c — was A/B-tested here
    # 2026-07-18/19 and LOST: fit -24, win -3.1. Pulling spies off enemy
    # infiltration delays visibility VP more than agent levels pay back
    # inside a 2400-UT Fast game; revisit with level-vs-time telemetry.)
    dominion_room? =
      length(Map.get(view.player, :dominions, []) || []) < view.player.max_dominions.value

    roles =
      case agent.type do
        :speaker ->
          if(dominion_room?,
            do: [{"w_mission_make_dominion", "make_dominion", :neutral, :nearest}],
            else: []
          ) ++
            [
              {"w_mission_destabilize", "encourage_hate", :enemy, "destabilize"},
              {"w_mission_convert", "conversion", :hunt, nil}
            ]

        :spy ->
          [
            {"w_mission_assassinate", "assassination", :hunt, nil},
            {"w_mission_infiltrate", "infiltrate", :enemy, "infiltrate"}
          ]
      end
      |> Enum.filter(fn {w, _, _, _} -> Map.get(g, w, 0.0) >= 0.5 end)
      |> Enum.sort_by(fn {w, _, _, _} -> -Map.get(g, w, 0.0) end)

    Enum.find_value(roles, fn {_w, action, scope, point} ->
      case scope do
        :hunt ->
          prey = hunt_candidates(view)

          with false <- prey == [],
               {target_char, sys_id} <- pick_hunt_target(view, agent, prey),
               false <- MapSet.member?(reserved, sys_id),
               hops when hops != nil <- Nav.path_hops(view.galaxy, agent.system, sys_id) do
            {{:queue_travel_character_action, agent.id, hops, action, sys_id, target_char}, sys_id}
          else
            _ -> nil
          end

        _ ->
          allow_stack = stack? and action == "encourage_hate"

          with target when target != nil <- pick_covert_target(view, agent, scope, point, targets, allow_stack),
               false <- MapSet.member?(reserved, target),
               hops when hops != nil <- Nav.path_hops(view.galaxy, agent.system, target) do
            {{:queue_travel_action, agent.id, hops, action, target}, target}
          else
            _ -> nil
          end
      end
    end)
  end

  defp owns_system?(view, sys_id), do: Enum.any?(view.player.stellar_systems, &(&1.id == sys_id))

  # Any active agent currently traveling to a system we have no intel on —
  # i.e. genuinely exploring the map (not just repositioning to a known one).
  defp any_exploring?(view) do
    intel = view.intel || %{}

    view.characters
    |> Map.values()
    |> Enum.any?(fn c ->
      d = c.actions && Map.get(c.actions, :virtual_position)
      d != nil and not Map.has_key?(intel, d)
    end)
  end

  # Move (no action) to the nearest system we have no intel on and don't own
  # — reveals the map, safe XP. nil when the map is fully scouted.
  defp explore_action(view, agent, reserved) do
    intel = view.intel || %{}
    owned = MapSet.new(view.player.stellar_systems, & &1.id)
    here = Enum.find(view.galaxy.stellar_systems, &(&1.id == agent.system))

    view.galaxy.stellar_systems
    |> Enum.filter(fn s ->
      s.id != agent.system and not Map.has_key?(intel, s.id) and
        not MapSet.member?(owned, s.id) and not MapSet.member?(reserved, s.id)
    end)
    |> Enum.min_by(fn s -> if here, do: dist2(s.position, here.position), else: 0 end, fn -> nil end)
    |> case do
      nil ->
        nil

      s ->
        case Nav.path_hops(view.galaxy, agent.system, s.id) do
          nil -> nil
          hops -> {{:queue_travel, agent.id, hops}, s.id}
        end
    end
  end

  # Foreign covert agents visiting owned systems: `{character_id, system_id}`.
  # Admirals are fleet business; undiscovered spies are unknowable.
  defp hunt_candidates(view) do
    my_faction = view.player.faction

    Enum.flat_map(view.systems, fn {sys_id, system} ->
      system.characters
      |> Enum.filter(fn c ->
        c.owner != nil and c.owner.faction != my_faction and c.type in [:spy, :speaker] and
          (c.type != :spy or Map.get(c, :is_discovered) == true)
      end)
      |> Enum.map(fn c -> {c.id, sys_id} end)
    end)
  end

  defp pick_hunt_target(view, hunter, prey) do
    systems = view.galaxy.stellar_systems
    here = Enum.find(systems, fn s -> s.id == hunter.system end)

    prey
    |> Enum.sort_by(fn {_char, sys_id} ->
      s = Enum.find(systems, fn gs -> gs.id == sys_id end)
      if here && s, do: dist2(s.position, here.position), else: 0
    end)
    |> case do
      [] -> nil
      [{char_id, sys_id} | _] -> {char_id, sys_id}
    end
  end

  # In-scope candidates the agent isn't already at, excluding systems any
  # other agent is traveling to (hard legality filters stay code) UNLESS
  # stacking is genome-enabled for this mission; ranking is the genome's
  # consideration list (enemy points) or nearest (training).
  defp pick_covert_target(view, agent, scope, point, targets, allow_stack \\ false) do
    my_faction = view.player.faction
    systems = view.galaxy.stellar_systems

    reserved =
      if allow_stack do
        MapSet.new()
      else
        view.characters
        |> Map.values()
        |> Enum.reject(&(&1.id == agent.id))
        |> Enum.map(fn c -> c.actions && Map.get(c.actions, :virtual_position) end)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
      end

    in_scope = fn s ->
      case scope do
        :enemy -> s.faction != nil and s.faction != my_faction
        :neutral -> s.status == :inhabited_neutral
      end
    end

    candidates =
      Enum.filter(systems, fn s ->
        s.id != agent.system and in_scope.(s) and not MapSet.member?(reserved, s.id)
      end)

    case point do
      :nearest ->
        here = Enum.find(systems, fn s -> s.id == agent.system end)

        candidates
        |> Enum.min_by(fn s -> if here, do: dist2(s.position, here.position), else: 0 end, fn -> nil end)
        |> case do
          nil -> nil
          s -> s.id
        end

      point ->
        gene_list = Map.get(targets, point, [["proximity", 1.0]])
        extra = if uses?(gene_list, "instability"), do: %{instability: instability_intel(view, candidates)}, else: %{}
        Considerations.rank(view, agent.system, candidates, gene_list, extra)
    end
  end

  defp uses?(gene_list, name), do: Enum.any?(gene_list, fn [c, _w] -> c == name end)

  # Stability intel (engine: happiness), readable only for systems the
  # faction has SCOUTED to visibility >= 3 (user rule 2026-07-05) — an
  # infiltration payoff beyond the VP track. Normalized so 1.0 = on the
  # brink (happiness <= 0) and 0.0 = fully stable or unseen.
  defp instability_intel(view, candidates) do
    intel = view.intel || %{}

    candidates
    |> Enum.filter(fn s ->
      case Map.get(intel, s.id) do
        %{value: v} -> v >= 3
        _ -> false
      end
    end)
    |> Map.new(fn s ->
      case Game.call(view.instance_id, :stellar_system, s.id, :get_state) do
        {:ok, sys} -> {s.id, min(1.0, max(0.0, 1.0 - max(sys.happiness.value, 0) / 150.0))}
        _ -> {s.id, 0.0}
      end
    end)
  end

  defp ensure_target_scores(view, %{target_scores: nil} = mem) do
    scores =
      view.galaxy.stellar_systems
      |> Enum.filter(&(&1.status == :uninhabited))
      |> Enum.filter(&takeable?(view, &1.id))
      |> Map.new(fn s -> {s.id, system_strength(view, s.id)} end)

    %{mem | target_scores: scores}
  end

  defp ensure_target_scores(_view, mem), do: mem

  # Colonization target via the genome's "colonize" consideration list;
  # precomputed system strengths feed the "strength" consideration.
  #
  # R3-A QUALITY SITING (flag quality_siting, human doctrine 2b): quality
  # is superior to distance almost always — a better system multiplies the
  # WHOLE economy (better returns AND faster builds), which offsets the
  # longer voyage. Behind the flag, the ranking is code doctrine
  # (strength-dominant, proximity secondary) instead of the genome's
  # evolved list; if the arm wins, colonize-targeting moves from GA space
  # to code per the V3 boundary.
  @quality_siting_list [["strength", 3.0], ["proximity", 1.0]]

  defp pick_target(view, mem, g, admiral, reserved) do
    candidates =
      view.galaxy.stellar_systems
      |> Enum.filter(fn s ->
        s.status == :uninhabited and Map.has_key?(mem.target_scores, s.id) and not MapSet.member?(reserved, s.id)
      end)

    gene_list =
      if Flags.on?(mem, "quality_siting"),
        do: @quality_siting_list,
        else: (Map.get(g, "targets") || default_targets()) |> Map.get("colonize", [["strength", 1.0], ["proximity", 1.0]])

    Considerations.rank(view, admiral.system, candidates, gene_list, %{strength: mem.target_scores})
  end

  # --- shared low-level helpers (same semantics as Colonizer) -----------------------

  defp takeable?(view, system_id) do
    case Game.call(view.instance_id, :galaxy, :master, {:check_system_takeability, system_id, view.player.faction}) do
      {:ok, :takeable} -> true
      _ -> false
    end
  end

  defp system_strength(view, system_id) do
    case Game.call(view.instance_id, :stellar_system, system_id, :get_state) do
      {:ok, system} ->
        system.bodies
        |> HomeDev.flatten_bodies()
        |> Enum.map(fn body ->
          Map.get(body, :industrial_factor, 0) + Map.get(body, :technological_factor, 0) +
            Map.get(body, :activity_factor, 0)
        end)
        |> Enum.sum()

      _ ->
        0
    end
  end

  defp find_slot(bodies, biome, key, limit, tile_kind, prefer \\ nil) do
    candidates =
      bodies
      |> Enum.filter(fn body -> HomeDev.biome(body.type) == biome end)
      |> Enum.reject(fn body -> limit == :unique_body and Enum.any?(body.tiles, &(&1.building_key == key)) end)

    # SMART SITING (2026-07-17): rating-scaled buildings earn body rating ×
    # multiplier (research_open 22×tec, ideo_credit 7×act, university
    # 0.6×pop) — first-fit siting threw the multiplier away. Best-rated
    # eligible body wins; :hidden ratings rank 0.
    candidates =
      case prefer do
        nil ->
          candidates

        field ->
          Enum.sort_by(candidates, fn body ->
            case Map.get(body, field) do
              v when is_number(v) -> -v
              _ -> 0
            end
          end)
      end

    Enum.find_value(candidates, {nil, nil}, fn body ->
      tile =
        case tile_kind do
          :infrastructure ->
            Enum.find(body.tiles, fn t -> t.type == :infrastructure and free?(t) end)

          :normal ->
            if biome == :orbital or not infra_tile_empty?(body),
              do: Enum.find(body.tiles, fn t -> t.type == :normal and free?(t) end)
        end

      if tile, do: {body, tile}
    end)
  end

  defp infra_tile_empty?(body) do
    match?(%{building_status: :empty}, Enum.find(body.tiles, &(&1.id == 1)))
  end

  defp free?(tile), do: tile.building_status == :empty and tile.construction_status == :none

  defp on_board_admirals(view), do: on_board_of_type(view, :admiral)

  defp on_board_of_type(view, type) do
    view.characters
    |> Map.values()
    |> Enum.filter(fn c -> c.type == type and c.status == :on_board end)
  end

  defp market_character(%{market: nil}, _type), do: nil

  defp market_character(view, type) do
    player = view.player

    view.market.slots
    |> Enum.flat_map(& &1.data)
    |> Enum.flat_map(& &1.data)
    |> Enum.map(& &1.character)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn c ->
      c.type == type and
        Map.get(c, :credit_cost, 0) <= player.credit.value and
        Map.get(c, :technology_cost, 0) <= player.technology.value and
        Map.get(c, :ideology_cost, 0) <= player.ideology.value
    end)
    |> Enum.min_by(&Map.get(&1, :credit_cost, 0), fn -> nil end)
  end

  defp has_transport?(admiral) do
    Enum.any?(admiral.army.tiles, fn tile ->
      tile.ship != nil and tile.ship.key == :transport_1 and Map.get(tile, :ship_status) == :filled
    end)
  end

  defp transport_pending?(admiral) do
    Enum.any?(admiral.army.tiles, fn tile -> tile.ship != nil and tile.ship.key == :transport_1 end)
  end

  defp queue_empty?(admiral), do: match?(%{queue: %{q: {[], []}}}, admiral.actions)

  defp dist2(%{x: x1, y: y1}, %{x: x2, y: y2}), do: (x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)
  defp dist2(_, _), do: 1.0e12
end
