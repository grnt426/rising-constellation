defmodule Wave.Pressure do
  @moduledoc """
  How hard the Rebellion has leaned on each system lately, and what that does
  to its choice of targets.

  Every trade goes where its odds are best, and every strike on a system
  improves the odds of the next one there: a destabilization lowers the
  defense the next agitator rolls against and the determination a seducer
  faces, and unrest cuts the Intelligence and protection the Erased work
  against. Left alone that loop puts the whole roster on one system. On i185
  (2026-10-08 to 10-11) four systems of one sector took 50 of 51
  mass-destabilization orders while 66 of the 71 human holdings took none, and
  one of them went from happiness 36 to an estimated −71 in a day.

  Pure, like `Wave.Erased` and `Wave.Siderian`: `Wave.Warlord` keeps the
  ledger and `Wave.Warlord.Agent` reads and feeds it.

  ## Stacks

  Every order against a system another faction holds adds to that system's
  stacks: `pressure_weights`, 1 for a destabilization, a seduction, a removal,
  a sabotage or a fleet's strike (pillage, bombardment, invasion), half that
  for an infiltration, which the owner never sees unless it fails. A stack wears off in `pressure_fade_ut`, one after the
  other, so a system that took five orders in a burst is back to nothing five
  fades later.

  ## What stacks do

    * **Closed** — a system at `pressure_cap` stacks or more is no target at
      all, for any trade, until it has worn some off. That bounds what one
      system can take: a burst up to the cap, then one order per fade.
    * **Debuff** — below the cap an agent choosing a target considers the
      system with probability `pressure_falloff ^ stacks`: one roll per
      decision, shared by every candidate, as with slots
      (`Wave.Erased.admit/5`). A rested system is always considered, the most
      pressed drop out first, and an agent left with nothing does what it does
      with no target: it trains or scouts. Every trade then chooses among what
      is left the way it always did.
  """

  @default_weights %{
    "encourage_hate" => 1.0,
    "conversion" => 1.0,
    "assassination" => 1.0,
    "sabotage" => 1.0,
    "infiltrate" => 0.5,
    "loot" => 1.0,
    "raid" => 1.0,
    "conquest" => 1.0
  }

  @doc "What an order of this `action` adds to its system's stacks. Unlisted actions add nothing."
  def weight(action, weights \\ %{}) when is_binary(action) do
    case Map.get(weights || %{}, action, Map.get(@default_weights, action, 0.0)) do
      value when is_number(value) and value > 0 -> value * 1.0
      _ -> 0.0
    end
  end

  @doc """
  A ledger entry's stacks at `now`: what it held when last written, less one
  per `fade_ut` since. Never below 0; a fade of 0 or less forgets at once.
  """
  def stacks(%{stacks: stacks, at: at}, now, fade_ut)
      when is_number(stacks) and is_number(at) and is_number(now) and is_number(fade_ut) and fade_ut > 0,
      do: max(stacks - max(now - at, 0.0) / fade_ut, 0.0)

  def stacks(_entry, _now, _fade_ut), do: 0.0

  @doc "The entry after one more order of `weight` at `now`."
  def add(entry, weight, now, fade_ut) when is_number(weight) and is_number(now),
    do: %{stacks: stacks(entry, now, fade_ut) + weight, at: now * 1.0}

  @doc "The ledger without the entries that have worn off entirely."
  def prune(ledger, now, fade_ut) when is_map(ledger),
    do: Map.filter(ledger, fn {_system_id, entry} -> stacks(entry, now, fade_ut) > 0 end)

  @doc "True while a system may still be targeted: below `cap` stacks. No cap (nil) never closes."
  def open?(stacks, cap) when is_number(stacks) and is_number(cap), do: stacks < cap
  def open?(_stacks, _cap), do: true

  @doc "What a system at `stacks` still counts for: `falloff ^ stacks`, 1 with none."
  def debuff(stacks, falloff) when is_number(stacks) and is_number(falloff),
    do: :math.pow(falloff |> max(0.0) |> min(1.0), max(stacks, 0.0))

  def debuff(_stacks, _falloff), do: 1.0

  @doc """
  The candidates an agent still considers. `stacks` answers the stacks on a
  candidate's system. A system at `cap` is closed; below it one passes when
  `debuff > roll`, so with one `roll` for the whole list a rested system is
  always in and the most pressed are the first out.
  """
  def admit(candidates, stacks, roll, falloff, cap) when is_function(stacks, 1) and is_number(roll) do
    Enum.filter(candidates, fn candidate ->
      held = stacks.(candidate)
      open?(held, cap) and debuff(held, falloff) > roll
    end)
  end
end
