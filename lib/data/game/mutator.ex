defmodule Data.Game.Mutator do
  @moduledoc """
  Forge mutators — per-scenario gameplay variants that can be enabled
  without forking the engine. Each entry is a pure record: the engine's
  hook points (Player.new, Game.Fight.Manager.do_cleaning, etc.) look
  these up via `Instance.Mutators.active?/2` and apply their effect.

  ## Stage 5 scope

  Only the resource-scaler family is implemented in this milestone —
  they're the doc's MVP because they need zero new hook points. Other
  catalog entries are stubbed (no implementation yet) so the UI can
  list them as "coming soon" without needing the engine work first.

  See docs/forge-redesign.md Stage 5 and docs/mutator-ideas.md for the
  longer roadmap.

  ## Adding a new mutator

  1. Add an entry to `@catalog` with a flavorful `name`, a one-sentence
     `description` players will read in the picker, and `implemented:
     true|false`.
  2. Wire the effect at the named hook (`hook:` field) — for
     resource scalers that's `RC.Instances.Player.Player.new/4` via
     the helpers in `Instance.Mutators`. Add a clause there.
  3. Bump `implemented: true` and the picker UI will let scenarios
     activate it.

  Frontend (Scenario.vue) reads `catalog/0` via GET /api/data/mutators.
  """

  # The catalog. Order in the list = display order in the picker.
  #
  # Beyond the picker fields (key/name/description/hook/implemented), three
  # tags drive the daily-challenge generator (lib/daily/generator.ex):
  #
  #   * polarity       — :positive | :negative, so a daily can roll "2 boons
  #                      + 1 bane" without hand-curating each day.
  #   * daily_eligible — whether the daily rotation may pick this mutator.
  #   * axis           — the lever the mutator pulls (:credit_income,
  #                      :happiness, :intel, ...). The generator never rolls
  #                      a bane sharing an axis with a rolled boon: a day
  #                      that both boosts and nerfs the same number reads as
  #                      having nothing interesting to offer. Same-polarity
  #                      stacking on one axis stays legal — contradiction is
  #                      filtered, not synergy. See
  #                      docs/daily-challenge-ideas.md (Rotation and pairing).
  #
  # Entries with `implemented: false` are catalog-only: the picker greys them
  # out and the daily generator skips them unless explicitly asked for the
  # full roster (`mix daily.preview --all`). They pin down the roadmap and
  # the hook each effect will need. See docs/mutator-ideas.md and
  # docs/daily-challenge.md.
  @catalog [
    # --- resource scalers (implemented; on_player_init) --------------------
    # Benched from the daily rotation (daily_eligible: false): a flat starting
    # multiplier is a dull "free lead" with no in-run decision. Still selectable
    # in the scenario editor. The daily's interesting levers are the ongoing
    # income/production modifiers below and the world-gen twists above.
    %{
      key: :empire_of_wealth,
      name: "Empire of Wealth",
      description: "Every player starts the game with double the credit reserves.",
      hook: :on_player_init,
      implemented: true,
      polarity: :positive,
      daily_eligible: false,
      axis: :starting_credit
    },
    %{
      key: :frontier_stockpile,
      name: "Frontier Stockpile",
      description: "Triple the starting credit — for scenarios that want an aggressive opening rush.",
      hook: :on_player_init,
      implemented: true,
      polarity: :positive,
      daily_eligible: false,
      axis: :starting_credit
    },
    %{
      key: :lean_years,
      name: "Lean Years",
      description: "Players start with only half the usual credit. Survival is the early game.",
      hook: :on_player_init,
      implemented: true,
      polarity: :negative,
      daily_eligible: false,
      axis: :starting_credit
    },
    %{
      key: :old_knowledge,
      name: "Old Knowledge",
      description: "The empires of old left their research behind. Players begin with double the starting technology.",
      hook: :on_player_init,
      implemented: true,
      polarity: :positive,
      daily_eligible: false,
      axis: :starting_technology
    },
    %{
      key: :faith_reborn,
      name: "Faith Reborn",
      description: "Doctrinal certainty runs deep. Players begin with double the starting ideology.",
      hook: :on_player_init,
      implemented: true,
      polarity: :positive,
      daily_eligible: false,
      axis: :starting_ideology
    },

    # --- world-generation twists (roadmap; on_galaxy_spawn) ----------------
    %{
      key: :garden_worlds,
      name: "Garden Worlds",
      description: "Every habitable world is lush and earth-like — no barren rocks to settle.",
      hook: :on_galaxy_spawn,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :habitability
    },
    %{
      key: :barren_crucible,
      name: "Barren Crucible",
      description: "Every habitable world is sterile — wring prosperity from dead stone.",
      hook: :on_galaxy_spawn,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :habitability
    },
    %{
      key: :worlds_of_plenty,
      name: "Worlds of Plenty",
      description: "Every planet spawns with maxed industry, science and appeal (5/5/5).",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :planet_factors
    },
    %{
      key: :hardscrabble_worlds,
      name: "Hardscrabble Worlds",
      description: "Every planet spawns at the lowest factors (1/1/1). Make do with little.",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :planet_factors
    },
    %{
      key: :gilded_orbitals,
      name: "Gilded Orbitals",
      description: "Every non-planet body spawns with maxed factors (5/5/5).",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :orbital_factors
    },
    %{
      key: :sprawling_frontier,
      name: "Sprawling Frontier",
      description: "Every body has two extra building tiles. Room to grow.",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :tiles
    },
    %{
      key: :open_frontier,
      name: "Open Frontier",
      description: "Every body has one extra building tile.",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :tiles
    },

    # --- economy / pacing twists (roadmap; on_player_init / on_tick) -------
    %{
      key: :teeming_masses,
      name: "Teeming Masses",
      description: "Begin with thirty extra population already settled.",
      hook: :on_player_init,
      implemented: false,
      polarity: :positive,
      daily_eligible: false,
      axis: :population
    },
    %{
      key: :hyperlane_mastery,
      name: "Hyperlane Mastery",
      description: "Mobility is twice as effective.",
      hook: :on_tick,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :mobility
    },
    %{
      key: :enlightened_age,
      name: "Enlightened Age",
      description: "Technology income flows 50% faster.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :technology_income,
      bonus: %Core.Bonus{from: :player_technology, to: :player_technology, type: :mul, value: 0.5}
    },
    %{
      key: :zealous_fervor,
      name: "Zealous Fervor",
      description: "Ideology income flows 50% faster.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :ideology_income,
      bonus: %Core.Bonus{from: :player_ideology, to: :player_ideology, type: :mul, value: 0.5}
    },

    # --- income & production modifiers (implemented; bonus pipeline) -------
    # These inject a Core.Bonus into the player/system pipeline at compute time
    # (see Instance.Mutators.bonus_entries/1 + Player.extract_bonus/2), so the
    # effect is ongoing — and the income ones interact directly with the day's
    # objective. :mul value 0.5 = +50%, -0.4 = -40% on the targeted rate.
    %{
      key: :bull_market,
      name: "Bull Market",
      description: "Credit income flows 50% faster.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :credit_income,
      bonus: %Core.Bonus{from: :player_credit, to: :player_credit, type: :mul, value: 0.5}
    },
    %{
      key: :industrial_surge,
      name: "Industrial Surge",
      description: "Reactors run hot — system production is 40% higher.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :production,
      bonus: %Core.Bonus{from: :sys_production, to: :sys_production, type: :mul, value: 0.4}
    },
    %{
      key: :luddite_backlash,
      name: "Luddite Backlash",
      description: "Technology income crawls — 40% slower.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :technology_income,
      bonus: %Core.Bonus{from: :player_technology, to: :player_technology, type: :mul, value: -0.4}
    },
    %{
      key: :crisis_of_faith,
      name: "Crisis of Faith",
      description: "Ideology income falters — 40% slower.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :ideology_income,
      bonus: %Core.Bonus{from: :player_ideology, to: :player_ideology, type: :mul, value: -0.4}
    },
    %{
      key: :heavy_tithes,
      name: "Heavy Tithes",
      description: "The realm bleeds you dry — credit income 40% slower.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :credit_income,
      bonus: %Core.Bonus{from: :player_credit, to: :player_credit, type: :mul, value: -0.4}
    },
    %{
      key: :failing_reactors,
      name: "Failing Reactors",
      description: "Reactors sputter — system production is 35% lower.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :production,
      bonus: %Core.Bonus{from: :sys_production, to: :sys_production, type: :mul, value: -0.35}
    },

    # --- daily expansion boons (implemented; bonus pipeline) ---------------
    # The wired batch from docs/daily-challenge-ideas.md. Multi-lever entries
    # carry `bonuses:` (a list) instead of `bonus:`; `bonuses/1` normalizes.
    %{
      key: :prosperous_masses,
      name: "Prosperous Masses",
      description: "Population pays taxes — every point of workforce adds 2 credit income.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :credit_income,
      bonus: %Core.Bonus{from: :sys_pop, to: :sys_credit, type: :add, value: 2}
    },
    %{
      key: :joyful_industry,
      name: "Joyful Industry",
      description: "Happiness feeds the reactors — every point of happiness adds 1 production.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :production,
      bonus: %Core.Bonus{from: :sys_happiness, to: :sys_production, type: :add, value: 1}
    },
    %{
      key: :festival_days,
      name: "Festival Days",
      description: "The realm celebrates — +10 happiness in every system.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :happiness,
      bonus: %Core.Bonus{from: :direct, to: :sys_happiness, type: :add, value: 10}
    },
    %{
      key: :panopticon,
      name: "Panopticon",
      description: "Nothing moves unseen — counter-intelligence and contact removal are 50% more effective.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :intel,
      bonuses: [
        %Core.Bonus{from: :sys_ci, to: :sys_ci, type: :mul, value: 0.5},
        %Core.Bonus{from: :sys_remove_contact, to: :sys_remove_contact, type: :mul, value: 0.5}
      ]
    },
    %{
      key: :veteran_shipwrights,
      name: "Veteran Shipwrights",
      description: "Ships leave the yards battle-ready — +10 to every ship class level.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :ship_levels,
      bonuses: [
        %Core.Bonus{from: :direct, to: :sys_fighter_lvl, type: :add, value: 10},
        %Core.Bonus{from: :direct, to: :sys_corvette_lvl, type: :add, value: 10},
        %Core.Bonus{from: :direct, to: :sys_frigate_lvl, type: :add, value: 10},
        %Core.Bonus{from: :direct, to: :sys_capital_lvl, type: :add, value: 10}
      ]
    },
    %{
      key: :open_court,
      name: "Open Court",
      description: "The court's doors stand open — +1 to every agent cap.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :agents,
      bonuses: [
        %Core.Bonus{from: :direct, to: :player_admiral, type: :add, value: 1},
        %Core.Bonus{from: :direct, to: :player_spy, type: :add, value: 1},
        %Core.Bonus{from: :direct, to: :player_speaker, type: :add, value: 1}
      ]
    },
    %{
      key: :expansion_charter,
      name: "Expansion Charter",
      description: "A mandate to grow — +1 max systems and +2 max dominions.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :expansion,
      bonuses: [
        %Core.Bonus{from: :direct, to: :player_system, type: :add, value: 1},
        %Core.Bonus{from: :direct, to: :player_dominion, type: :add, value: 2}
      ]
    },
    %{
      key: :field_docks,
      name: "Field Docks",
      description: "Repair crews work miracles — army repair is twice as effective.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :fleet_repair,
      bonus: %Core.Bonus{from: :army_repair, to: :army_repair, type: :mul, value: 1.0}
    },
    %{
      key: :cheap_steel,
      name: "Cheap Steel",
      description: "The yards run a surplus — army maintenance is halved.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :fleet_upkeep,
      bonus: %Core.Bonus{from: :army_maintenance, to: :army_maintenance, type: :mul, value: -0.5}
    },
    %{
      key: :silver_tongues,
      name: "Silver Tongues",
      description: "Siderian actions are twice as effective — conversion, destabilization and vassalization.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :speaker_power,
      bonuses: [
        %Core.Bonus{from: :speaker_conversion, to: :speaker_conversion, type: :mul, value: 1.0},
        %Core.Bonus{from: :speaker_encourage_hate, to: :speaker_encourage_hate, type: :mul, value: 1.0},
        %Core.Bonus{from: :speaker_make_dominion, to: :speaker_make_dominion, type: :mul, value: 1.0}
      ]
    },
    %{
      key: :ghost_protocols,
      name: "Ghost Protocols",
      description: "The Erased move like rumors — infiltration, sabotage and assassination are 50% more effective.",
      hook: :on_bonus,
      implemented: true,
      polarity: :positive,
      daily_eligible: true,
      axis: :spy_power,
      bonuses: [
        %Core.Bonus{from: :spy_infiltrate, to: :spy_infiltrate, type: :mul, value: 0.5},
        %Core.Bonus{from: :spy_sabotage, to: :spy_sabotage, type: :mul, value: 0.5},
        %Core.Bonus{from: :spy_assassination, to: :spy_assassination, type: :mul, value: 0.5}
      ]
    },
    # Prodigies needs the :on_xp hook (the mirror of Inexperienced Court):
    # the bonus pipeline only reaches *passive* XP gain — action XP is added
    # directly via Character.add_experience and never sees pipeline bonuses,
    # so a pipeline-only version would be half a mutator. Wire both XP
    # mutators together at Character.add_experience + the passive change.
    %{
      key: :prodigies,
      name: "Prodigies",
      description: "A generation of talents — agents earn double experience.",
      hook: :on_xp,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :agent_xp
    },

    # --- daily expansion banes (implemented; bonus pipeline) ---------------
    %{
      key: :hungry_mouths,
      name: "Hungry Mouths",
      description: "The crowds must be fed — every point of workforce drains 2 credit income.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :credit_income,
      bonus: %Core.Bonus{from: :sys_pop, to: :sys_credit, type: :add, value: -2}
    },
    %{
      key: :crowded_slums,
      name: "Crowded Slums",
      description: "Housing strains at the seams — habitation is 25% less effective.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :habitation,
      bonus: %Core.Bonus{from: :sys_habitation, to: :sys_habitation, type: :mul, value: -0.25}
    },
    %{
      key: :sullen_populace,
      name: "Sullen Populace",
      description: "The people trust no one — −10 happiness in every system.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :happiness,
      bonus: %Core.Bonus{from: :direct, to: :sys_happiness, type: :add, value: -10}
    },
    %{
      key: :blind_watch,
      name: "Blind Watch",
      description: "The watchers doze — counter-intelligence and contact removal are 50% less effective.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :intel,
      bonuses: [
        %Core.Bonus{from: :sys_ci, to: :sys_ci, type: :mul, value: -0.5},
        %Core.Bonus{from: :sys_remove_contact, to: :sys_remove_contact, type: :mul, value: -0.5}
      ]
    },
    %{
      key: :porous_borders,
      name: "Porous Borders",
      description: "The walls have gaps — system defense is 30% lower.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :defense,
      bonus: %Core.Bonus{from: :sys_defense, to: :sys_defense, type: :mul, value: -0.3}
    },
    %{
      key: :brittle_hulls,
      name: "Brittle Hulls",
      description: "Repairs never quite hold — army repair is half as effective.",
      hook: :on_bonus,
      implemented: true,
      polarity: :negative,
      daily_eligible: true,
      axis: :fleet_repair,
      bonus: %Core.Bonus{from: :army_repair, to: :army_repair, type: :mul, value: -0.5}
    },

    # --- package-day mutators (implemented; pinned by an objective) --------
    # Never rolled at random (daily_eligible: false) — the objective that owns
    # the package pins them via its `package_mutators` (see Daily.Objective /
    # Daily.Generator). Selectable in the Forge for scenarios that want the
    # same twist.
    %{
      key: :the_bequest_estate,
      name: "The Bequest (Estate)",
      description:
        "Start with a fortune of 100,000,000 credits that bleeds 5,000 credits a minute.",
      hook: :on_player_init,
      implemented: true,
      polarity: :negative,
      daily_eligible: false,
      axis: :bequest,
      # The drain, in credit per game-day (ut). At the daily speed (factor
      # 240) one real minute is 60_000ms × 240 / 180_000 = 80 ut, so 5_000
      # credits/min = 62.5/ut. `direct_last` applies it after all income, the
      # same slot character wages and fleet maintenance use.
      bonus: %Core.Bonus{from: :direct_last, to: :player_credit, type: :add, value: -62.5}
    },

    # --- daily expansion roadmap (not yet wired) ---------------------------
    # Selected in docs/daily-challenge-ideas.md; each names the hook it's
    # waiting on. :on_event entries belong to the Director (the daily's
    # deterministic event scheduler — see the doc's "four unlocks").
    %{
      key: :demographic_dividend,
      name: "Demographic Dividend",
      description: "Everything that scales with population scales twice as hard.",
      hook: :on_bonus,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :population
    },
    %{
      key: :radiant_court,
      name: "Radiant Court",
      description: "Every Siderian present in a system grants +10% ideology and technology income there.",
      hook: :on_tick,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :court_presence
    },
    %{
      key: :doctrine_of_the_masses,
      name: "Doctrine of the Masses",
      description: "Siderian passive skills are twice as effective.",
      hook: :on_bonus,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :speaker_power
    },
    %{
      key: :pioneer_charter,
      name: "Pioneer Charter",
      description: "Start with a named patent already researched.",
      hook: :on_player_init,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :starting_patent
    },
    %{
      key: :subsidized_yards,
      name: "Subsidized Yards",
      description: "Ships cost half production.",
      hook: :on_cost,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :ship_cost
    },
    %{
      key: :open_science,
      name: "Open Science",
      description: "Patents cost half technology.",
      hook: :on_cost,
      implemented: false,
      polarity: :positive,
      daily_eligible: true,
      axis: :patent_cost
    },
    %{
      key: :agitators_abroad,
      name: "Agitators Abroad",
      description: "Siderians of rising skill destabilize your system every few minutes.",
      hook: :on_event,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :unrest_events
    },
    %{
      key: :reavers_come,
      name: "The Reavers Come",
      description: "Bombardment fleets arrive at fixed times, hold orbit briefly, then fire.",
      hook: :on_event,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :raid_events
    },
    %{
      key: :crumbling_ground,
      name: "Crumbling Ground",
      description: "Every five minutes a quake damages one to three buildings.",
      hook: :on_event,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :quake_events
    },
    %{
      key: :tides_of_industry,
      name: "Tides of Industry",
      description: "Production oscillates ±25%, flipping every five minutes.",
      hook: :on_tick,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :production_swings
    },

    # --- restrictions / banes (roadmap; assorted hooks) --------------------
    %{
      key: :cramped_quarters,
      name: "Cramped Quarters",
      description: "Housing is 25% less effective.",
      hook: :on_bonus,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :habitation
    },
    %{
      key: :lost_sciences,
      name: "Lost Sciences",
      description: "Patents cost double to research.",
      hook: :on_cost,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :patent_cost
    },
    %{
      key: :restless_senate,
      name: "Restless Senate",
      description: "Lex influence scales 30% faster — the senate moves whether you're ready or not.",
      hook: :on_tick,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :lex
    },
    %{
      key: :inexperienced_court,
      name: "Inexperienced Court",
      description: "Governors earn experience 50% slower.",
      hook: :on_xp,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :agent_xp
    },
    %{
      key: :closed_borders,
      name: "Closed Borders",
      description: "Agents cannot be recruited — work with the court you have.",
      hook: :on_action,
      implemented: false,
      polarity: :negative,
      daily_eligible: true,
      axis: :agents
    }
  ]

  @doc """
  Returns every mutator in display order. Use this in the picker UI
  and the docs page; engine hooks should use `get/1` instead.
  """
  def catalog, do: @catalog

  @doc """
  Returns only mutators that are wired into the engine. The Scenario
  editor uses this to gate which checkboxes are enabled; entries with
  `implemented: false` show up greyed-out for visibility but can't be
  selected.
  """
  def implemented, do: Enum.filter(@catalog, & &1.implemented)

  @doc """
  Mutators the daily rotation may roll (tagged `daily_eligible: true`).
  """
  def daily_eligible, do: Enum.filter(@catalog, &Map.get(&1, :daily_eligible, false))

  @doc """
  Daily-eligible mutators of a given polarity (`:positive` | `:negative`).
  Used by `Daily.Generator` to roll boons and banes separately.
  """
  def daily_by_polarity(polarity) do
    Enum.filter(daily_eligible(), &(Map.get(&1, :polarity) == polarity))
  end

  @doc """
  Look up one mutator definition by key. Accepts atoms or strings (the
  latter is what arrives from game_data jsonb).
  """
  def get(key) when is_atom(key), do: Enum.find(@catalog, &(&1.key == key))

  def get(key) when is_binary(key) do
    Enum.find(@catalog, fn m -> Atom.to_string(m.key) == key end)
  end

  def get(_), do: nil

  @doc """
  The `Core.Bonus` a mutator injects into the player/system bonus pipeline, or
  nil when it has no bonus (world-gen / starting-resource mutators carry their
  effect elsewhere). Single-lever entries only; multi-lever mutators declare
  `bonuses:` — use `bonuses/1`, which normalizes both shapes.
  """
  def bonus(key) do
    case get(key) do
      %{bonus: %Core.Bonus{} = b} -> b
      _ -> nil
    end
  end

  @doc """
  Every `Core.Bonus` a mutator injects, as a list — `[]` when it has none
  (world-gen / starting-resource mutators carry their effect elsewhere).
  Wired in via `Instance.Mutators.bonus_entries/1` →
  `Instance.Player.Player.extract_bonus/2`, the same path faction traditions
  use; each bonus routes to the player, stellar-system or character pipeline
  by its target.
  """
  def bonuses(key) do
    case get(key) do
      %{bonuses: list} when is_list(list) -> list
      %{bonus: %Core.Bonus{} = b} -> [b]
      _ -> []
    end
  end

  @doc """
  Multiplier applied to `player_starting_credit` based on which credit-
  scaling mutator is active. Designed to be looked up once during
  `Player.new/4`. Defaults to 1.0 (vanilla) when none is active.
  """
  def credit_multiplier(mutator_keys) do
    cond do
      :frontier_stockpile in mutator_keys -> 3.0
      :empire_of_wealth in mutator_keys -> 2.0
      :lean_years in mutator_keys -> 0.5
      true -> 1.0
    end
  end

  @doc """
  Absolute starting-credit override, or nil for the normal
  constant × multiplier path. Overrides win over multipliers — a package day
  like The Bequest sets the exact opening fortune.
  """
  def credit_override(mutator_keys) do
    if :the_bequest_estate in mutator_keys, do: 100_000_000, else: nil
  end

  def technology_multiplier(mutator_keys) do
    if :old_knowledge in mutator_keys, do: 2.0, else: 1.0
  end

  def ideology_multiplier(mutator_keys) do
    if :faith_reborn in mutator_keys, do: 2.0, else: 1.0
  end

  # --- world-generation mutators (on_galaxy_spawn) ------------------------
  #
  # These are applied as pure post-processing of the seeded rolls in
  # Instance.StellarSystem.StellarBody.new/5: the RNG draws still happen (so a
  # daily *without* these mutators generates exactly as vanilla — the stream
  # is untouched), only the rolled results are overridden. `body_kind` is
  # :primary (a planet) or :secondary (a moon/asteroid orbital).

  @doc """
  Whether a generated body's industrial / technological / activity factors
  should be forced to the top (`:max`) or bottom (`:min`) of their range, or
  rolled normally (`nil`). Planets and orbitals are targeted separately.
  """
  def gen_factor_override(mutator_keys, :primary) do
    cond do
      :worlds_of_plenty in mutator_keys -> :max
      :hardscrabble_worlds in mutator_keys -> :min
      true -> nil
    end
  end

  def gen_factor_override(mutator_keys, :secondary) do
    if :gilded_orbitals in mutator_keys, do: :max, else: nil
  end

  # Factors live on a 1..5 scale. `:max`/`:min` set the scale extremes
  # directly (not the body's natural roll range), so mutator descriptions like
  # Gilded Orbitals "5/5/5" hold even where a body's appeal/science roll range
  # only reaches 4. Matches the starter-system path (see
  # StellarSystem.transform_to_starter_system/1).
  @max_factor 5
  @min_factor 1

  @doc """
  Apply a `gen_factor_override/2` result to a single rolled factor: `:max` →
  5, `:min` → 1, `nil` → keep the roll. `range` is accepted for call-site
  symmetry but unused — the override always targets the scale extreme.
  """
  def apply_factor(rolled, nil, _range), do: rolled
  def apply_factor(_rolled, :max, _range), do: @max_factor
  def apply_factor(_rolled, :min, _range), do: @min_factor

  @doc """
  Extra building tiles every generated body should get, from the frontier
  mutators. Defaults to 0.
  """
  def extra_tiles(mutator_keys) do
    cond do
      :sprawling_frontier in mutator_keys -> 2
      :open_frontier in mutator_keys -> 1
      true -> 0
    end
  end
end
