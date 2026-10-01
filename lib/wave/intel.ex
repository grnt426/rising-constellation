defmodule Wave.Intel do
  @moduledoc """
  What the Rebellion knows, and what it makes of it.

  Two jobs, both pure:

    * **Visibility** — how much of a system the Rebellion can actually see
      (`Instance.Faction.Faction.resolve_system_visibility/2`), reproduced here
      from the faction's stored contacts so a target can be judged without
      reading its system agent. `visible/3` then answers whether a given field
      is legible at that level, using the same tiers the engine's obfuscators
      use (`Instance.StellarSystem.Character.obfuscate/2`,
      `Instance.Character.Tile.obfuscate/2`).

    * **Odds** — a mirror of `Core.Dice`, so the Warlord can weigh an attack
      before ordering it the way a human weighs the client's action preview.
      `Core.Dice.roll/4` draws uniformly from `[lo, hi]` and calls anything
      from 0.5 up a success, so the success chance is the share of that band
      above 0.5 — an exact number, not an estimate.

  The Erased use the odds to gate removals: an unknown defence is a blind
  20% gamble, a known one is a steep curve around an even chance
  (`attempt_chance/2`). Nothing here performs I/O; `Wave.Recon` supplies the
  readings.
  """

  @uncertainty 0.20
  @level_cap 20
  @success_at 0.5

  # Visibility tiers, from the engine's own obfuscators.
  @tiers %{
    # StellarSystem.Character.obfuscate/2
    identity: 2,
    determination: 4,
    protection: 5,
    cover: 6,
    # Character.Tile.obfuscate/2 — a filled tile's ship key
    ship_keys: 4,
    # Faction.StellarSystem.obfuscate/4 — happiness at 3, counter-intelligence at 4
    happiness: 3,
    counter_intelligence: 4
  }

  @doc "True when `field` is legible at `visibility`. Unknown fields are never legible."
  def visible?(field, visibility) when is_integer(visibility) do
    case Map.fetch(@tiers, field) do
      {:ok, tier} -> visibility >= tier
      :error -> false
    end
  end

  def visible?(_field, _visibility), do: false

  @doc """
  The Rebellion's resolved visibility of one system, from data cheap to hold:

    * `contact` — the stored contact value for the system (informers,
      explorers), 0 when the faction has none;
    * `own_system?` — the Rebellion owns the system or holds it as a dominion;
    * `own_agent?` — a Rebellion character stands in it;
    * `stance` — the diplomatic stance toward the system's owner
      (`:war` fogs by one, `:non_aggression` opens by one, anything else is
      neutral). Ignored on the Rebellion's own systems.

  Mirrors `Instance.Faction.Faction.resolve_system_visibility/2`, which is the
  value the engine's obfuscators are keyed on.
  """
  def visibility(contact, opts \\ []) do
    own_system? = Keyword.get(opts, :own_system?, false)
    own_agent? = Keyword.get(opts, :own_agent?, false)

    value =
      (contact || 0)
      |> then(&if(own_agent?, do: max(&1, 2), else: &1))
      |> then(&if(own_system?, do: max(&1, 5), else: &1))

    cond do
      own_system? -> value
      Keyword.get(opts, :stance) == :war -> max(value - 1, 0)
      Keyword.get(opts, :stance) == :non_aggression -> min(value + 1, 5)
      true -> value
    end
  end

  @doc """
  The probability band `Core.Dice.roll/4` would draw from: the attacker's
  ratio, widened by the uncertainty range and shifted up by the attacker's
  level (a hundredth per level, capped at 20).
  """
  def band(attack, level, defense) when is_number(attack) and is_number(level) and is_number(defense) do
    ratio = ratio(attack, defense)
    lo = max(ratio - @uncertainty + 0.01 * min(level, @level_cap), 0)
    hi = min(ratio + @uncertainty, 1)
    {lo, max(hi, lo)}
  end

  defp ratio(attack, defense) when attack + defense > 0, do: attack / (attack + defense)
  defp ratio(_attack, _defense), do: 0.5

  @doc """
  The chance an attack succeeds: the share of its band at or above 0.5, which
  is where `Core.Dice` stops calling the roll a failure. A band entirely below
  0.5 is a certain failure, one entirely above it a certain success.
  """
  def success_chance(attack, level, defense) do
    {lo, hi} = band(attack, level, defense)

    cond do
      hi <= lo -> if lo >= @success_at, do: 1.0, else: 0.0
      true -> ((hi - @success_at) / (hi - lo)) |> min(1.0) |> max(0.0)
    end
  end

  @doc """
  How likely the Rebellion is to actually go through with an attack.

  `chance` is `success_chance/3`, or `nil` when the defence can't be seen. An
  unseen defence is a flat gamble (`unknown`); a seen one runs through a
  logistic centred on `midpoint`, so the appetite climbs steeply once the
  median outcome crosses a coin flip and all but vanishes below it.

  `knobs` takes `%{"unknown" => 0.2, "steepness" => 12.0, "midpoint" => 0.5}`.
  """
  def attempt_chance(chance, knobs \\ %{})

  def attempt_chance(nil, knobs), do: clamp(number(knobs, "unknown", 0.2))

  def attempt_chance(chance, knobs) when is_number(chance) do
    steepness = number(knobs, "steepness", 12.0)
    midpoint = number(knobs, "midpoint", 0.5)

    clamp(1.0 / (1.0 + :math.exp(-steepness * (chance - midpoint))))
  end

  def attempt_chance(_chance, knobs), do: attempt_chance(nil, knobs)

  @doc "Coarse label for a chance, for the logs: `:unknown`, `:poor`, `:even` or `:good`."
  def odds_class(nil), do: :unknown
  def odds_class(chance) when is_number(chance) and chance < 0.35, do: :poor
  def odds_class(chance) when is_number(chance) and chance < 0.65, do: :even
  def odds_class(chance) when is_number(chance), do: :good
  def odds_class(_chance), do: :unknown

  # Knob maps round-trip through jsonb, so they arrive with string keys — but a
  # map built in a test may still use atoms. Match on the printed key rather
  # than interning one.
  defp number(knobs, key, default) when is_map(knobs) do
    Enum.find_value(knobs, default, fn
      {k, value} when is_number(value) -> if to_string(k) == key, do: value * 1.0
      _ -> nil
    end)
  end

  defp number(_knobs, _key, default), do: default

  defp clamp(value), do: value |> max(0.0) |> min(1.0)
end
