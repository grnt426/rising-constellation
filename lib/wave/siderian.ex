defmodule Wave.Siderian do
  @moduledoc """
  The Rebellion's Siderians: which trade each one plies, how the roster is
  split between the trades, what the Rebellion can tell about a system's
  stability, and where an agitator strikes or practises.

  Pure decisions only, like `Wave.Erased`: `Wave.Warlord.Agent` does the I/O.
  Design and rationale: docs/wave-defense.md, "Siderians: destabilization and
  seduction".

  ## Roles

  | role | action | skill (index) | bonus |
  |---|---|---|---|
  | `:capture` | `make_dominion` | proselyte (0) | `speaker_make_dominion` |
  | `:destab` | `encourage_hate` | agitator (1) | `speaker_encourage_hate` |
  | `:seduce` | `conversion` | seducer (2) | `speaker_conversion` |

  A Siderian is bought for a role and keeps it. The in-game Destabilize and
  Seduce actions are greyed out at 0 points in their skill, so a role is only
  ever given to an agent with at least one point in it.

  ## Stability

  A system's happiness is legible at visibility 3, and an agent standing in
  it gives only 2, so the Rebellion mostly learns it from its own
  destabilization reports: each one shows the defence rolled against
  (`max(happiness, 0)`) and the penalty applied. `record_destab/6` keeps that
  as an anchor plus a ledger of our own penalties, each decaying on its own at
  the engine's `happiness_penalty_reduction_factor`, and `estimate/3` reads it
  back. Below 0 a report only says 0, so from there the estimate runs on the
  ledger alone.
  """

  @proselyte 0
  @agitator 1
  @seducer 2

  @roles [:capture, :destab, :seduce]
  @bonus_keys %{capture: :speaker_make_dominion, destab: :speaker_encourage_hate, seduce: :speaker_conversion}

  def roles, do: @roles

  @doc "The Siderian skill points that matter, by role."
  def skill_points(skills) when is_list(skills) do
    %{
      capture: Enum.at(skills, @proselyte, 0) || 0,
      destab: Enum.at(skills, @agitator, 0) || 0,
      seduce: Enum.at(skills, @seducer, 0) || 0
    }
  end

  def skill_points(_skills), do: %{capture: 0, destab: 0, seduce: 0}

  @doc """
  A Siderian's strength in one role: the bonus its points grant to that
  role's action, from the speaker `specializations` table. Faction and
  doctrine bonuses only multiply this, so zero can never win a roll.
  """
  def strength(skills, specializations, role)
      when is_list(skills) and is_list(specializations) and is_map_key(@bonus_keys, role) do
    key = Map.fetch!(@bonus_keys, role)

    for %{index: index, bonus: bonuses} <- specializations,
        %{to: ^key, type: :add, value: value} <- bonuses,
        reduce: 0 do
      acc -> acc + value * (Enum.at(skills, index, 0) || 0)
    end
  end

  def strength(_skills, _specializations, _role), do: 0

  @doc """
  Roll a role for an agent the Rebellion did not choose — a seduced convert —
  among the roles it has points for, each weight scaled by `1 + points`, the
  way Erased duties are rolled. nil when it has no point in any of them.
  """
  def role(roll, weights, skills) do
    points = skill_points(skills)

    scaled =
      @roles
      |> Enum.filter(&(Map.get(points, &1, 0) > 0))
      |> Enum.map(&{&1, Map.get(weights, &1, 0) * (1 + Map.get(points, &1, 0))})
      |> Enum.filter(fn {_role, weight} -> weight > 0 end)

    case scaled do
      [] -> nil
      _ -> weighted_pick(scaled, roll)
    end
  end

  @doc """
  How many Siderians each role should have. Capture takes its share of the
  `ceiling` only up to the capture targets there are; the rest of the ceiling
  goes to destabilization and seduction by their weights, largest remainder
  first so the quotas add up to the ceiling exactly. `seduce_cap` (an integer,
  or nil for none) then holds seduction down while no human is in reach.
  """
  def quotas(ceiling, weights, capture_targets, seduce_cap \\ nil)
      when is_integer(ceiling) and is_integer(capture_targets) do
    total = Enum.sum(Enum.map(@roles, &Map.get(weights, &1, 0)))
    targets = max(capture_targets, 0)

    capture =
      if total > 0,
        do: min(round(ceiling * Map.get(weights, :capture, 0) / total), targets),
        else: 0

    rest = max(ceiling - capture, 0)
    split = largest_remainder(rest, destab: Map.get(weights, :destab, 0), seduce: Map.get(weights, :seduce, 0))

    # With no human in reach a seducer has nobody to seduce, so only
    # `seduce_cap` are kept. The places that frees go to capture while there
    # are targets for it, and are otherwise left unfilled: better no hire than
    # one whose only use is training.
    freed = if is_integer(seduce_cap), do: max(split.seduce - max(seduce_cap, 0), 0), else: 0
    moved = min(freed, targets - capture)

    split
    |> Map.put(:seduce, split.seduce - freed)
    |> Map.put(:capture, capture + moved)
  end

  @doc """
  The roles to hire for, most short of its quota first (by the share of the
  quota still missing), roles at or over quota left out.
  """
  def hire_order(counts, quotas) do
    @roles
    |> Enum.map(fn role -> {role, Map.get(quotas, role, 0), Map.get(counts, role, 0)} end)
    |> Enum.filter(fn {_role, quota, count} -> count < quota end)
    |> Enum.sort_by(fn {role, quota, count} -> {-(quota - count) / quota, Enum.find_index(@roles, &(&1 == role))} end)
    |> Enum.map(&elem(&1, 0))
  end

  # --- stability ------------------------------------------------------------------

  @doc """
  Fold one destabilization report into a system's reading. `defence` is what
  the report showed (`max(happiness, 0)` before the strike), `penalty` what
  the strike took off. A positive defence re-anchors the reading; a zero one
  only says the system was already at or below 0, so the ledger carries on.
  """
  def record_destab(reading, defence, penalty, now, decay, floor) do
    ledger_entry = %{penalty: penalty * 1.0, at: now}

    reading =
      if is_number(defence) and defence > 0 do
        %{anchor: defence * 1.0, at: now, ledger: [ledger_entry]}
      else
        base = reading || %{anchor: 0.0, at: now, ledger: []}
        %{base | ledger: [ledger_entry | prune(Map.get(base, :ledger, []), now, decay)]}
      end

    held = Map.get(reading, :held, false) or estimate(reading, now, decay) <= floor
    Map.put(reading, :held, held)
  end

  @doc """
  The estimated happiness of a system from its reading, or nil when there is
  none: the anchor less what remains of our own penalties since.
  """
  def estimate(nil, _now, _decay), do: nil

  def estimate(%{anchor: anchor} = reading, now, decay) do
    remaining = reading |> Map.get(:ledger, []) |> Enum.map(&remaining(&1, now, decay)) |> Enum.sum()
    anchor - remaining
  end

  @doc """
  Whether a system still wants destabilizing, and by how many agitators at
  most: until the estimate reaches `floor` it takes up to `cap`; once it has
  been driven there it is *held*, and one agitator tops it up whenever the
  estimate climbs back above `floor + margin`. An unknown system always does.
  """
  def destab_need(reading, now, decay, floor, margin, cap) do
    case estimate(reading, now, decay) do
      nil ->
        cap

      est ->
        if(Map.get(reading, :held, false),
          do: if(est > floor + margin, do: 1, else: 0),
          else: if(est > floor, do: cap, else: 0)
        )
    end
  end

  @doc """
  Rank mass-destabilization targets. First the one agitators are already
  working (so they converge), then systems in sectors the Rebellion works,
  then the most populous it can see, then the least happy, then the nearest.
  `target` carries `:committed`, `:working_sector?`, `:population` (nil when
  not legible), `:estimate` (nil when unknown) and `:travel`.
  """
  def destab_priority(target) do
    {
      if(Map.get(target, :committed, 0) > 0, do: 0, else: 1),
      if(Map.get(target, :working_sector?, false), do: 0, else: 1),
      -(Map.get(target, :population) || 0),
      Map.get(target, :estimate) || 1_000.0,
      Map.get(target, :travel, 0.0),
      target.id
    }
  end

  @doc """
  Rank practice grounds for a new cluster: the Rebellion's border sectors
  first (held ground next to the front, where an agent can rest between
  strikes), then its other sectors, then anywhere; within that, neutrals the
  capture Siderians will want (practice softens them), then the least happy,
  then the nearest.
  """
  def ground_priority(ground) do
    {
      sector_rank(Map.get(ground, :sector_class)),
      if(Map.get(ground, :capture_candidate?, false), do: 0, else: 1),
      Map.get(ground, :estimate) || 1_000.0,
      Map.get(ground, :travel, 0.0),
      ground.id
    }
  end

  @doc "How good a sector class is to practise in: border, then internal, then the rest."
  def sector_rank(:border), do: 0
  def sector_rank(:internal), do: 1
  def sector_rank(_class), do: 2

  @doc """
  The penalty a destabilization applied, read off the cooldown the Siderian
  came back with — the duration it was set to (`Core.CooldownValue.initial`),
  which the engine pairs with the outcome: critical failure 0 / 120 ut,
  failure 5 / 100, success 15 / 40, critical success 20 / 30. The player
  reads the same thing off their agent.
  """
  def penalty_from_cooldown(duration) when is_number(duration) do
    cond do
      duration > 110 -> 0
      duration > 70 -> 5
      duration > 35 -> 15
      duration > 0 -> 20
      true -> nil
    end
  end

  def penalty_from_cooldown(_remaining), do: nil

  # --- seduction -------------------------------------------------------------------

  @doc """
  True for a hostile a seducer may go after: a Navarch, Siderian or Erased,
  on board or governing, but never an undercover Erased (it cannot be seen)
  and never a level-1 stand-in commander, which buys nothing.
  """
  def seducible?(hostile) do
    hostile.type in [:admiral, :spy, :speaker] and
      not (hostile.type == :spy and Map.get(hostile, :discovered?) != true and not Map.get(hostile, :governor?, false)) and
      not (Wave.Erased.replacement_officer?(hostile) and (hostile.level || 1) <= 1)
  end

  @doc """
  A seduction's defence as far as the Rebellion can tell: the target's
  determination, plus its system's happiness when it stands in its own
  faction's system (negative happiness lowers it; the total is floored at 0
  like the engine's). nil when a term it needs is not known.
  """
  def seduction_defence(determination, in_own_system?, happiness)
  def seduction_defence(nil, _in_own_system?, _happiness), do: nil
  def seduction_defence(determination, false, _happiness), do: max(determination, 0)
  def seduction_defence(_determination, true, nil), do: nil
  def seduction_defence(determination, true, happiness), do: max(determination + happiness, 0)

  # --- evasion ----------------------------------------------------------------------

  @doc """
  A Siderian cannot hide, so one resting on its cooldown outside rebel-held
  sectors is easy to seduce or remove; nothing intercepts it while it moves.
  True when it should keep moving.
  """
  def evade?(locked?, backline?), do: locked? and not backline?

  @doc """
  The next hop for an evading Siderian: a random neighbour, avoiding the
  system it just came from while there is any other.
  """
  def evasion_hop([], _came_from, _roll), do: nil

  def evasion_hop(neighbours, came_from, roll) do
    pool =
      case Enum.reject(neighbours, &(&1 == came_from)) do
        [] -> neighbours
        others -> others
      end
      |> Enum.sort()

    Enum.at(pool, min(trunc(roll * length(pool)), length(pool) - 1))
  end

  # --- helpers ------------------------------------------------------------------------

  defp remaining(%{penalty: penalty, at: at}, now, decay), do: max(penalty - decay * (now - at), 0.0)

  defp prune(ledger, now, decay), do: Enum.filter(ledger, &(remaining(&1, now, decay) > 0))

  defp weighted_pick(scaled, roll) do
    total = scaled |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    target = roll * total

    Enum.reduce_while(scaled, 0, fn {role, weight}, acc ->
      if target < acc + weight, do: {:halt, role}, else: {:cont, acc + weight}
    end)
    |> case do
      role when is_atom(role) -> role
      _ -> scaled |> List.last() |> elem(0)
    end
  end

  defp largest_remainder(amount, weights) do
    total = weights |> Keyword.values() |> Enum.sum()

    if total <= 0 do
      Map.new(weights, fn {role, _} -> {role, 0} end)
    else
      exact = Enum.map(weights, fn {role, weight} -> {role, amount * weight / total} end)
      floors = Map.new(exact, fn {role, value} -> {role, trunc(value)} end)
      left = amount - Enum.sum(Map.values(floors))

      exact
      |> Enum.sort_by(fn {role, value} -> {-(value - trunc(value)), role} end)
      |> Enum.take(left)
      |> Enum.reduce(floors, fn {role, _}, acc -> Map.update!(acc, role, &(&1 + 1)) end)
    end
  end
end
