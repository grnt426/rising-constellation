defmodule Sim.Genome do
  @moduledoc """
  Genome for the fleet-design search.

    * **18 slot genes** (one per army tile), each `0..79` encoding `(type, stack)`
      in mixed radix `type*5 + stack_tier` — type 0 = empty / 1..15 a combat type,
      stack tier 0..4 -> {1,2,4,8,16} units.
    * **5 class-level genes**, each `0..max_build_level`, giving the build level of
      each ship class (fighter / corvette / frigate / transport / capital).

  Ship level is **per class, not per ship.** A system produces every ship of a
  class at the same XP (driven by Aerospace Military Academies + a training
  governor + the Navarch Tradition lex), so a fleet's interceptors and scouts
  (both `:fighter`) share one level, while its corvettes may sit at another —
  but a class is never split across levels (a player wouldn't, and couldn't
  without shuffling shipyards). We don't model the XP infrastructure directly;
  the per-class level *is* the buildable level and the 5%/level cost (see
  `Sim.Cost`) proxies the investment to reach it.

  Levels are capped at `max_build_level/0` (~150 XP, the realistic *buildable*
  ceiling). Battle-earned XP can exceed that, but fleet *design* optimises around
  what a system can build; the "what if they had more levels" question lives in
  `Sim.LevelBreak`.

  `decode/2` CLAMPS (type, stack) to the nearest legal & stage-allowed variant,
  so every genome maps to a valid, class-uniform fleet.
  """

  # Index 1..15 (0 = EMPTY); excludes transport_1 (colony ship). 15 + empty = 16.
  @types {
    :fighter_1,
    :fighter_2,
    :fighter_3,
    :fighter_4,
    :corvette_1,
    :corvette_2,
    :corvette_3,
    :frigate_1,
    :frigate_2,
    :frigate_3,
    :frigate_4,
    :transport_2,
    :capital_1,
    :capital_2,
    :capital_3
  }
  @stack_sizes {1, 2, 4, 8, 16}
  @type_count 15
  @slot_count 18
  # slot gene = type(0..15) * 5 + stack_tier(0..4) -> 0..79
  @slot_max 16 * 5
  @class_order [:fighter, :corvette, :frigate, :transport, :capital]
  # Realistic buildable level ceiling (~150 XP). A knob — tied to how much XP
  # infrastructure (AMA level, shipyard level, training-gov points) a player can
  # realistically dedicate without sacrificing production / static defense.
  @max_build_level 7

  def slots, do: @slot_count
  def types, do: @types
  def class_order, do: @class_order
  def max_build_level, do: @max_build_level

  @doc "A random genome (18 slot genes + 5 class-level genes). Uses the process RNG."
  def random do
    slots = for _ <- 1..@slot_count, do: :rand.uniform(@slot_max) - 1
    levels = for _ <- @class_order, do: :rand.uniform(@max_build_level + 1) - 1
    slots ++ levels
  end

  @doc "Uniform crossover: each gene taken independently from either parent."
  def crossover(g1, g2) do
    Enum.zip(g1, g2)
    |> Enum.map(fn {a, b} -> if :rand.uniform() < 0.5, do: a, else: b end)
  end

  @doc "Per-gene mutation, respecting each gene's range (slot genes vs class-level genes)."
  def mutate(genome, rate) do
    genome
    |> Enum.with_index()
    |> Enum.map(fn {gene, i} ->
      cond do
        :rand.uniform() >= rate -> gene
        i < @slot_count -> :rand.uniform(@slot_max) - 1
        true -> :rand.uniform(@max_build_level + 1) - 1
      end
    end)
  end

  @doc """
  Decode a genome into fleet slots `[{tile_id, ship_key, level}]` for `stage`,
  clamping each slot to a legal & stage-allowed ship and applying the per-class
  build level (all ships of a class share one level).
  """
  def decode(genome, stage) do
    {slot_genes, level_genes} = Enum.split(genome, @slot_count)
    class_levels = @class_order |> Enum.zip(level_genes) |> Map.new()

    allowed = MapSet.new(Sim.Setup.stage_ship_keys(stage))
    by_key = Sim.Setup.ship_index()

    slot_genes
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {code, tile} ->
      type = div(code, 5)
      stack_tier = rem(code, 5)

      case clamp(type, stack_tier, allowed, by_key) do
        nil -> []
        key -> [{tile, key, Map.get(class_levels, by_key[key].class, 0)}]
      end
    end)
  end

  # type 0 -> empty. Otherwise: take the base type, walk its merge chain, keep
  # variants allowed in this stage, and pick the largest unit_count <= the
  # requested size (clamp down); if none are <= requested, take the smallest
  # available (clamp up). No allowed variant for this type/stage -> empty.
  defp clamp(0, _stack_tier, _allowed, _by_key), do: nil

  defp clamp(type, stack_tier, allowed, by_key) when type >= 1 and type <= @type_count do
    base = elem(@types, type - 1)
    requested = elem(@stack_sizes, stack_tier)

    variants =
      base
      |> chain(by_key)
      |> Enum.filter(fn k -> MapSet.member?(allowed, k) end)
      |> Enum.map(fn k -> {k, by_key[k].unit_count} end)

    case Enum.filter(variants, fn {_k, uc} -> uc <= requested end) do
      [] ->
        case variants do
          [] -> nil
          vs -> vs |> Enum.min_by(fn {_k, uc} -> uc end) |> elem(0)
        end

      le ->
        le |> Enum.max_by(fn {_k, uc} -> uc end) |> elem(0)
    end
  end

  defp clamp(_type, _stack_tier, _allowed, _by_key), do: nil

  # The full stack-variant chain for a base key, via merge_to.
  defp chain(base, by_key) do
    Stream.unfold(base, fn
      nil -> nil
      k -> {k, by_key[k] && by_key[k].merge_to}
    end)
    |> Enum.to_list()
  end
end
