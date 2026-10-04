defmodule SystemAI.Weights do
  @moduledoc """
  How well a building suits the body it would stand on, as a multiplier on its
  lots in the build draw. Pure.

  A building's output scales with whatever its bonuses read from
  (`Core.Bonus.from`): a potential of the body, the body's population, the
  system's mobility, or nothing at all (`:direct`). The vanilla draw ignores
  that, so a Zero-G Arena (appeal) and an Experiment Station (science) are
  equally likely on an asteroid with science 5 and appeal 1.

    * **Potentials** (`body_ind`, `body_tec`, `body_act`): lots proportional to
      the potential, half a share per point — ×0.5 at 1, ×1 at 2, ×2.5 at 5.
    * **Population and mobility** (`body_pop`, `sys_pop`, `sys_mobility`): a
      saturating curve around the value at which the building starts to pay,
      ×0.2 at two thirds of it and below, ×1 at it, ×1.3 at four thirds, and
      never more than ×1.5. A planet pays from 15 population, a system's
      mobility from 40.
    * **Flat bonuses** (`direct`, and anything else): ×1, unless the body's
      `opportunity` is given. A flat building pays the same anywhere, so its
      best place is where it displaces the least: a body whose potentials are
      all low, or one whose good potential is already used. `opportunity` is
      the best multiplier a scaling building could still get on the body
      (`opportunity/3`), and a flat bonus gets ×2 at 1 and below, ×1 at 1.5
      (a potential of 3 still open), ×0.5 at 2, ×0.25 at 2.5.

  A building with several bonuses gets the mean of their multipliers.
  Penalties (negative bonuses) do not count: they say what the building
  costs, not what it scales with.

  An `emphasis` map (`%{sys_mobility: 0.5}`) scales single bonuses by what
  they produce, for a system type that wants less of something.
  """

  @per_point 0.5

  @low 0.2
  @high 1.5

  @body_pop_even 15.0
  @sys_pop_even 30.0
  @mobility_even 40.0

  # A flat bonus is neutral when the best scaling alternative is a potential of 3.
  @flat_even 1.5
  @flat_best 2.0

  @scaling [:body_ind, :body_tec, :body_act, :body_pop, :sys_pop, :sys_mobility]

  @doc """
  The lots multiplier of `building` (a `Data.Game.Building`) on `body` in
  `system`. Options: `opportunity` (see `opportunity/3`) places flat bonuses
  by what they would displace, nil leaving them at x1; `emphasis` maps a
  bonus target to a multiplier for it.
  """
  def building(building, body, system, opts \\ []) do
    opportunity = Keyword.get(opts, :opportunity)
    emphasis = Keyword.get(opts, :emphasis, %{})

    building
    |> gains()
    |> Enum.map(fn {from, to} ->
      multiplier = if from in @scaling, do: source(from, body, system), else: flat(opportunity)
      multiplier * Map.get(emphasis, to, 1.0)
    end)
    |> mean()
  end

  @doc "True when nothing the building gives scales with anything: it pays the same anywhere."
  def flat?(building), do: not Enum.any?(gains(building), fn {from, _to} -> from in @scaling end)

  @doc "The multiplier of the building's scaling bonuses alone, or nil when it has none."
  def scaled(building, body, system) do
    case for {from, _to} <- gains(building), from in @scaling, do: from do
      [] -> nil
      sources -> sources |> Enum.map(&source(&1, body, system)) |> mean()
    end
  end

  @doc """
  The best multiplier any of `buildings` (the ones still buildable on `body`)
  would get from what it scales with: what a flat building there gives up. 0
  when none of them scales with anything.
  """
  def opportunity(buildings, body, system) do
    buildings
    |> Enum.map(&scaled(&1, body, system))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0.0 end)
  end

  @doc "The multiplier of a flat bonus on a body with that `opportunity`."
  def flat(nil), do: 1.0

  def flat(opportunity) when is_number(opportunity),
    do: min(@flat_best, :math.pow(2, 2 * (@flat_even - opportunity)))

  @doc "The multiplier for one thing a scaling bonus reads from."
  def source(:body_ind, body, _system), do: potential(Map.get(body, :industrial_factor))
  def source(:body_tec, body, _system), do: potential(Map.get(body, :technological_factor))
  def source(:body_act, body, _system), do: potential(Map.get(body, :activity_factor))
  def source(:body_pop, body, _system), do: saturating(Map.get(body, :population) || 0, @body_pop_even)
  def source(:sys_pop, _body, system), do: saturating(value(system.population), @sys_pop_even)
  def source(:sys_mobility, _body, system), do: saturating(value(system.mobility), @mobility_even)
  def source(_flat, _body, _system), do: 1.0

  @doc "Half a share of lots per point of potential; a hidden potential counts as average."
  def potential(points) when is_number(points), do: max(points, 0) * @per_point
  def potential(_hidden), do: 1.0

  @doc """
  The curve for inputs that have to reach a size before a building pays:
  `even` is that size. Flat at the floor up to two thirds of it, 1 at it,
  then flattening toward the ceiling.
  """
  def saturating(x, even) when is_number(x) and is_number(even) and even > 0 do
    start = even * 2 / 3

    if x <= start do
      @low
    else
      # Chosen so the curve passes through 1 at `even`.
      rate = :math.log((@high - @low) / (@high - 1.0)) / (even - start)
      @high - (@high - @low) * :math.exp(-rate * (x - start))
    end
  end

  def saturating(_x, _even), do: 1.0

  # Each of the building's level-1 gains, as what it reads from and what it feeds.
  defp gains(%{levels: levels}) do
    case Enum.find(levels, &(&1.level == 1)) do
      nil -> []
      level -> for bonus <- level.bonus, is_number(bonus.value) and bonus.value > 0, do: {bonus.from, bonus.to}
    end
  end

  defp value(%{value: value}) when is_number(value), do: value
  defp value(value) when is_number(value), do: value
  defp value(_), do: 0

  defp mean([]), do: 1.0
  defp mean(values), do: Enum.sum(values) / length(values)
end
