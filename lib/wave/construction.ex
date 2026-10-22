defmodule Wave.Construction do
  @moduledoc """
  The Rebellion pays for what its systems build.

  A human pays credit for every building and upgrade (the level's `credit`)
  and for every repair (that times `building_repairs_factor`) when the order
  is placed (`Instance.Player.Player.order_building/5`). The system AI places
  its orders on the system alone, so until 2026-10-22 the Rebellion's
  systems built for nothing: on i185, 272M credits of construction against
  200M of real income.

  A rebel system now pays the same prices out of the construction allowance
  the Warlord sets (`Wave.Budget`). After the tree has run, `charge/2` prices
  the orders it placed: when the allowance covers them, it draws the credit
  and the turn stands; otherwise the turn is dropped and nothing is ordered.
  The system agent then casts the credit to the bot player
  (`{:pay_construction, credit}`).

  Neutral systems and human dominions are developed by the vanilla tree as
  before, at no cost to anyone.
  """

  alias Instance.StellarSystem.StellarSystem

  @doc """
  Settle a tree turn that took the system from `was` to `now`: `{:ok, credit}` with
  what was drawn (0 for a system the Rebellion does not hold, or a turn that
  ordered nothing), or `:unaffordable` when the allowance cannot cover it.
  """
  def charge(%StellarSystem{} = was, %StellarSystem{} = now) do
    case Wave.Config.bot_system?(was) and orders_credit(was, now) do
      false -> {:ok, 0}
      0 -> {:ok, 0}
      credit -> if Wave.Budget.take(was.instance_id, credit) == :ok, do: {:ok, credit}, else: :unaffordable
    end
  end

  @doc """
  What the system may spend on construction now: the Rebellion's allowance
  for one of its systems (0 before the Warlord set any), nil (no limit) for
  any other system. The tree's choices read it so a rebel system picks among
  the orders it can pay for.
  """
  def budget(system) do
    if Wave.Config.bot_system?(system), do: Wave.Budget.available(system.instance_id) || 0
  end

  @doc "What the orders in `now` that `was` did not have cost a human."
  def orders_credit(%StellarSystem{} = was, %StellarSystem{} = now) do
    placed = was |> items() |> MapSet.new(&order/1)

    now
    |> items()
    |> Enum.reject(&MapSet.member?(placed, order(&1)))
    |> Enum.map(&credit(now.instance_id, &1.type, &1.prod_key, &1.prod_level))
    |> Enum.sum()
  end

  @doc """
  The credit a human pays to order `type` of `prod_key` at `prod_level`
  (the same prices as `Player.order_building/5`): the level's credit for a
  build or an upgrade, that times the repair factor for a repair. 0 for any
  other kind of order.
  """
  def credit(instance_id, type, prod_key, prod_level) when type in [:building, :building_repairs] do
    with %{levels: levels} <- Data.Querier.one(Data.Game.Building, instance_id, prod_key),
         %{credit: credit} <- Enum.find(levels, &(&1.level == prod_level)) do
      if type == :building do
        credit
      else
        constant = Data.Querier.one(Data.Game.Constant, instance_id, :main)
        round(credit * constant.building_repairs_factor)
      end
    else
      _ -> 0
    end
  end

  def credit(_instance_id, _type, _prod_key, _prod_level), do: 0

  defp items(system), do: Queue.to_list(system.queue.queue)

  # Queue ids are reused once the queue empties: an order is told apart by
  # what it builds.
  defp order(item), do: {item.type, item.target_id, item.tile_id, item.prod_key, item.prod_level}
end
