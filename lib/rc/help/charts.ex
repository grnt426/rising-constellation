defmodule RC.Help.Charts do
  @moduledoc """
  `{chart:<name> key=value …}` generators. A chart simulates a mechanic with
  the game's own functions, for the compile context's speed, and returns two
  SVG variants: one with the time axis in ticks and one in hours. The
  surfaces show one of them depending on the reader's unit (see the
  `help-unit-tick` / `help-unit-hour` classes in `RC.Help.Compiler`).

  | Chart | Args | Shows |
  | --- | --- | --- |
  | `population_growth` | `housing=40 bonus=0,20,40` | population of a new colony over time, one line per extra stability |

  Styling hooks (no colors in the SVG): `help-chart-svg`, `help-chart-grid`,
  `help-chart-axis`, `help-chart-label`, `help-chart-line s0…s3`,
  `help-chart-legend`, `help-chart-ref`.
  """

  import RC.Help.Format
  alias RC.Help.Data
  alias Instance.StellarSystem.StellarSystem

  @charts ~w(population_growth)
  @w 640
  @h 320
  @ml 52
  @mr 16
  @mt 16
  @mb 44
  @sim_ticks 8_000
  @max_series 4

  def charts, do: @charts

  @doc "Returns `{:ok, %{tick: svg, hour: svg, caption: text}}` or `{:error, message}`."
  def render(ctx, name, args)

  def render(ctx, "population_growth", args) do
    with {:ok, opts} <- parse_args(args, %{"housing" => "40", "bonus" => "0,20,40"}),
         {:ok, [housing]} <- numbers(opts["housing"], "housing"),
         {:ok, bonuses} <- numbers(opts["bonus"], "bonus"),
         :ok <- series_count(bonuses) do
      c = Data.constants(ctx.speed)
      target = housing + 0.75

      runs = Enum.map(bonuses, fn b -> {b, simulate(housing, b, c)} end)

      horizon =
        runs
        |> Enum.map(fn {_, pops} -> settle_tick(pops) end)
        |> Enum.max()
        |> Kernel.*(1.15)
        |> max(20)

      y_raw = runs |> Enum.flat_map(fn {_, pops} -> Tuple.to_list(pops) end) |> Enum.max() |> max(target) |> Kernel.*(1.08)

      series =
        Enum.map(runs, fn {b, pops} ->
          %{label: "#{signed(b)} #{t(ctx, :chart_stability)}", points: sample(pops, horizon)}
        end)

      base = %{
        y_title: t(ctx, :chart_population),
        y_raw: y_raw,
        refs: [{target, t(ctx, :chart_target)}],
        aria: "#{t(ctx, :chart_growth_aria)} (#{sig(housing)}, #{Enum.map_join(bonuses, ", ", &signed/1)})"
      }

      tph = Data.ticks_per_hour(ctx.speed)

      {:ok,
       %{
         tick: svg(series, Map.merge(base, %{x_raw: horizon, x_scale: 1, x_title: t(ctx, :ticks)})),
         hour: svg(series, Map.merge(base, %{x_raw: horizon / tph, x_scale: 1 / tph, x_title: t(ctx, :hours)})),
         caption: String.replace(t(ctx, :chart_growth_caption), "%{housing}", sig(housing))
       }}
    else
      {:ok, [_ | _]} -> {:error, "`housing` takes a single number"}
      {:error, _} = error -> error
    end
  end

  def render(_ctx, name, _args), do: {:error, "unknown chart `#{name}` (known: #{Enum.join(@charts, ", ")})"}

  # -- population simulation --------------------------------------------------

  # One tick at a time from a new colony, with stability = base + bonus +
  # per-population change × workforce, the way the system recomputes it.
  defp simulate(housing, bonus, c) do
    Enum.reduce(1..@sim_ticks, [c.system_starting_population * 1.0], fn _, [pop | _] = acc ->
      happiness = c.system_base_happiness + bonus + c.system_population_negative_happiness_factor * Float.floor(pop)
      growth = StellarSystem.population_growth(housing, pop, happiness, c.system_base_growth)
      [max(pop + growth, 0.0) | acc]
    end)
    |> Enum.reverse()
    |> List.to_tuple()
  end

  # First tick after which the population stays within half a point of where
  # the simulation ends.
  defp settle_tick(pops) do
    last = elem(pops, tuple_size(pops) - 1)

    (tuple_size(pops) - 1)..0//-1
    |> Enum.find(fn i -> abs(elem(pops, i) - last) >= 0.5 end)
    |> case do
      nil -> 0
      i -> i + 1
    end
  end

  defp sample(pops, horizon) do
    last = min(ceil(horizon), tuple_size(pops) - 1)
    step = max(div(last, 160), 1)
    for i <- Enum.uniq(Enum.to_list(0..last//step) ++ [last]), do: {i, elem(pops, i)}
  end

  # -- args -------------------------------------------------------------------

  defp parse_args(args, defaults) do
    Enum.reduce_while(args, {:ok, defaults}, fn arg, {:ok, acc} ->
      case String.split(arg, "=", parts: 2) do
        [k, v] when is_map_key(defaults, k) -> {:cont, {:ok, Map.put(acc, k, v)}}
        _ -> {:halt, {:error, "unknown chart argument `#{arg}` (known: #{defaults |> Map.keys() |> Enum.join(", ")})"}}
      end
    end)
  end

  defp numbers(value, key) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn s, {:ok, acc} ->
      case Float.parse(String.trim(s)) do
        {n, ""} -> {:cont, {:ok, acc ++ [if(n == trunc(n), do: trunc(n), else: n)]}}
        _ -> {:halt, {:error, "`#{key}` must be numbers, got `#{value}`"}}
      end
    end)
  end

  defp series_count(list) when length(list) in 1..@max_series, do: :ok
  defp series_count(_), do: {:error, "a chart takes 1 to #{@max_series} series"}

  # -- svg --------------------------------------------------------------------

  defp svg(series, %{x_raw: x_raw, x_scale: x_scale, y_raw: y_raw} = o) do
    pw = @w - @ml - @mr
    ph = @h - @mt - @mb
    {x_max, x_step} = nice_axis(x_raw)
    {y_max, y_step} = nice_axis(y_raw)
    sx = fn x -> @ml + x / x_max * pw end
    sy = fn y -> @mt + ph - y / y_max * ph end
    xs = axis_ticks(x_max, x_step)
    ys = axis_ticks(y_max, y_step)

    grid =
      Enum.map(ys, &line(@ml, sy.(&1), @ml + pw, sy.(&1))) ++
        Enum.map(xs, &line(sx.(&1), @mt, sx.(&1), @mt + ph))

    axis =
      [line(@ml, @mt + ph, @ml + pw, @mt + ph), line(@ml, @mt, @ml, @mt + ph)] ++
        Enum.map(xs, &label(sx.(&1), @mt + ph + 16, sig(&1), "middle")) ++
        Enum.map(ys, &label(@ml - 6, sy.(&1) + 4, sig(&1), "end")) ++
        [
          label(@ml + pw / 2, @h - 6, o.x_title, "middle"),
          ~s[<text class="help-chart-label" text-anchor="middle" transform="translate(14 #{f(@mt + ph / 2)}) rotate(-90)">#{esc(o.y_title)}</text>]
        ]

    refs =
      Enum.map(o.refs, fn {y, text} ->
        ~s(<line class="help-chart-ref" x1="#{f(@ml)}" y1="#{f(sy.(y))}" x2="#{f(@ml + pw)}" y2="#{f(sy.(y))}" stroke="currentColor" stroke-opacity="0.45" stroke-dasharray="6 4"/>) <>
          label(@ml + 6, sy.(y) - 5, text, "start")
      end)

    lines =
      series
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        pts = Enum.map_join(s.points, " ", fn {x, y} -> "#{f(sx.(x * x_scale))},#{f(sy.(y))}" end)
        ~s(<polyline class="help-chart-line s#{i}" fill="none" points="#{pts}"/>)
      end)

    n = length(series)

    legend =
      series
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        y = @mt + ph - 14 - (n - 1 - i) * 18
        x = @ml + pw - 150

        ~s(<line class="help-chart-line s#{i}" x1="#{f(x)}" y1="#{f(y)}" x2="#{f(x + 22)}" y2="#{f(y)}"/>) <>
          label(x + 28, y + 4, s.label, "start")
      end)

    ~s(<svg class="help-chart-svg" viewBox="0 0 #{@w} #{@h}" role="img" aria-label="#{esc(o.aria)}">) <>
      ~s(<g class="help-chart-grid">#{Enum.join(grid)}</g>) <>
      ~s(<g class="help-chart-axis">#{Enum.join(axis)}</g>) <>
      Enum.join(refs) <>
      Enum.join(lines) <>
      ~s(<g class="help-chart-legend">#{Enum.join(legend)}</g>) <>
      "</svg>"
  end

  defp nice_axis(raw) when raw <= 0, do: {1, 0.2}

  defp nice_axis(raw) do
    rough = raw / 5
    mag = :math.pow(10, Float.floor(:math.log10(rough)))

    step =
      case rough / mag do
        n when n <= 1 -> mag
        n when n <= 2 -> 2 * mag
        n when n <= 5 -> 5 * mag
        _ -> 10 * mag
      end

    step = if step == trunc(step), do: trunc(step), else: step
    {Float.ceil(raw / step) * step |> tidy(), step}
  end

  defp axis_ticks(max, step) do
    count = round(max / step)
    for i <- 0..count, do: tidy(i * step)
  end

  defp tidy(n) when is_float(n), do: if(n == trunc(n), do: trunc(n), else: Float.round(n, 6))
  defp tidy(n), do: n

  defp line(x1, y1, x2, y2), do: ~s(<line x1="#{f(x1)}" y1="#{f(y1)}" x2="#{f(x2)}" y2="#{f(y2)}"/>)

  defp label(x, y, text, anchor),
    do: ~s(<text class="help-chart-label" x="#{f(x)}" y="#{f(y)}" text-anchor="#{anchor}">#{esc(text)}</text>)

  defp f(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)

  defp esc(s), do: s |> to_string() |> Plug.HTML.html_escape()
end
