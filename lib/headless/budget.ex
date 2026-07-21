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

  # Phase split tables, PER RESOURCE — fractions of newly arrived
  # spendable stock. The uniform-table version regressed the whole meta
  # overnight (2026-07-15: col/eval 1.22 -> 0.92, frontier stability 43 ->
  # 14, "no ship patent" funnel share back to 38%): credit is abundant and
  # partitions fine, but TECH and IDEOLOGY are scarce early — the
  # colonization chain (600+2000 tech, 1200+ ideology lexes) needs them
  # CONCENTRATED, which is precisely what the old strict-priority forcing
  # provided. So scarce resources lean hard toward the phase's critical
  # path; credit funds the broad economy.
  @splits %{
    opening: %{
      credit: %{expansion: 0.20, economy: 0.55, military: 0.05, covert: 0.20},
      technology: %{expansion: 0.50, economy: 0.40, military: 0.05, covert: 0.05},
      ideology: %{expansion: 0.65, economy: 0.25, military: 0.00, covert: 0.10}
    },
    foundation: %{
      credit: %{expansion: 0.20, economy: 0.55, military: 0.05, covert: 0.20},
      technology: %{expansion: 0.50, economy: 0.40, military: 0.05, covert: 0.05},
      ideology: %{expansion: 0.65, economy: 0.25, military: 0.00, covert: 0.10}
    },
    expansion: %{
      credit: %{expansion: 0.35, economy: 0.40, military: 0.10, covert: 0.15},
      technology: %{expansion: 0.45, economy: 0.40, military: 0.05, covert: 0.10},
      ideology: %{expansion: 0.60, economy: 0.20, military: 0.05, covert: 0.15}
    },
    consolidation: %{
      credit: %{expansion: 0.10, economy: 0.40, military: 0.30, covert: 0.20},
      technology: %{expansion: 0.10, economy: 0.55, military: 0.25, covert: 0.10},
      ideology: %{expansion: 0.25, economy: 0.30, military: 0.20, covert: 0.25}
    },
    endgame: %{
      credit: %{expansion: 0.05, economy: 0.20, military: 0.45, covert: 0.30},
      technology: %{expansion: 0.05, economy: 0.30, military: 0.45, covert: 0.20},
      ideology: %{expansion: 0.05, economy: 0.15, military: 0.35, covert: 0.45}
    }
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
    pools = Map.get(mem, :pools) || empty()

    pools =
      Map.new(@resources, fn res ->
        fracs = fractions(phase, res, g)
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

  # (An expansion_ideo_share lever — scale the expansion pool's ideology up
  # in foundation/expansion to climb the cap ladder faster — was A/B-tested
  # 2026-07-20 and LOST decisively: zero-colony 50% vs 30%, cp75 sys 1 vs 2,
  # fit 153 vs 191, and it made transport_no_slot WORSE. The cap ladder was
  # never ideology-limited; the boost just starved economy/covert ideology.)
  defp fractions(phase, resource, g) do
    base = @splits |> Map.get(phase, @splits.foundation) |> Map.fetch!(resource)

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
