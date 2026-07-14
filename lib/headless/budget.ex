defmodule Headless.Budget do
  @moduledoc """
  V3 pillar 2: budget pools (docs/game-ai-v3.md).

  A per-bot resource ledger living in policy mem. Each decision, newly
  arrived spendable resources (credit / technology / ideology) are split
  across four pools — expansion, economy, military, covert — by the game
  phase's table scaled by the genome's focus_* leans. Nodes spend only
  from their pool; an unspent pool ROLLS OVER, which is how saving for a
  12k transport or a 2000-tech ship happens without strict-priority
  reservations.

  This retires the starvation bug class that dominated the V2 era: ship
  credit vs development spending, admiral tech vs patents, covert hires
  vs the colonizer arm — every one was two consumers fighting over one
  unpartitioned stock. Replaced on arrival: the reserve_first_colony /
  reserve_followup_colony mechanism, scattered credit_floor spend gates,
  and the hire_reserve gate.

  Accounting model: the ledger tracks pool balances; nodes decrement on
  spend using their KNOWN approximate costs (catalog prices). Engine-side
  drift — upkeep, price inflation on lexes, refunds, opener spending —
  is absorbed by reconciliation: when the real spendable stock is below
  the ledger sum, pools scale down proportionally; when above, the
  difference is treated as inflow and distributed by the current splits.
  The ledger therefore never promises more than the player actually has.
  """

  @pools [:expansion, :economy, :military, :covert]
  @resources [:credit, :technology, :ideology]

  # Phase split tables — fractions of newly arrived spendable resources.
  # Foundation is economy-heavy (the growth engine IS the strategy there);
  # expansion phase funds the lanes; endgame shifts to the sprint
  # (military/covert own the close, expansion is waste).
  @splits %{
    opening: %{expansion: 0.25, economy: 0.45, military: 0.10, covert: 0.20},
    foundation: %{expansion: 0.30, economy: 0.45, military: 0.10, covert: 0.15},
    expansion: %{expansion: 0.40, economy: 0.30, military: 0.15, covert: 0.15},
    consolidation: %{expansion: 0.15, economy: 0.35, military: 0.30, covert: 0.20},
    endgame: %{expansion: 0.05, economy: 0.20, military: 0.45, covert: 0.30}
  }

  # The existing focus_* gene family (0..2) doubles as the pool leans —
  # personality scales its pool's share, then shares renormalize.
  @lean_gene %{
    expansion: "focus_expansion",
    economy: "focus_economy",
    military: "focus_military",
    covert: "focus_shadows"
  }

  def pools, do: @pools

  @doc "Current balance of a pool for a resource."
  def balance(mem, pool, resource), do: get_in(mem, [:pools, resource, pool]) || 0.0

  @doc "Can this pool cover the cost?"
  def afford?(mem, pool, resource, cost), do: balance(mem, pool, resource) >= cost

  @doc "Decrement a pool after emitting a spend action (clamped at zero)."
  def spend(mem, pool, resource, cost) do
    update_in(mem, [:pools, resource, pool], fn bal -> max((bal || 0.0) - cost, 0.0) end)
  end

  @doc """
  Per-decision reconcile + allocate. Distributes inflow by the phase's
  splits × genome leans; scales the ledger down when reality (upkeep,
  price inflation, engine-side costs) ate more than the ledger knew.
  """
  def allocate(mem, view, phase, g) do
    fracs = fractions(phase, g)
    pools = Map.get(mem, :pools) || empty()

    pools =
      Map.new(@resources, fn res ->
        available = spendable(view.player, res, g)
        ledger = Map.get(pools, res, zero())
        total = ledger |> Map.values() |> Enum.sum()

        ledger =
          cond do
            # Inflow (income, or costs the ledger over-estimated):
            # distribute by the current phase's splits.
            available > total ->
              inflow = available - total
              Map.new(ledger, fn {pool, bal} -> {pool, bal + inflow * fracs[pool]} end)

            # Drift (upkeep, lex price inflation, opener spends): the
            # ledger promised more than exists — scale down pro rata.
            available < total and total > 0 ->
              scale = available / total
              Map.new(ledger, fn {pool, bal} -> {pool, bal * scale} end)

            true ->
              ledger
          end

        {res, ledger}
      end)

    Map.put(mem, :pools, pools)
  end

  # Spendable stock per resource. credit_floor stays as the SOLVENCY floor
  # (a real personality knob) — but it lives here now, not scattered
  # through every node's spend gate.
  defp spendable(player, :credit, g),
    do: max(player.credit.value - Map.get(g, "credit_floor", 6_000), 0.0)

  defp spendable(player, :technology, _g), do: max(player.technology.value, 0.0)
  defp spendable(player, :ideology, _g), do: max(player.ideology.value, 0.0)

  defp fractions(phase, g) do
    base = Map.get(@splits, phase, @splits.foundation)

    weighted =
      Map.new(base, fn {pool, frac} ->
        {pool, frac * max(Map.get(g, @lean_gene[pool], 1.0), 0.05)}
      end)

    total = weighted |> Map.values() |> Enum.sum()
    Map.new(weighted, fn {pool, w} -> {pool, w / total} end)
  end

  defp empty, do: Map.new(@resources, fn res -> {res, zero()} end)
  defp zero, do: Map.new(@pools, fn pool -> {pool, 0.0} end)
end
