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
  @catalog [
    %{
      key: :empire_of_wealth,
      name: "Empire of Wealth",
      description: "Every player starts the game with double the credit reserves.",
      hook: :on_player_init,
      implemented: true
    },
    %{
      key: :frontier_stockpile,
      name: "Frontier Stockpile",
      description:
        "Triple the starting credit — for scenarios that want an aggressive opening rush.",
      hook: :on_player_init,
      implemented: true
    },
    %{
      key: :lean_years,
      name: "Lean Years",
      description: "Players start with only half the usual credit. Survival is the early game.",
      hook: :on_player_init,
      implemented: true
    },
    %{
      key: :old_knowledge,
      name: "Old Knowledge",
      description:
        "The empires of old left their research behind. Players begin with double the starting technology.",
      hook: :on_player_init,
      implemented: true
    },
    %{
      key: :faith_reborn,
      name: "Faith Reborn",
      description:
        "Doctrinal certainty runs deep. Players begin with double the starting ideology.",
      hook: :on_player_init,
      implemented: true
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
end
