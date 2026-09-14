defmodule RC.Help.Tables do
  @moduledoc """
  `{table:<generator> <args>}` generators. Each returns markdown built from
  the game content for the compile context's speed and language, so a page
  never hand-lists buildings or numbers.

  | Generator | Args | Rows |
  | --- | --- | --- |
  | `buildings_by_output` | `<sys_key>` | buildings whose bonuses target the key, level 1 → max |
  | `buildings_by_input` | `<from_key>` | buildings whose bonuses scale with the key |
  | `bonus_sources` | `<sys_key>` | lexes, traditions and agent skills targeting the key (buildings have their own table) |
  | `building_levels` | `<building_key>` | one building, all levels |
  | `constants` | `<prefix>` | `Data.Game.Constant` fields starting with the prefix |
  | `population_classes` | none | population classes, the population each starts at, victory points |
  | `population_statuses` | none | population statuses, their stability range and output penalty |

  Buildings whose biome is not a real body type (`:gate`) are never listed.
  Faction buildings, faction trees and mutators are excluded on purpose
  (beta / out of scope, see `docs/help-manual.md` §1).
  """

  import RC.Help.Format
  alias RC.Help.Data

  @body_biomes [:open, :dome, :orbital]
  @biome_class %{open: "open", dome: "dome", orbital: "orbital"}

  @generators ~w(buildings_by_output buildings_by_input bonus_sources building_levels constants)
  @no_arg_generators ~w(population_classes population_statuses speeds stellar_bodies star_types)

  def generators, do: @generators ++ @no_arg_generators

  @doc "Returns `{:ok, markdown}` or `{:error, message}`."
  def render(ctx, gen, args)

  # A system takes the first class (highest threshold first) whose threshold
  # its raw population reaches: `StellarSystem.update_population_class/1`.
  def render(ctx, "population_classes", []) do
    rows =
      Data.population_classes()
      |> Enum.sort_by(& &1.threshold)
      |> Enum.map(fn c ->
        [data_name(ctx, ["population_class", to_string(c.key)]), num(c.threshold), num(c.points)]
      end)

    # The points column uses the victory panel's own name for these points
    # ("Star System Points"); they are track points, not victory points.
    points = get_in(ctx.locale.data, ["victory", "population", "points"]) || t(ctx, :victory_points)
    {:ok, table([t(ctx, :population_class), t(ctx, :population_from), points], rows)}
  end

  # The status is the last one in content order whose threshold is at or
  # above the stability: `StellarSystem.update_population_status/3`. The top
  # status's threshold is a sentinel, so its range is shown as "above".
  def render(ctx, "population_statuses", []) do
    statuses = Data.population_statuses() |> Enum.sort_by(& &1.threshold, :desc)
    lower = statuses |> Enum.drop(1) |> Enum.map(& &1.threshold) |> Kernel.++([nil])

    rows =
      statuses
      |> Enum.zip(lower)
      |> Enum.with_index()
      |> Enum.map(fn {{s, low}, i} ->
        range =
          cond do
            i == 0 -> "> #{num(low)}"
            is_nil(low) -> "≤ #{num(s.threshold)}"
            true -> "#{num(low)} < … ≤ #{num(s.threshold)}"
          end

        penalty = if s.penalty == 0, do: "—", else: "-" <> num(round(s.penalty * 100)) <> " %"
        [data_name(ctx, ["population_status", to_string(s.key), "name"]), range, penalty]
      end)

    {:ok, table([t(ctx, :population_status), t(ctx, :stability), t(ctx, :output_penalty)], rows)}
  end

  # Body types in content order, with what galaxy generation gives each one:
  # tiles, orbiting bodies and the three potential ranges
  # (`Data.Game.StellarBody`). Mutators are excluded, as elsewhere.
  def render(ctx, "stellar_bodies", []) do
    body_name = fn key -> singular(data_name(ctx, ["stellar_body", to_string(key), "name"])) end

    rows =
      for b <- Data.stellar_bodies() do
        orbiting =
          case b.gen_subbody_number do
            %Range{first: 0, last: 0} -> "—"
            range -> "#{range_text(range)} " <> Enum.map_join(b.gen_subbody_types, ", ", body_name)
          end

        [
          body_name.(b.key),
          range_text(b.gen_tiles_number),
          orbiting,
          potential_range(b.gen_ind_factor_number),
          potential_range(b.gen_tec_factor_number),
          potential_range(b.gen_act_factor_number)
        ]
      end

    headers = [
      t(ctx, :body),
      t(ctx, :tiles),
      t(ctx, :orbiting),
      pipeline_in_name(ctx, :body_ind),
      pipeline_in_name(ctx, :body_tec),
      pipeline_in_name(ctx, :body_act)
    ]

    {:ok, table(headers, rows)}
  end

  # Star types in content order with the number of bodies a system of that
  # type is generated with (`Data.Game.StellarSystem`).
  def render(ctx, "star_types", []) do
    rows =
      for s <- Data.star_types() do
        [singular(data_name(ctx, ["stellar_system", to_string(s.key), "name"])), range_text(s.gen_body_number)]
      end

    {:ok, table([t(ctx, :star_type), t(ctx, :bodies)], rows)}
  end

  # Selectable speeds, slowest first: one tick's real length and ticks per
  # hour, from the speed factor and `Core.Tick`'s unit time.
  def render(ctx, "speeds", []) do
    rows =
      Data.speed_content()
      |> Enum.reject(&(Map.get(&1, :selectable, true) == false))
      |> Enum.sort_by(& &1.factor)
      |> Enum.map(fn s ->
        ms = Core.Tick.unit_time_divider() / s.factor

        length =
          if ms >= 60_000,
            do: "#{sig(ms / 60_000)} #{t(ctx, :minutes_short)}",
            else: "#{sig(ms / 1000)} #{t(ctx, :seconds_short)}"

        [data_name(ctx, ["speed", to_string(s.key), "name"]), length, sig(Data.ticks_per_hour(s.key))]
      end)

    {:ok, table([t(ctx, :speed), t(ctx, :tick_lasts), t(ctx, :ticks_per_hour)], rows)}
  end

  def render(_ctx, gen, args) when gen in @no_arg_generators do
    {:error, "`#{gen}` takes no arguments, got #{inspect(args)}"}
  end

  def render(ctx, "buildings_by_output", [key]) do
    with {:ok, key} <- out_key(ctx, key) do
      rows =
        for b <- listed_buildings(ctx),
            effects = level_effects(ctx, b, fn bonus -> bonus.to == key end),
            effects != [] do
          {b, effects}
        end

      {:ok, building_table(ctx, rows)}
    end
  end

  def render(ctx, "buildings_by_input", [key]) do
    with {:ok, key} <- in_key(ctx, key) do
      rows =
        for b <- listed_buildings(ctx),
            effects = level_effects(ctx, b, fn bonus -> bonus.from == key end),
            effects != [] do
          {b, effects}
        end

      {:ok, building_table(ctx, rows)}
    end
  end

  def render(ctx, "bonus_sources", [key]) do
    with {:ok, key} <- out_key(ctx, key) do
      lexes =
        for d <- Data.doctrines(ctx.speed),
            effects = Enum.filter(d.bonus, &(&1.to == key)),
            effects != [] do
          name = data_name(ctx, ["doctrine", to_string(d.key), "name"])
          [link_or_name(ctx, "lex/#{d.key}", name), t(ctx, :lex), effects(ctx, effects)]
        end

      traditions =
        for f <- Data.factions(),
            tr <- f.traditions,
            tr.bonus.to == key do
          name = data_name(ctx, ["tradition", to_string(tr.key), "name"])
          faction = data_name(ctx, ["faction", to_string(f.key), "name"])
          ["#{name} (#{faction})", t(ctx, :tradition), bonus(ctx, tr.bonus)]
        end

      skills =
        for c <- Data.characters(ctx.speed),
            spec <- c.specializations,
            effects = Enum.filter(spec.bonus, &(&1.to == key)),
            effects != [] do
          type = singular(data_name(ctx, ["character", to_string(c.key), "name"]))
          skill = get_in(ctx.locale.data, ["character", to_string(c.key), "skills", Access.at(spec.index), "name"])
          skill = skill || get_in(ctx.en.data, ["character", to_string(c.key), "skills", Access.at(spec.index), "name"])
          ["#{type} — #{skill || spec.key}", t(ctx, :skill), effects(ctx, effects)]
        end

      rows = lexes ++ traditions ++ skills
      {:ok, table([t(ctx, :source), t(ctx, :type), t(ctx, :effect)], rows) || none(ctx)}
    end
  end

  def render(ctx, "building_levels", [key]) do
    case Enum.find(listed_buildings(ctx), &(to_string(&1.key) == key)) do
      nil ->
        {:error, "unknown building `#{key}` for speed #{ctx.speed}"}

      b ->
        rows =
          for lvl <- b.levels do
            patent =
              case lvl.patent do
                nil -> "—"
                p -> data_name(ctx, ["patent", to_string(p), "name"])
              end

            [lvl.level, num(lvl.credit), num(lvl.production), patent, Enum.map_join(lvl.bonus, "; ", &bonus(ctx, &1))]
          end

        {:ok, table([t(ctx, :level), t(ctx, :credit), t(ctx, :production), t(ctx, :patent), t(ctx, :bonuses)], rows)}
    end
  end

  def render(ctx, "constants", [prefix]) do
    rows =
      Data.constants(ctx.speed)
      |> Enum.filter(fn {k, _} -> String.starts_with?(to_string(k), prefix) end)
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> ["`#{k}`", num(v)] end)

    if rows == [] do
      {:error, "no constant starts with `#{prefix}`"}
    else
      {:ok, table([t(ctx, :constant), t(ctx, :value)], rows)}
    end
  end

  def render(_ctx, gen, args) when gen in @generators do
    {:error, "`#{gen}` takes exactly one argument, got #{inspect(args)}"}
  end

  def render(_ctx, gen, _args), do: {:error, "unknown table generator `#{gen}`"}

  # -- helpers ---------------------------------------------------------------

  defp range_text(%Range{first: a, last: a}), do: "#{a}"
  defp range_text(%Range{first: a, last: b}), do: "#{a}–#{b}"

  defp potential_range(%Range{first: 0, last: 0}), do: "—"
  defp potential_range(range), do: range_text(range)

  defp listed_buildings(ctx) do
    ctx.speed
    |> Data.buildings()
    |> Enum.filter(&(&1.biome in @body_biomes))
  end

  # For every bonus of level 1 that matches, pair it with the same bonus at
  # the top level (same from/to at the same index) so the range can be shown.
  defp level_effects(ctx, building, matcher) do
    first = List.first(building.levels)
    last = List.last(building.levels)

    first.bonus
    |> Enum.with_index()
    |> Enum.filter(fn {b, _} -> matcher.(b) end)
    |> Enum.map(fn {b, i} ->
      case Enum.at(last.bonus, i) do
        %Core.Bonus{from: from, to: to} = lb when from == b.from and to == b.to -> bonus(ctx, b, lb)
        _ -> bonus(ctx, b)
      end
    end)
  end

  defp building_table(ctx, []), do: none(ctx)

  defp building_table(ctx, rows) do
    # One legend for every buildings table, so pages never type their own.
    ranged? = Enum.any?(rows, fn {_b, effects} -> Enum.any?(effects, &String.contains?(&1, "→")) end)
    legend = if ranged?, do: "\n\n_#{t(ctx, :level_range_legend)}_", else: ""

    rows =
      rows
      |> Enum.sort_by(fn {b, _} -> {Enum.find_index(@body_biomes, &(&1 == b.biome)), building_name(ctx, b)} end)
      |> Enum.map(fn {b, effects} ->
        [
          "{icon:building/#{b.key}} " <> link_or_name(ctx, "building/#{b.key}", building_name(ctx, b)),
          data_name(ctx, ["patent_class", @biome_class[b.biome], "name"]),
          Enum.join(effects, "; ")
        ]
      end)

    table([t(ctx, :building), t(ctx, :built_on), t(ctx, :effect)], rows) <> legend
  end

  defp building_name(ctx, b), do: data_name(ctx, ["building", to_string(b.key), "name"])

  defp effects(ctx, bonuses), do: Enum.map_join(bonuses, "; ", &bonus(ctx, &1))

  defp link_or_name(ctx, slug, name) do
    if Map.has_key?(ctx.index.slugs, slug), do: "[[#{slug}|#{name}]]", else: name
  end

  defp none(ctx), do: "_#{t(ctx, :none)}_"

  defp out_key(_ctx, key) do
    case Enum.find(Data.pipeline_out(), &(to_string(&1.key) == key)) do
      nil -> {:error, "unknown bonus target `#{key}` (see bonus-pipeline-out.ex)"}
      out -> {:ok, out.key}
    end
  end

  defp in_key(_ctx, key) do
    case Enum.find(Data.pipeline_in(), &(to_string(&1.key) == key)) do
      nil -> {:error, "unknown bonus input `#{key}` (see bonus-pipeline-in.ex)"}
      inp -> {:ok, inp.key}
    end
  end
end
