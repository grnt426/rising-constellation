defmodule Sim.Setup do
  @moduledoc """
  Bootstraps the headless battle-simulation arena and defines the
  per-game-stage ship pools used to scope an optimization run.

  Combat stats are identical across game speeds; only credit/production
  cost differs. We default to the same dataset the existing fight
  controller uses (`speed: :fast, mode: :prod`) so the simulator matches
  proven behaviour out of the box; pass a different metadata to
  `install/1` (e.g. `[speed: :medium, mode: :prod]`) to read the canonical
  balance costs.

  Stage pools follow the patent tech tree and the three-stage split:

    * early — scouts/light fighters/fighter-bombers/interceptors up to 8x,
      light & heavy corvettes up to 4x.
    * mid   — adds multi-turret corvettes, all four frigates (2x only),
      and the carrier; raises fighters to 16x and corvettes to 8x.
    * late  — adds the three capitals and the 4x frigate formation.

  They are strictly nested (early ⊂ mid ⊂ late), matching the hypothesis
  that each stage is a subset-optimisation of the next.
  """

  @doc "Build + cache the game dataset for the :sim instance. Idempotent."
  def install(metadata \\ [speed: :fast, mode: :prod]) do
    :persistent_term.erase({__MODULE__, :ship_index})
    Data.Data.install_sim(metadata)
  end

  def installed?, do: Data.Data.sim_installed?()

  @doc "Install the dataset once if it isn't already cached."
  def ensure_installed(metadata \\ [speed: :fast, mode: :prod]) do
    unless installed?(), do: install(metadata)
    :ok
  end

  ## Catalog accessors

  def ships, do: Data.Querier.all(Data.Game.Ship, :sim)
  def patents, do: Data.Querier.all(Data.Game.Patent, :sim)
  def constant, do: Data.Querier.one(Data.Game.Constant, :sim, :main)

  def ship(key), do: Enum.find(ships(), fn s -> s.key == key end)

  @doc "Memoized `%{ship_key => ship}` index (rebuilt on install). Hot-path lookup for Sim.Arena."
  def ship_index do
    case :persistent_term.get({__MODULE__, :ship_index}, nil) do
      nil ->
        idx = Map.new(ships(), fn s -> {s.key, s} end)
        :persistent_term.put({__MODULE__, :ship_index}, idx)
        idx

      idx ->
        idx
    end
  end

  @doc "Max number of army tiles (fleet slots) for one admiral."
  def tile_count, do: constant().army_tile_count

  ## Stage ship pools
  #
  # Each rule is {base_ship_key, max_unit_count}; expanded to the concrete
  # stack-variant keys by walking the merge_to chain and keeping variants
  # whose unit_count is within the cap.

  # Early game caps fighters at 4x (8x interceptors are expensive — that's
  # "the beginning of mid game") and corvettes at 4x.
  @early_rules [
    {:fighter_1, 4},
    {:fighter_2, 4},
    {:fighter_3, 4},
    {:fighter_4, 4},
    {:corvette_1, 4},
    {:corvette_2, 4}
  ]

  @mid_rules [
    {:fighter_1, 16},
    {:fighter_2, 16},
    {:fighter_3, 16},
    {:fighter_4, 16},
    {:corvette_1, 8},
    {:corvette_2, 8},
    {:corvette_3, 8},
    {:frigate_1, 2},
    {:frigate_2, 2},
    {:frigate_3, 2},
    {:frigate_4, 2},
    {:transport_2, 1}
  ]

  @late_rules [
    {:frigate_1, 4},
    {:frigate_2, 4},
    {:frigate_3, 4},
    {:frigate_4, 4},
    {:capital_1, 1},
    {:capital_2, 1},
    {:capital_3, 1}
  ]

  def stage_ship_keys(:early), do: expand_rules(@early_rules)
  def stage_ship_keys(:mid), do: Enum.uniq(expand_rules(@early_rules) ++ expand_rules(@mid_rules))
  def stage_ship_keys(:late), do: Enum.uniq(stage_ship_keys(:mid) ++ expand_rules(@late_rules))

  defp expand_rules(rules) do
    by_key = Map.new(ships(), fn s -> {s.key, s} end)

    rules
    |> Enum.flat_map(fn {base, max_units} -> expand_chain(base, max_units, by_key) end)
    |> Enum.uniq()
  end

  # Walk the merge_to chain from `base`, collecting variants with
  # unit_count <= max_units.
  defp expand_chain(base, max_units, by_key) do
    case Map.get(by_key, base) do
      nil ->
        []

      ship ->
        rest = if ship.merge_to, do: expand_chain(ship.merge_to, max_units, by_key), else: []
        if ship.unit_count <= max_units, do: [ship.key | rest], else: rest
    end
  end
end
