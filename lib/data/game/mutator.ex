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
  # Beyond the picker fields (key/name/description/hook/implemented), two tags
  # drive the daily-challenge generator (lib/daily/generator.ex):
  #
  #   * polarity       — :positive | :negative, so a daily can roll "2 boons
  #                      + 1 bane" without hand-curating each day.
  #   * daily_eligible — whether the daily rotation may pick this mutator.
  #
  # Entries with `implemented: false` are catalog-only: the picker greys them
  # out and the daily generator skips them unless explicitly asked for the
  # full roster (`mix daily.preview --all`). They pin down the roadmap and
  # the hook each effect will need. See docs/mutator-ideas.md and
  # docs/daily-challenge.md.
  @catalog [
    # --- resource scalers (implemented; on_player_init) --------------------
    %{
      key: :empire_of_wealth,
      name: "Empire of Wealth",
      description: "Every player starts the game with double the credit reserves.",
      hook: :on_player_init,
      implemented: true,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :frontier_stockpile,
      name: "Frontier Stockpile",
      description: "Triple the starting credit — for scenarios that want an aggressive opening rush.",
      hook: :on_player_init,
      implemented: true,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :lean_years,
      name: "Lean Years",
      description: "Players start with only half the usual credit. Survival is the early game.",
      hook: :on_player_init,
      implemented: true,
      polarity: :negative,
      daily_eligible: true
    },
    %{
      key: :old_knowledge,
      name: "Old Knowledge",
      description: "The empires of old left their research behind. Players begin with double the starting technology.",
      hook: :on_player_init,
      implemented: true,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :faith_reborn,
      name: "Faith Reborn",
      description: "Doctrinal certainty runs deep. Players begin with double the starting ideology.",
      hook: :on_player_init,
      implemented: true,
      polarity: :positive,
      daily_eligible: true
    },

    # --- world-generation twists (roadmap; on_galaxy_spawn) ----------------
    %{
      key: :garden_worlds,
      name: "Garden Worlds",
      description: "Every habitable world is lush and earth-like — no barren rocks to settle.",
      hook: :on_galaxy_spawn,
      implemented: false,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :barren_crucible,
      name: "Barren Crucible",
      description: "Every habitable world is sterile — wring prosperity from dead stone.",
      hook: :on_galaxy_spawn,
      implemented: false,
      polarity: :negative,
      daily_eligible: true
    },
    %{
      key: :worlds_of_plenty,
      name: "Worlds of Plenty",
      description: "Every planet spawns with maxed industry, science and appeal (5/5/5).",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :hardscrabble_worlds,
      name: "Hardscrabble Worlds",
      description: "Every planet spawns at the lowest factors (1/1/1). Make do with little.",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :negative,
      daily_eligible: true
    },
    %{
      key: :gilded_orbitals,
      name: "Gilded Orbitals",
      description: "Every non-planet body spawns with maxed factors (5/5/5).",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :sprawling_frontier,
      name: "Sprawling Frontier",
      description: "Every body has two extra building tiles. Room to grow.",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :open_frontier,
      name: "Open Frontier",
      description: "Every body has one extra building tile.",
      hook: :on_galaxy_spawn,
      implemented: true,
      polarity: :positive,
      daily_eligible: true
    },

    # --- economy / pacing twists (roadmap; on_player_init / on_tick) -------
    %{
      key: :teeming_masses,
      name: "Teeming Masses",
      description: "Begin with thirty extra population already settled.",
      hook: :on_player_init,
      implemented: false,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :hyperlane_mastery,
      name: "Hyperlane Mastery",
      description: "Mobility is twice as effective.",
      hook: :on_tick,
      implemented: false,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :enlightened_age,
      name: "Enlightened Age",
      description: "Technology income flows 50% faster.",
      hook: :on_tick,
      implemented: false,
      polarity: :positive,
      daily_eligible: true
    },
    %{
      key: :zealous_fervor,
      name: "Zealous Fervor",
      description: "Ideology income flows 50% faster.",
      hook: :on_tick,
      implemented: false,
      polarity: :positive,
      daily_eligible: true
    },

    # --- restrictions / banes (roadmap; assorted hooks) --------------------
    %{
      key: :cramped_quarters,
      name: "Cramped Quarters",
      description: "Housing is 25% less effective.",
      hook: :on_bonus,
      implemented: false,
      polarity: :negative,
      daily_eligible: true
    },
    %{
      key: :lost_sciences,
      name: "Lost Sciences",
      description: "Patents cost double to research.",
      hook: :on_cost,
      implemented: false,
      polarity: :negative,
      daily_eligible: true
    },
    %{
      key: :restless_senate,
      name: "Restless Senate",
      description: "Lex influence scales 30% faster — the senate moves whether you're ready or not.",
      hook: :on_tick,
      implemented: false,
      polarity: :negative,
      daily_eligible: true
    },
    %{
      key: :inexperienced_court,
      name: "Inexperienced Court",
      description: "Governors earn experience 50% slower.",
      hook: :on_xp,
      implemented: false,
      polarity: :negative,
      daily_eligible: true
    },
    %{
      key: :closed_borders,
      name: "Closed Borders",
      description: "Agents cannot be recruited — work with the court you have.",
      hook: :on_action,
      implemented: false,
      polarity: :negative,
      daily_eligible: true
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

  @doc """
  Apply a `gen_factor_override/2` result to a single rolled factor. `:max` /
  `:min` clamp to the body-type's allowed `range`; `nil` keeps the roll.
  """
  def apply_factor(rolled, nil, _range), do: rolled
  def apply_factor(_rolled, :max, range), do: Enum.max(range)
  def apply_factor(_rolled, :min, range), do: Enum.min(range)

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
