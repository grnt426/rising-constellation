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
  alias Headless.Policies.HomeDev

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
  @doctrines [
    {:agent, 50, nil},
    {:admiral_1, 400, :agent},
    {:system_1, 1200, :agent},
    {:dominion_1, 3000, :system_1},
    {:sys_dom_2, 6000, :dominion_1},
    {:system_4, 8000, :sys_dom_2},
    {:speaker_1, 300, :agent},
    {:tech_2, 900, :speaker_1},
    {:ideo_2, 800, :speaker_1},
    {:credit_1, 700, :speaker_1},
    {:credit_2, 2800, :credit_1},
    {:stab_2, 2000, :ideo_2},
    # Covert branch (the shadows path runs through admiral/defense lexes):
    # defense_1 gates spy/speaker capacity; infiltration boosts infiltrate.
    {:defense_1, 700, :admiral_1},
    {:spy_1, 1500, :defense_1},
    {:speaker_2, 1800, :defense_1},
    {:infiltration, 3000, :spy_1}
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
      {"opener_variant", {0.0, 1.99}},
      {"credit_floor", {1_000.0, 20_000.0}},
      {"hire_reserve", {500.0, 15_000.0}},
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
      {"focus_economy", {0.25, 2.0}}
    ]

    Map.new(weights ++ scalars)
  end

  @families %{
    "expansion" =>
      ~w(w_doc_system_1 w_doc_dominion_1 w_doc_sys_dom_2 w_doc_system_4 w_flip_dominion w_undo_dominion w_mission_make_dominion),
    "military" =>
      ~w(w_patent_shipyard_1 w_patent_fighter_2 w_patent_fighter_3 w_patent_fighter_4 w_patent_merge_fighter_1 w_patent_shipyard_2 w_patent_corvette_1 w_patent_corvette_2 w_patent_corvette_3 w_patent_merge_fighter_corvette w_patent_shipyard_3 w_patent_frigate_2 w_patent_frigate_3 w_patent_frigate_4 w_patent_merge_fighter_3 w_patent_merge_corvette_2 w_patent_shipyard_4 w_patent_capital_1 w_patent_capital_2 w_patent_capital_3 w_patent_merge_frigate_1 w_patent_transport_2 w_patent_dome_academy w_patent_open_defense w_patent_dome_defense_2 w_raid_enemy w_conquest w_defend w_train_navarch w_build_shipyard_1_orbital w_build_shipyard_2_orbital w_build_shipyard_3_orbital w_build_shipyard_4_orbital w_build_defense_global_dome w_build_defense_local_open w_build_defense_local_dome w_build_defense_local_orbital w_build_military_school_dome w_build_radar_orbital w_build_counterintelligence_open),
    "shadows" =>
      ~w(w_doc_defense_1 w_doc_spy_1 w_doc_speaker_2 w_doc_infiltration w_mission_infiltrate w_mission_destabilize w_mission_assassinate w_mission_convert w_train_covert w_build_counterintelligence_open w_build_radar_orbital),
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
      "hire_reserve" => 3_000.0,
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

  @doc "Gaussian mutation on flat genes + one structural op on the target lists."
  def mutate(genome, sigma \\ 0.15) do
    spec()
    |> Map.new(fn {key, {lo, hi}} ->
      base = Map.get(genome, key, (lo + hi) / 2)
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
    %{
      genome: apply_focus(Map.merge(default(), Map.get(ctx, :params, %{}))),
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
    mem = Map.put(mem, :genome_active, apply_reactions(mem.genome, view))
    g = active_genome(mem)
    {mission, mem} = mission_actions(view, mem)
    {covert, mem} = covert_missions(view, mem)
    {military, mem} = fleet_employment(view, mem)
    {reactions, mem} = reaction_actions(view, mem)
    {dominion, mem} = dominion_actions(view, mem)

    {doctrines, mem} =
      if mem.tick - Map.get(mem, :last_doctrine_try, -@doctrine_dwell) >= @doctrine_dwell do
        case doctrine_actions(view, g) do
          [] -> {[], mem}
          actions -> {actions, %{mem | last_doctrine_try: mem.tick}}
        end
      else
        {[], mem}
      end

    actions =
      patent_action(view, g) ++
        doctrines ++
        roster_actions(view, g) ++
        ship_actions(view, g) ++
        fleet_commission(view, g) ++
        dominion ++
        build_actions(view, g) ++
        mission ++
        covert ++
        military ++
        reactions

    {actions, mem}
  end

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
  defp patent_action(view, g) do
    player = view.player
    tech = player.technology.value
    eff = effective_weights(g, @patents, "w_patent_")

    # Strict priority with saving: target the highest-weight unlocked patent
    # and hold technology until it's affordable. (Greedy buy-whatever-is-
    # affordable lets cheap low-weight options drain the budget first —
    # weight order must BE purchase order for genomes to control sequencing.)
    @patents
    |> Enum.reject(fn {key, _, _} -> key in player.patents end)
    |> Enum.filter(fn {key, _cost, ancestor} ->
      Map.get(eff, key, 0.0) >= 0.5 and (ancestor == nil or ancestor in player.patents)
    end)
    |> Enum.max_by(fn {key, _, _} -> Map.get(eff, key, 0.0) end, fn -> nil end)
    |> case do
      {key, cost, _} when tech >= cost -> [{:purchase_patent, key}]
      _ -> []
    end
  end

  # Highest-weighted affordable doctrine by EFFECTIVE weight (V2.1 desire
  # propagation — `system_1` is the ancestor of every dominion lex, so a
  # zero there must not sever the ladder). Activation below still uses RAW
  # weights: stepping stones get bought, not seated in scarce slots.
  defp doctrine_actions(view, g) do
    player = view.player
    ideo = player.ideology.value
    owned = player.doctrines
    active = player.policies
    eff = effective_weights(g, @doctrines, "w_doc_")

    # Strict priority with saving (see patent_action): doctrine costs also
    # INFLATE per owned doctrine, so buying cheap fillers first actively
    # taxes the expansion ladder.
    purchase =
      @doctrines
      |> Enum.reject(fn {key, _, _} -> key in owned end)
      |> Enum.filter(fn {key, _cost, ancestor} ->
        Map.get(eff, key, 0.0) >= 0.5 and (ancestor == nil or ancestor in owned)
      end)
      |> Enum.max_by(fn {key, _, _} -> Map.get(eff, key, 0.0) end, fn -> nil end)
      |> case do
        {key, cost, _} when ideo >= cost -> [{:purchase_doctrine, key}]
        _ -> []
      end

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

    purchase ++ activation
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

  defp roster_actions(view, g) do
    activate_action(view, g) ++ governor_action(view, g) ++ hire_action(view, g)
  end

  defp wants_on_board?(:admiral, _g), do: true
  defp wants_on_board?(:spy, g), do: Map.get(g, "w_mission_infiltrate", 0.0) >= 0.5
  defp wants_on_board?(:speaker, g), do: Map.get(g, "w_mission_destabilize", 0.0) >= 0.5

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

  defp spare_deck_character(view, g) do
    player = view.player

    @agent_types
    |> Enum.flat_map(&deck_of_type(player, &1))
    |> Enum.find(fn %{character: %{type: type}} ->
      # Spare = its type isn't wanted for missions, or missions of that type
      # are already staffed on the map.
      not wants_on_board?(type, g) or length(active_of_type(view, type)) >= 1
    end)
  end

  defp hire_action(view, g) do
    player = view.player

    Enum.find_value(@agent_types, [], fn type ->
      wanted =
        wants_on_board?(type, g) or
          (Map.get(g, "w_governor", 0.0) >= 0.5 and Enum.any?(view.systems, fn {_, s} -> s.governor == nil end))

      below_cap = length(active_of_type(view, type)) + length(deck_of_type(player, type)) < cap(player, type)

      with true <- wanted and below_cap,
           candidate when candidate != nil <- market_character(view, type),
           true <- player.credit.value - Map.get(candidate, :credit_cost, 0) >= Map.get(g, "hire_reserve", 3_000) do
        [{:hire_character, candidate.id}]
      else
        _ -> nil
      end
    end)
  end

  # Order a transport for the COLONIZER admiral (lowest id) when it lacks
  # one, at whatever OWNED system it is docked (colonies become production
  # sites as they develop). Warfleet admirals get warships instead — see
  # warship_actions.
  defp ship_actions(view, g) do
    affordable? =
      view.player.credit.value >= @transport_credit + Map.get(g, "credit_floor", 6_000) and
        view.player.technology.value >= @transport_tech

    with true <- affordable?,
         admiral when admiral != nil <- colonizer_admiral(view),
         false <- transport_pending?(admiral),
         system when system != nil <- view.systems[admiral.system],
         true <- HomeDev.queue_idle?(system),
         tile when tile != nil <- free_army_tile(admiral) do
      [{:order_ship, admiral.system, admiral.id, tile.id, :transport_1}]
    else
      _ -> []
    end
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
  defp fleet_commission(view, g) do
    player = view.player
    floor = Map.get(g, "credit_floor", 6_000)
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

      {orders, _credit, _tech} =
        empty_tiles
        |> Enum.with_index(committed)
        |> Enum.reduce({[], player.credit.value, player.technology.value}, fn {tile, i}, {acc, credit, tech} ->
          ship_key = Enum.at(blueprint.ships, rem(i, length(blueprint.ships)))
          {credit_cost, tech_cost, shipyard} = Map.get(@ship_costs, ship_key, {0, 0, :shipyard_1_orbital})

          if credit - credit_cost >= floor and tech >= tech_cost and shipyard_built?(system, shipyard) do
            {[{:order_ship, admiral.system, admiral.id, tile.id, ship_key} | acc], credit - credit_cost, tech - tech_cost}
          else
            {acc, credit, tech}
          end
        end)

      Enum.reverse(orders)
    else
      _ -> []
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
      |> Enum.filter(fn a -> army_fill(a) > 0 and a.action_status == :idle and queue_empty?(a) end)

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
  defp build_actions(view, g) do
    player = view.player
    floor = Map.get(g, "credit_floor", 6_000)

    view.systems
    |> Enum.filter(fn {_id, system} -> HomeDev.queue_idle?(system) end)
    |> Enum.flat_map(fn {system_id, system} ->
      bodies = HomeDev.flatten_bodies(system.bodies)

      @catalog
      |> Enum.filter(fn {key, _, patent, _, _, cost} ->
        Map.get(g, "w_build_#{key}", 0.0) >= 0.5 and
          (patent == nil or patent in player.patents) and
          player.credit.value >= cost + floor
      end)
      |> Enum.flat_map(fn {key, biome, _, limit, tile_kind, _} = entry ->
        case find_slot(bodies, biome, key, limit, tile_kind) do
          {nil, _} -> []
          {body, tile} -> [{entry, body, tile}]
        end
      end)
      |> Enum.max_by(fn {{key, _, _, _, _, _}, _, _} -> Map.get(g, "w_build_#{key}", 0.0) end, fn -> nil end)
      |> case do
        nil -> []
        {{key, _, _, _, _, _}, body, tile} -> [{:order_building, system_id, body.uid, tile.id, key}]
      end
    end)
  end

  # --- mission (same legality plumbing as Colonizer) -------------------------------

  # Dispatch (at most one per decision) any idle admiral holding a built
  # transport, while system slots remain. Targets already being traveled to
  # by busy admirals (their queue's end position) are reserved.
  defp mission_actions(view, mem) do
    g = active_genome(mem)
    player = view.player

    ready =
      view
      |> on_board_admirals()
      |> Enum.find(fn a -> has_transport?(a) and a.action_status == :idle and queue_empty?(a) end)

    cond do
      ready == nil or length(player.stellar_systems) >= player.max_systems.value ->
        {[], mem}

      true ->
        mem = ensure_target_scores(view, mem)

        reserved =
          view
          |> on_board_admirals()
          |> Enum.reject(&(&1.id == ready.id))
          |> Enum.map(fn a -> a.actions && Map.get(a.actions, :virtual_position) end)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        case pick_target(view, mem, g, ready, reserved) do
          nil ->
            {[], mem}

          target ->
            case Nav.path_hops(view.galaxy, ready.system, target) do
              nil -> {[], %{mem | target_scores: Map.delete(mem.target_scores, target)}}
              hops -> {[{:queue_mission, ready.id, hops, target}], %{mem | dispatched: target}}
            end
        end
    end
  end

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
  defp covert_missions(view, mem) do
    g = active_genome(mem)

    case hunt_missions(view, g) do
      [] -> covert_dispatch(view, mem, g)
      hunt -> {hunt, mem}
    end
  end

  # COUNTER-AGENT play: hunt foreign agents caught in OWN territory — every
  # owned system's state lists its visiting characters (the same source
  # fleet interception uses). Undiscovered Erased stay invisible (cover
  # rules); once blown — e.g. a failed infiltration — they're huntable, and
  # a foreign agent gets no counter-intelligence protection in YOUR system.
  # Erased assassinate (removal); Siderians convert (seduction). One
  # dispatch per decision, like all covert play.
  defp hunt_missions(view, g) do
    options =
      [
        {:spy, "w_mission_assassinate", "assassination"},
        {:speaker, "w_mission_convert", "conversion"}
      ]
      |> Enum.filter(fn {_, w, _} -> Map.get(g, w, 0.0) >= 0.5 end)
      |> Enum.sort_by(fn {_, w, _} -> -Map.get(g, w, 0.0) end)

    prey = hunt_candidates(view)

    Enum.find_value(options, [], fn {type, _w, action} ->
      with false <- prey == [],
           hunter when hunter != nil <-
             view |> on_board_of_type(type) |> Enum.find(&(&1.action_status == :idle and queue_empty?(&1))),
           {target_char, system_id} <- pick_hunt_target(view, hunter, prey),
           hops when hops != nil <- Nav.path_hops(view.galaxy, hunter.system, system_id) do
        [{:queue_travel_character_action, hunter.id, hops, action, system_id, target_char}]
      else
        _ -> nil
      end
    end)
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

  defp covert_dispatch(view, mem, g) do
    targets = Map.get(g, "targets") || default_targets()

    options =
      [
        {:spy, "w_mission_infiltrate", "infiltrate", :enemy, "infiltrate"},
        {:spy, "w_train_covert", "infiltrate", :neutral, :nearest},
        {:speaker, "w_mission_destabilize", "encourage_hate", :enemy, "destabilize"},
        {:speaker, "w_train_covert", "encourage_hate", :neutral, :nearest},
        {:speaker, "w_mission_make_dominion", "make_dominion", :neutral, :nearest}
      ]
      |> Enum.filter(fn {_, w, _, _, _} -> Map.get(g, w, 0.0) >= 0.5 end)
      |> Enum.sort_by(fn {_, w, _, _, _} -> -Map.get(g, w, 0.0) end)

    stack? = Map.get(g, "covert_focus", 0.0) >= 0.5

    dispatch =
      Enum.find_value(options, fn {type, _w, action, scope, point} ->
        allow_stack = stack? and action == "encourage_hate"

        with agent when agent != nil <-
               view |> on_board_of_type(type) |> Enum.find(&(&1.action_status == :idle and queue_empty?(&1))),
             target when target != nil <- pick_covert_target(view, agent, scope, point, targets, allow_stack),
             hops when hops != nil <- Nav.path_hops(view.galaxy, agent.system, target) do
          {:queue_travel_action, agent.id, hops, action, target}
        else
          _ -> nil
        end
      end)

    case dispatch do
      nil -> {[], mem}
      action -> {[action], mem}
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
  defp pick_target(view, mem, g, admiral, reserved) do
    candidates =
      view.galaxy.stellar_systems
      |> Enum.filter(fn s ->
        s.status == :uninhabited and Map.has_key?(mem.target_scores, s.id) and not MapSet.member?(reserved, s.id)
      end)

    gene_list = (Map.get(g, "targets") || default_targets()) |> Map.get("colonize", [["strength", 1.0], ["proximity", 1.0]])

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

  defp find_slot(bodies, biome, key, limit, tile_kind) do
    bodies
    |> Enum.filter(fn body -> HomeDev.biome(body.type) == biome end)
    |> Enum.reject(fn body -> limit == :unique_body and Enum.any?(body.tiles, &(&1.building_key == key)) end)
    |> Enum.find_value({nil, nil}, fn body ->
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
