defmodule RC.Help.Format do
  @moduledoc """
  Number, bonus and header formatting shared by the token expander and the
  table generators. All user-visible names come from the locale maps in the
  compile context (`ctx.locale`, falling back to `ctx.en`); the handful of
  table headers the manual needs itself live in `@strings`.
  """

  @strings %{
    "en" => %{
      building: "Building",
      built_on: "Built on",
      effect: "Effect",
      source: "Source",
      type: "Type",
      lex: "Lex",
      tradition: "Tradition",
      skill: "Agent skill",
      constant: "Constant",
      value: "Value",
      level: "Level",
      credit: "Credit",
      production: "Production",
      patent: "Patent",
      bonuses: "Bonuses",
      none: "None",
      per: "per",
      missing_table: "missing table",
      population_class: "Class",
      population_from: "From population",
      victory_points: "Victory points",
      population_status: "Status",
      stability: "Stability",
      output_penalty: "Output penalty",
      level_range_legend: "An effect with an arrow runs from the building's first level to its top level.",
      body: "Body",
      tiles: "Tiles",
      orbiting: "Orbiting bodies",
      star_type: "Star type",
      bodies: "Bodies",
      per_tick: "per tick",
      per_hour: "per hour",
      tick: "tick",
      ticks: "ticks",
      hour: "hour",
      hours: "hours",
      speed: "Speed",
      tick_lasts: "One tick lasts",
      ticks_per_hour: "Ticks per hour",
      minutes_short: "min",
      seconds_short: "s",
      part_of: "Part of the %{link} guide",
      guide_pages: "Pages in this guide",
      chart_population: "Population",
      chart_stability: "stability",
      chart_target: "growth target (housing + 0.75)",
      chart_growth_caption:
        "Population of a new colony over time, with %{housing} housing. Each line adds a different amount of stability from buildings, Lexes and agents.",
      chart_growth_aria: "Line chart of population over time for a new colony"
    },
    "fr" => %{
      building: "Bâtiment",
      built_on: "Construit sur",
      effect: "Effet",
      source: "Source",
      type: "Type",
      lex: "Lex",
      tradition: "Tradition",
      skill: "Compétence d'agent",
      constant: "Constante",
      value: "Valeur",
      level: "Niveau",
      credit: "Crédit",
      production: "Production",
      patent: "Brevet",
      bonuses: "Bonus",
      none: "Aucun",
      per: "par",
      missing_table: "table manquante",
      population_class: "Classe",
      population_from: "À partir de population",
      victory_points: "Points de victoire",
      population_status: "Statut",
      stability: "Stabilité",
      output_penalty: "Pénalité de production",
      level_range_legend: "Un effet avec une flèche va du premier niveau du bâtiment à son niveau maximum.",
      body: "Corps",
      tiles: "Cases",
      orbiting: "Corps en orbite",
      star_type: "Type d'étoile",
      bodies: "Corps célestes",
      per_tick: "par tick",
      per_hour: "par heure",
      tick: "tick",
      ticks: "ticks",
      hour: "heure",
      hours: "heures",
      speed: "Vitesse",
      tick_lasts: "Un tick dure",
      ticks_per_hour: "Ticks par heure",
      minutes_short: "min",
      seconds_short: "s",
      part_of: "Fait partie du guide %{link}",
      guide_pages: "Pages de ce guide",
      chart_population: "Population",
      chart_stability: "stabilité",
      chart_target: "cible de croissance (habitation + 0,75)",
      chart_growth_caption:
        "Population d'une nouvelle colonie au fil du temps, avec %{housing} d'habitation. Chaque courbe ajoute une stabilité différente venant des bâtiments, des Lex et des agents.",
      chart_growth_aria: "Courbe de population d'une nouvelle colonie au fil du temps"
    }
  }

  def t(ctx, key) do
    get_in(@strings, [ctx.lang, key]) || get_in(@strings, ["en", key]) || Atom.to_string(key)
  end

  @doc "Compact number: integers as-is, floats with up to two decimals."
  def num(n) when is_integer(n), do: Integer.to_string(n)

  def num(n) when is_float(n) do
    if n == trunc(n) do
      Integer.to_string(trunc(n))
    else
      n |> Float.round(2) |> :erlang.float_to_binary(decimals: 2) |> String.trim_trailing("0")
    end
  end

  def num(other), do: to_string(other)

  @doc """
  Number for rates and chart labels, which can be small: `0.002` stays
  `0.002`, `7.5` stays `7.5`, `40.0` becomes `40`.
  """
  def sig(n) when is_integer(n), do: Integer.to_string(n)

  def sig(n) when is_float(n) do
    cond do
      n == trunc(n) -> Integer.to_string(trunc(n))
      abs(n) >= 100 -> decimals(n, 1)
      abs(n) >= 1 -> decimals(n, 2)
      true -> decimals(n, 4)
    end
  end

  defp decimals(n, d) do
    n
    |> Float.round(d)
    |> :erlang.float_to_binary(decimals: d)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  def signed(n) when is_number(n) and n >= 0, do: "+" <> num(n)
  def signed(n) when is_number(n), do: "-" <> num(abs(n))

  def pct(v) when is_number(v), do: signed(round_pct(v)) <> " %"

  defp round_pct(v) do
    p = v * 100
    if p == trunc(p), do: trunc(p), else: Float.round(p * 1.0, 1)
  end

  @doc """
  Localized name from `data.json` (`path` is a list under the `"data"`
  object). Falls back to English, then to the last path segment.
  """
  def data_name(ctx, path) do
    get_in(ctx.locale.data, path) || get_in(ctx.en.data, path) || List.last(path)
  end

  def has_data_key?(ctx, path), do: not is_nil(get_in(ctx.en.data, path))

  @doc "Localized UI string from `game.json` (dotted path)."
  def ui(ctx, dotted) do
    path = String.split(dotted, ".")
    get_in(ctx.locale.game, path) || get_in(ctx.en.game, path)
  end

  @doc ~S(`"Navarch | Navarchs"` → `"Navarch"`.)
  def singular(name) when is_binary(name), do: name |> String.split("|") |> hd() |> String.trim()
  def singular(other), do: other

  def pipeline_in_name(ctx, key), do: data_name(ctx, ["bonus_pipeline_in", to_string(key), "name"])
  def pipeline_out_name(ctx, key), do: data_name(ctx, ["bonus_pipeline_out", to_string(key), "name"])

  @doc """
  One bonus as text. `last` is the same bonus at the building's top level,
  when there is one, which turns `+1.6 Mobility` into `+1.6 → +8 Mobility`.

  - `from: :direct`          → `+10 Housing`
  - `from == to` (multiplier) → `+25 % Defense`
  - otherwise                 → `+2.8 Production per Industrial Potential`
  """
  def bonus(ctx, %Core.Bonus{} = b, last \\ nil) do
    to_name = pipeline_out_name(ctx, b.to)

    cond do
      # The dominion tax rate is a share (0.3 = 30 %), so its flat bonuses read as percents.
      b.from == :direct and b.to == :dominion_rate ->
        "#{range(b.value, last && last.value, &pct/1)} #{to_name}"

      b.from == :direct ->
        "#{range(b.value, last && last.value, &signed/1)} #{to_name}"

      b.from == b.to and b.type == :mul ->
        "#{range(b.value, last && last.value, &pct/1)} #{to_name}"

      true ->
        "#{range(b.value, last && last.value, &signed/1)} #{to_name} #{t(ctx, :per)} #{pipeline_in_name(ctx, b.from)}"
    end
  end

  defp range(v, nil, fmt), do: fmt.(v)
  defp range(v, v2, fmt) when v == v2, do: fmt.(v)
  defp range(v, v2, fmt), do: "#{fmt.(v)} → #{fmt.(v2)}"

  @doc "Escape a value for a markdown table cell."
  def cell(text), do: text |> to_string() |> String.replace("|", "\\|") |> String.replace("\n", " ")

  @doc "Render a markdown table from header cells and row lists."
  def table(_headers, []), do: nil

  def table(headers, rows) do
    line = fn cells -> "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |" end
    sep = "|" <> String.duplicate(" --- |", length(headers))
    Enum.join([line.(headers), sep | Enum.map(rows, line)], "\n")
  end
end
