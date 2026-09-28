defmodule Instance.ResourceMarket.ResourceMarket do
  @moduledoc """
  Galactic value of technology and ideology, in credits per point — a flavor
  index shown on the market panel, driven by what the factions produce.

  Every step (20 UT: one real hour on Legacy, the same share of the economy at
  every speed) each resource's price moves once:

    * target = pooled gross credit income ÷ pooled gross resource income over
      every player, times the resource's active market events;
    * gap = target − price; shift = sign(gap) × gap², capped at ±4 points;
    * roll = uniform(−5 + shift, +5 + shift) percent, applied ÷ 10: at most
      ±0.9% an hour, drifting toward the target, never jumping to it.

  Each game day (480 UT) per resource:

    * one market event scales the target by a random factor of up to ±15% in a
      two-faction match, less with more factions (15% × 2 ÷ factions), fading
      with a 240 UT half-life — something happening out in the galaxy;
    * two short shocks replace that day's move with a random ±2% jump, whatever
      the economy is doing.

  Why the noise: in a two-faction match the pooled ratio plus one's own
  incomes constrains the enemy's economy. Events can't be told apart from real
  income shifts (their moves stay inside the normal hourly window), so a
  single day of prices can't be read back into the enemy's production;
  trends over several days still show, which is the point of the index. With
  more factions each one weighs less, so events shrink and the market follows
  the players more closely. Rolls come from `:crypto`, never from a seed a
  player could reproduce (design and simulations: 2026-09-16 session on
  match 121 archive data).

  The target is never published — only prices.
  """
  use TypedStruct

  @resources [:technology, :ideology]
  @base_price 10.0
  @step_ut 20
  @day_ut 480
  @band 5.0
  @shift_cap 4.0
  @divisor 10.0
  @event_size_two_factions 0.15
  @event_half_life_ut 240
  @events_per_day 1
  @shock_size 2.0
  @shocks_per_day 2
  @report_max_age_ut 480
  @history_max 2_000

  def jason(), do: []

  typedstruct enforce: true do
    field(:instance_id, integer())
    field(:faction_count, integer())
    # accumulated game time (UT) since the market started
    field(:clock, float(), default: 0.0)
    field(:next_step, float(), default: 20.0)
    field(:step_count, integer(), default: 0)
    field(:prices, map())
    # player_id => %{faction_id, credit, technology, ideology, at}
    field(:reports, map(), default: %{})
    # resource => [%{step, size}] (events still affecting the target)
    field(:events, map())
    # resource => %{day => [step]} short-shock steps scheduled for that day
    field(:shocks, map())
    field(:scheduled_day, integer(), default: -1)
    # newest first: %{step, at (unix s), technology, ideology}
    field(:history, list(), default: [])
  end

  def new(instance_id, faction_count) do
    %__MODULE__{
      instance_id: instance_id,
      faction_count: max(faction_count, 1),
      clock: 0.0,
      next_step: @step_ut * 1.0,
      step_count: 0,
      prices: Map.new(@resources, &{&1, @base_price}),
      reports: %{},
      events: Map.new(@resources, &{&1, []}),
      shocks: Map.new(@resources, &{&1, []}),
      scheduled_day: -1,
      history: []
    }
  end

  def resources, do: @resources
  def step_ut, do: @step_ut

  @doc "Latest gross incomes (per UT) reported by a player agent."
  def report_income(%__MODULE__{} = state, player_id, faction_id, %{} = incomes) do
    report = %{
      faction_id: faction_id,
      credit: num(incomes[:credit]),
      technology: num(incomes[:technology]),
      ideology: num(incomes[:ideology]),
      at: state.clock
    }

    %{state | reports: Map.put(state.reports, player_id, report)}
  end

  @doc "Gross income of a resource DynamicValue: the sum of its positive parts."
  def gross_income(%{details: details}) when is_map(details) do
    details
    |> Map.values()
    |> List.flatten()
    |> Enum.map(fn part -> num(Map.get(part, :value)) end)
    |> Enum.filter(&(&1 > 0))
    |> Enum.sum()
  end

  def gross_income(%{change: change}), do: max(num(change), 0)
  def gross_income(_), do: 0

  @doc "UT until the next price step."
  def compute_next_tick_interval(%__MODULE__{} = state), do: max(state.next_step - state.clock, 0)

  @doc """
  Advance the market clock by `elapsed` UT, running every step that falls due.
  `rand` returns a uniform float in [0, 1).
  """
  def next_tick(%__MODULE__{} = state, elapsed, rand \\ &crypto_uniform/0) do
    state = %{state | clock: state.clock + elapsed}
    run_due_steps(state, rand)
  end

  defp run_due_steps(state, rand) do
    if state.clock + 1.0e-9 >= state.next_step do
      state
      |> step(rand)
      |> Map.put(:next_step, state.next_step + @step_ut)
      |> run_due_steps(rand)
    else
      state
    end
  end

  @doc "Pooled gross credit income ÷ pooled resource income, or nil without data."
  def target(%__MODULE__{} = state, resource) do
    fresh = fresh_reports(state)
    credits = fresh |> Enum.map(& &1.credit) |> Enum.sum()
    produced = fresh |> Enum.map(&Map.fetch!(&1, resource)) |> Enum.sum()

    if credits > 0 and produced > 0, do: credits / produced, else: nil
  end

  def event_size(%__MODULE__{faction_count: n}), do: @event_size_two_factions * 2 / max(n, 2)

  defp step(state, rand) do
    step = state.step_count
    state = schedule_day(state, step, rand)

    prices =
      Map.new(@resources, fn resource ->
        {resource, move(state, resource, step, rand)}
      end)

    point = Map.merge(%{step: step, at: System.os_time(:second)}, round_prices(prices))

    %{
      state
      | prices: prices,
        step_count: step + 1,
        events: Map.new(@resources, &{&1, live_events(state, &1, step)}),
        history: Enum.take([point | state.history], @history_max)
    }
  end

  defp move(state, resource, step, rand) do
    price = state.prices[resource]

    if step in Map.get(state.shocks, resource, []) do
      price * (1 + uniform(rand, -@shock_size, @shock_size) / 100)
    else
      case target(state, resource) do
        nil ->
          price

        base ->
          gap = base * event_factor(state, resource, step) - price
          shift = min(gap * gap, @shift_cap) * sign(gap)
          roll = uniform(rand, -@band + shift, @band + shift)
          price * (1 + roll / @divisor / 100)
      end
    end
  end

  # At the first step of each game day, draw that day's events and shocks
  # (as step indices within the day) for every resource.
  defp schedule_day(state, step, rand) do
    steps_per_day = div(@day_ut, @step_ut)
    day = div(step, steps_per_day)

    if day == state.scheduled_day do
      state
    else
      day_start = day * steps_per_day
      size = event_size(state)

      {events, shocks} =
        Enum.reduce(@resources, {state.events, state.shocks}, fn resource, {events, shocks} ->
          new_events =
            for _ <- 1..@events_per_day,
                do: %{step: day_start + pick(rand, steps_per_day), size: uniform(rand, -size, size)}

          shock_steps = Enum.map(1..@shocks_per_day, fn _ -> day_start + pick(rand, steps_per_day) end)

          {Map.put(events, resource, Map.get(events, resource, []) ++ new_events),
           Map.put(shocks, resource, shock_steps)}
        end)

      %{state | events: events, shocks: shocks, scheduled_day: day}
    end
  end

  defp event_factor(state, resource, step) do
    lambda = :math.log(2) / (@event_half_life_ut / @step_ut)

    state.events
    |> Map.get(resource, [])
    |> Enum.filter(&(&1.step <= step))
    |> Enum.reduce(1.0, fn event, acc -> acc * (1 + event.size * :math.exp(-lambda * (step - event.step))) end)
  end

  # Drop events that have faded below 0.1% of their size (10 half-lives).
  defp live_events(state, resource, step) do
    horizon = 10 * div(@event_half_life_ut, @step_ut)
    Enum.filter(Map.get(state.events, resource, []), &(&1.step > step - horizon))
  end

  defp fresh_reports(state) do
    state.reports
    |> Map.values()
    |> Enum.filter(&(state.clock - &1.at <= @report_max_age_ut))
  end

  @doc "Client view: current prices and history (oldest first). Never the target."
  def public(%__MODULE__{} = state) do
    %{
      prices: round_prices(state.prices),
      base_price: @base_price,
      step_ut: @step_ut,
      history: Enum.reverse(state.history)
    }
  end

  defp round_prices(prices), do: Map.new(prices, fn {k, v} -> {k, Float.round(v * 1.0, 3)} end)

  defp uniform(rand, lo, hi), do: lo + rand.() * (hi - lo)
  defp pick(rand, n), do: min(trunc(rand.() * n), n - 1)
  defp sign(x) when x < 0, do: -1.0
  defp sign(_), do: 1.0

  defp num(n) when is_number(n), do: n * 1.0
  defp num(_), do: 0.0

  @doc false
  def crypto_uniform do
    <<n::unsigned-integer-size(53), _::size(3)>> = :crypto.strong_rand_bytes(7)
    n / 9_007_199_254_740_992
  end
end
