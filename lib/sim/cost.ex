defmodule Sim.Cost do
  @moduledoc """
  Build cost and one-time unlock (patent) cost for a fleet.

    * `build_cost/1` — recurring cost: credit / production / technology /
      maintenance summed over the ships in the fleet. **Ship level carries a
      cost penalty**: each level adds #{trunc(0.05 * 100)}% to a ship's credit
      and production cost — a proxy for the XP infrastructure (Aerospace
      Military Academies + training governor + Navarch lex) needed to build that
      class at that level. Technology and maintenance are unaffected.
    * `unlock_cost/1` — one-time tech cost: sum of patent `cost` over the
      *prerequisite closure* of every patent that gates a ship in the fleet
      (shipyards + merge patents + base unlocks), deduplicated.

  Inputs accept ship keys (`:fighter_1`, level 0) or `{ship_key, level}` tuples.
  For build cost, pass one entry per ship (duplicates matter); for unlock cost
  the list is deduplicated internally.
  """

  # Each ship level adds this fraction to the ship's credit + production cost.
  # 5% (was 2%): leveling is a meaningful, system-level investment, not cheap —
  # so the optimiser must justify every +1. Bump to 0.10 to penalise harder.
  @level_cost_rate 0.05

  @doc "Recurring cost of a fleet (list of keys or {key, level}; duplicates count)."
  def build_cost(slots) when is_list(slots) do
    by_key = ships_by_key()

    Enum.reduce(slots, %{credit: 0, production: 0, technology: 0, maintenance: 0}, fn slot, acc ->
      {key, level} = normalize(slot)

      case Map.get(by_key, key) do
        nil ->
          acc

        s ->
          factor = 1 + @level_cost_rate * level

          %{
            credit: acc.credit + round(s.credit_cost * factor),
            production: acc.production + round(s.production * factor),
            technology: acc.technology + s.technology_cost,
            maintenance: acc.maintenance + s.maintenance_cost
          }
      end
    end)
  end

  @doc "Per-level cost rate (fraction of base added per ship level)."
  def level_cost_rate, do: @level_cost_rate

  @doc """
  One-time Technology cost to unlock everything the given ships require.
  Deduplicates ships and shared prerequisites, so two ships behind the same
  shipyard count that shipyard once. Level is irrelevant to unlock cost.
  """
  def unlock_cost(slots) when is_list(slots) do
    patents_by_key = patents_by_key()

    slots
    |> required_patents()
    |> Enum.reduce(0, fn patent_key, sum ->
      case Map.get(patents_by_key, patent_key) do
        nil -> sum
        p -> sum + p.cost
      end
    end)
  end

  @doc "The set of patent keys required to unlock the given ships (prerequisite closure)."
  def required_patents(slots) when is_list(slots) do
    ships_by_key = ships_by_key()
    patents_by_key = patents_by_key()

    slots
    |> Enum.map(&key_of/1)
    |> Enum.uniq()
    |> Enum.map(fn key -> Map.get(ships_by_key, key) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.patent)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(MapSet.new(), fn patent_key, acc ->
      collect_ancestors(patent_key, patents_by_key, acc)
    end)
  end

  defp collect_ancestors(nil, _patents_by_key, acc), do: acc

  defp collect_ancestors(patent_key, patents_by_key, acc) do
    if MapSet.member?(acc, patent_key) do
      acc
    else
      acc = MapSet.put(acc, patent_key)

      case Map.get(patents_by_key, patent_key) do
        nil -> acc
        p -> collect_ancestors(p.ancestor, patents_by_key, acc)
      end
    end
  end

  defp normalize(key) when is_atom(key), do: {key, 0}
  defp normalize({key, level}) when is_atom(key), do: {key, level}

  defp key_of(key) when is_atom(key), do: key
  defp key_of({key, _level}), do: key

  defp ships_by_key, do: Map.new(Sim.Setup.ships(), fn s -> {s.key, s} end)
  defp patents_by_key, do: Map.new(Sim.Setup.patents(), fn p -> {p.key, p} end)
end
