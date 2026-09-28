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
      advanced: "Advanced mechanics",
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
      chart_growth_aria: "Line chart of population over time for a new colony",
      levels: "Levels",
      level_n: "%{name} level %{n}",
      requires: "Requires",
      effects: "Effects",
      credit_cost: "Credit cost",
      production_cost: "Production cost",
      unlocking: "Unlocking",
      unlocked_by: "Unlocked by",
      max_level: "Levels",
      workforce: "Workforce",
      ships_built_here: "Ships built here",
      not_at_speed: "This building is not in %{speed} games.",
      no_patent: "No patent is needed to build it.",
      unlocked_by_patent: "Unlocked by the patent %{patent}.",
      patent_path: "A patent can only be bought once the one above it is owned. Its path from the root of the patent tree:",
      patent_root: "This patent is a root of the patent tree, so it needs no other patent.",
      shipyard_intro: "Ships of these classes can only be ordered in a system where this building is finished and not damaged:",
      per_tick_legend: "Production, credit, technology, ideology and upkeep amounts are per tick.",
      per_hour_legend: "Production, credit, technology, ideology and upkeep amounts are per hour.",
      limit_link: "What Unique and Limited mean",
      limit: "Limit",
      sieges: "Sieges",
      siege_weight: "Twice as likely to be damaged as most buildings",
      levels_intro: "Every level above 1 is an upgrade. See %{link} for what the requirements mean.",
      buildings_guide: "Buildings"
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
      advanced: "Mécanismes avancés",
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
      chart_growth_aria: "Courbe de population d'une nouvelle colonie au fil du temps",
      levels: "Niveaux",
      level_n: "%{name} niveau %{n}",
      requires: "Nécessite",
      effects: "Effets",
      credit_cost: "Coût en crédit",
      production_cost: "Coût en production",
      unlocking: "Déblocage",
      unlocked_by: "Débloqué par",
      max_level: "Niveaux",
      workforce: "Main-d'œuvre",
      ships_built_here: "Vaisseaux construits ici",
      not_at_speed: "Ce bâtiment n'existe pas dans les parties %{speed}.",
      no_patent: "Aucun brevet n'est nécessaire pour le construire.",
      unlocked_by_patent: "Débloqué par le brevet %{patent}.",
      patent_path:
        "Un brevet ne peut être acheté qu'une fois celui du dessus acquis. Son chemin depuis la racine de l'arbre des brevets :",
      patent_root: "Ce brevet est une racine de l'arbre des brevets : il ne nécessite aucun autre brevet.",
      shipyard_intro:
        "Les vaisseaux de ces classes ne peuvent être commandés que dans un système où ce bâtiment est terminé et intact :",
      per_tick_legend: "Les montants de production, crédit, technologie, idéologie et entretien sont par tick.",
      per_hour_legend: "Les montants de production, crédit, technologie, idéologie et entretien sont par heure.",
      limit_link: "Ce que signifient Unique et Limité",
      limit: "Limite",
      sieges: "Sièges",
      siege_weight: "Deux fois plus souvent endommagé que la plupart des bâtiments",
      levels_intro: "Chaque niveau au-delà du premier est une amélioration. Voir %{link} pour ce que signifient les prérequis.",
      buildings_guide: "Bâtiments"
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
  A whole amount with its thousands grouped the way the language writes them,
  as the in-game cards do: `462,000` (en), `462 000` (fr, no-break space).
  Anything that is not a whole number falls back to `num/1`.
  """
  def grouped(ctx, n) when is_integer(n) or (is_float(n) and n == trunc(n)) do
    sep = if ctx.lang == "fr", do: " ", else: ","
    digits = n |> trunc() |> abs() |> Integer.to_string()
    body = digits |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1#{sep}") |> String.reverse()
    if n < 0, do: "-" <> body, else: body
  end

  def grouped(_ctx, n), do: num(n)

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

  # Bonus targets whose flat and per-input values are amounts per tick. The
  # in-game cards convert exactly these to per hour (`isIncomeBonus` in
  # CardComplexBonus.vue); every other target is a level (housing, stability,
  # defense…) and stays as it is.
  @per_tick_targets [
    :sys_production,
    :sys_technology,
    :sys_ideology,
    :sys_credit,
    :player_credit,
    :player_technology,
    :player_ideology,
    :army_maintenance
  ]

  @doc "Whether a bonus target's values are amounts per tick (so they follow the reader's unit)."
  def per_tick_target?(to), do: to in @per_tick_targets

  @doc """
  A per-tick amount as the in-game cards show it per hour: times the speed's
  ticks per hour, rounded to one decimal, `k` from 100 000, and marked `/h`
  (`income` in front/src/utils/format.js). `+56/h`, `-1/h`, `+120k/h`.
  """
  def hour_amount(ctx, v) do
    scaled = v * Map.fetch!(ctx.ticks_per_hour, ctx.speed)

    {value, suffix} =
      if abs(scaled) >= 100_000,
        do: {Float.round(scaled / 1000, 1), "k/h"},
        else: {Float.round(scaled * 1.0, 1), "/h"}

    text = if value == trunc(value), do: grouped(ctx, trunc(value)), else: :erlang.float_to_binary(value, decimals: 1)
    if(value > 0, do: "+", else: "") <> text <> suffix
  end

  @doc "Both unit variants of a value in one span; the surfaces show one (`help-unit-tick` / `help-unit-hour`)."
  def unit_variants_html(class, tick, hour) do
    ~s(<span class="#{class}"><span class="help-unit-tick">#{escape(tick)}</span><span class="help-unit-hour">#{escape(hour)}</span></span>)
  end

  @doc """
  The legend line for a generated table whose text holds `{amount:}` tokens,
  in both units, or `""` when it holds none.
  """
  def rate_legend(ctx, text) do
    if String.contains?(text, "{amount:"),
      do: "\n\n_{units:#{t(ctx, :per_tick_legend)}|#{t(ctx, :per_hour_legend)}}_",
      else: ""
  end

  @doc """
  One bonus as text. `last` is the same bonus at the building's top level,
  when there is one, which turns `+1.6 Mobility` into `+1.6 → +8 Mobility`.

  - `from: :direct`          → `+10 Housing`
  - `from == to` (multiplier) → `+25 % Defense`
  - otherwise                 → `+2.8 Production per Industrial Potential`

  Values of per-tick targets are `{amount:}` tokens, so they read per tick or
  per hour with the reader's unit.
  """
  def bonus(ctx, %Core.Bonus{} = b, last \\ nil) do
    to_name = pipeline_out_name(ctx, b.to)
    amount = if per_tick_target?(b.to), do: &"{amount:#{signed(&1)}}", else: &signed/1

    cond do
      # The dominion tax rate is a share (0.3 = 30 %), so its flat bonuses read as percents.
      b.from == :direct and b.to == :dominion_rate ->
        "#{range(b.value, last && last.value, &pct/1)} #{to_name}"

      b.from == :direct ->
        "#{range(b.value, last && last.value, amount)} #{to_name}"

      b.from == b.to and b.type == :mul ->
        "#{range(b.value, last && last.value, &pct/1)} #{to_name}"

      true ->
        "#{range(b.value, last && last.value, amount)} #{to_name} #{t(ctx, :per)} #{pipeline_in_name(ctx, b.from)}"
    end
  end

  defp range(v, nil, fmt), do: fmt.(v)
  defp range(v, v2, fmt) when v == v2, do: fmt.(v)
  defp range(v, v2, fmt), do: "#{fmt.(v)} → #{fmt.(v2)}"

  @doc """
  Escape a value for a markdown table cell. A pipe inside a `[[slug|label]]`
  link or a `{token|label}` stays as it is: tokens are expanded before
  markdown ever sees the table.
  """
  def cell(text) do
    text
    |> to_string()
    |> String.replace("\n", " ")
    |> then(
      &Regex.replace(~r/\[\[[^\]]*\]\]|\{[^}]*\}|\|/, &1, fn
        "|" -> "\\|"
        token -> token
      end)
    )
  end

  @doc "Render a markdown table from header cells and row lists."
  def table(_headers, []), do: nil

  def table(headers, rows) do
    line = fn cells -> "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |" end
    sep = "|" <> String.duplicate(" --- |", length(headers))
    Enum.join([line.(headers), sep | Enum.map(rows, line)], "\n")
  end

  @doc "HTML-escape a value."
  def escape(s), do: s |> to_string() |> Plug.HTML.html_escape()

  @doc """
  A link to a help page as both surfaces expect it: a real `/help/<slug>`
  href for the public site, `data-help` for the SPA, which opens the page in
  place, and the section anchor when there is one.
  """
  def ref_html(slug, label, anchor \\ nil)

  def ref_html(slug, label, nil),
    do: ~s(<a href="/help/#{escape(slug)}" class="help-ref" data-help="#{escape(slug)}">#{escape(label)}</a>)

  def ref_html(slug, label, anchor) do
    ~s(<a href="/help/#{escape(slug)}##{escape(anchor)}" class="help-ref" data-help="#{escape(slug)}" data-anchor="#{escape(anchor)}">#{escape(label)}</a>)
  end

  @doc """
  `[[slug|name]]` when the slug is a page or an alias, else the plain name,
  so generated text links to a page as soon as that page exists.
  """
  def link_or_name(ctx, slug, name) do
    if Map.has_key?(ctx.index.slugs, slug) or Map.has_key?(ctx.index.aliases, slug),
      do: "[[#{slug}|#{name}]]",
      else: name
  end
end
