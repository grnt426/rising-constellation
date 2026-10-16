defmodule Wave.Draw do
  @moduledoc """
  Drawing a target by weight, and the weights every such draw shares.

  The Rebellion's agitators and its fleets do not rank their targets and take
  the first: each system in reach gets a weight and one is drawn, so the
  strikes spread (`Wave.Siderian.pick_destab/3`, `Wave.Sortie.pick/3`). Pure.
  """

  # A sector nothing connects to rebel space counts as three further back.
  @unreached_sectors 3

  @doc "1 to 2 with the population the Rebellion can see, 1.5 when it cannot."
  def size(population) when is_number(population), do: 1.0 + min(max(population, 0), 100) / 100
  def size(_population), do: 1.5

  @doc """
  `factor` per sector further back than `nearest`, the shallowest depth among
  the candidates. `depth` is a sector's distance from rebel space, nil when
  no chain of sectors reaches it.
  """
  def rear(depth, nearest, factor) when is_number(factor) do
    behind = if is_integer(depth), do: max(depth - (nearest || 0), 0), else: @unreached_sectors
    :math.pow(factor, behind)
  end

  @doc "The shallowest sector depth among `targets`, 0 when none has one."
  def nearest_depth(targets),
    do: targets |> Enum.map(&Map.get(&1, :depth)) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> 0 end)

  @doc "1 next door, 0.5 at the edge of `reach`."
  def nearness(travel, reach) when is_number(travel) and is_number(reach) and reach > 0,
    do: 1.0 / (1.0 + max(travel, 0.0) / reach)

  def nearness(_travel, _reach), do: 1.0

  @doc """
  Draw one item from `[{item, weight}]`. `roll` is uniform in [0, 1). Items
  without weight are never drawn; nil when nothing has any.
  """
  def pick(weighted, roll) when is_list(weighted) and is_number(roll) do
    weighted = Enum.filter(weighted, fn {_item, weight} -> weight > 0 end)
    total = weighted |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    aim = roll * total

    weighted
    |> Enum.reduce_while(0.0, fn {item, weight}, acc ->
      if aim < acc + weight, do: {:halt, {:drawn, item}}, else: {:cont, acc + weight}
    end)
    |> case do
      {:drawn, item} -> item
      _ when weighted == [] -> nil
      _ -> weighted |> List.last() |> elem(0)
    end
  end
end
