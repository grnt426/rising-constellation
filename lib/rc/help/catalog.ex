defmodule RC.Help.Catalog do
  @moduledoc """
  Generated parts of catalog pages (`docs/help-manual.md` §3.2).

  A building page lives in `priv/help/<lang>/building/<key>.md` (slug
  `building/<key>`, the slug the in-game card's `?` opens). Its file holds
  only the prose slot. For every speed the compiler wraps that prose in:

      {facts:building <key>}                 Unique / Limited badge, body type, workforce, unlocking patent
      <prose slot>
      {card:building <key>}                  the in-game building card, with a level selector
      ## Levels            {table:building_levels <key>}
      ## Unlocking         {table:building_unlock <key>}
      ## Ships built here  {table:shipyard_ships <key>}   (shipyards only)

  `{card:}` and `{facts:}` are block tokens that any page may use.

  The card is HTML and CSS only. Each level pip wraps a radio input, and
  `.help-bcard:has(input[value="n"]:checked)` shows that level's panel, so
  the selector works on the public site without script and inside the SPA's
  `v-html`. Both surfaces style it (`assets/css/views/_help.scss`,
  `front/src/styles/game/components/help.scss`).

  Names and links resolve like the rest of the manual: a patent, ship class
  or bonus target links to its page once that page exists, and reads as
  plain text until then.
  """

  import RC.Help.Format,
    only: [
      t: 2,
      data_name: 2,
      ui: 2,
      singular: 1,
      num: 1,
      grouped: 2,
      signed: 1,
      pct: 1,
      table: 2,
      bonus: 2,
      pipeline_in_name: 2,
      pipeline_out_name: 2
    ]

  alias RC.Help.{Compiler, Data, Format, Page, Source}

  @body_biomes [:open, :dome, :orbital]
  @biome_class %{open: "open", dome: "dome", orbital: "orbital"}

  # On a planet, a building's level may not exceed the level of the body's
  # infrastructure building on tile 1 (`StellarSystem.order_building_production/2`).
  # Moons and asteroids have no infrastructure tile.
  @infrastructure %{open: :infra_open, dome: :infra_dome}

  # The page that explains a bonus target. Linked from the card only when the
  # page (or an alias) exists.
  @target_pages %{
    sys_production: "production",
    sys_technology: "technology",
    sys_ideology: "ideology",
    sys_credit: "credit",
    sys_habitation: "housing",
    sys_happiness: "stability",
    sys_mobility: "mobility",
    sys_defense: "defense",
    sys_ci: "intelligence",
    sys_remove_contact: "cybersecurity",
    sys_radar: "slsd",
    player_system: "system-limits",
    player_dominion: "system-limits",
    dominion_rate: "dominion-tax-rate"
  }

  # The page that explains what a scaling bonus reads, linked from the input's
  # icon on the card when the page (or an alias) exists.
  @input_pages %{
    body_ind: "potentials",
    body_tec: "potentials",
    body_act: "potentials",
    body_pop: "local-population",
    sys_pop: "workforce",
    sys_mobility: "mobility",
    sys_defense: "defense"
  }

  # UI string keys (`card.building.*`) and the Buildings guide aliases that
  # explain each limit in depth.
  @limits %{
    unique_system: %{ui: "unique", link: "unique-buildings"},
    unique_body: %{ui: "limited", link: "limited-buildings"}
  }

  # -- pages -------------------------------------------------------------------

  @doc "`\"building/hab_open\"` → `{:building, \"hab_open\"}`; `nil` for other slugs."
  def parse_slug("building/" <> key), do: {:building, key}
  def parse_slug(_slug), do: nil

  @doc """
  Fills in the title and icon of catalog pages that leave them out, from the
  names in `locale` (the map `RC.Help.Data.locale/1` returns, or `nil`).
  """
  def fill_meta(pages, locale) do
    Enum.map(pages, fn
      %Page{kind: :catalog} = page ->
        case parse_slug(page.slug) do
          {:building, key} ->
            name = locale && get_in(locale, [:data, "building", key, "name"])
            %{page | title: page.title || singular(name || key), icon: page.icon || "building/#{key}"}

          nil ->
            page
        end

      page ->
        page
    end)
  end

  @doc "Lint issues of a catalog page that do not depend on the speed."
  def issues(%Page{kind: :catalog} = page) do
    case parse_slug(page.slug) do
      {:building, key} ->
        if Enum.any?(Data.speeds(), &find_building(&1, key)),
          do: [],
          else: [Source.issue(:error, page.slug, "no building `#{key}` in the content of any speed")]

      nil ->
        []
    end
  end

  def issues(_page), do: []

  @doc "Markdown body of a page for the context's speed: a catalog page gets its generated shell."
  def body(ctx, %Page{kind: :catalog} = page) do
    case parse_slug(page.slug) do
      {:building, key} -> building_body(ctx, key, page.body)
      nil -> page.body
    end
  end

  def body(_ctx, %Page{} = page), do: page.body

  defp building_body(ctx, key, prose) do
    case find_building(ctx.speed, key) do
      nil ->
        speed = data_name(ctx, ["speed", Atom.to_string(ctx.speed), "name"])
        "_" <> String.replace(t(ctx, :not_at_speed), "%{speed}", speed) <> "_"

      b ->
        ships =
          if shipyard?(ctx.speed, b),
            do: "## #{t(ctx, :ships_built_here)}\n\n{table:shipyard_ships #{key}}",
            else: ""

        # Point the Levels table's requirements at the page that explains them
        # (not for a one-level building: it has no upgrades).
        levels_intro =
          if length(b.levels) > 1 and resolve(ctx, "upgrades"),
            do: String.replace(t(ctx, :levels_intro), "%{link}", "[[upgrades]]") <> "\n\n",
            else: ""

        [
          "{facts:building #{key}}",
          prose,
          "{card:building #{key}}",
          "## #{t(ctx, :levels)}\n\n#{levels_intro}{table:building_levels #{key}}",
          "## #{t(ctx, :unlocking)}\n\n{table:building_unlock #{key}}",
          ships
        ]
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
    end
  end

  # -- block tokens --------------------------------------------------------------

  @doc "HTML of a `{card:building <key>}` or `{facts:building <key>}` block: `{:ok, html}` or `{:error, message}`."
  def block(ctx, "card", "building", key), do: with_building(ctx, key, &card_html(ctx, &1))
  def block(ctx, "facts", "building", key), do: with_building(ctx, key, &facts_html(ctx, &1))
  def block(_ctx, kind, type, _key), do: {:error, "unknown block `#{kind}:#{type}`"}

  @doc "Markdown of the building table generators: `building_levels`, `building_unlock`, `shipyard_ships`."
  def table(ctx, "building_levels", key), do: with_building(ctx, key, &levels_md(ctx, &1))
  def table(ctx, "building_unlock", key), do: with_building(ctx, key, &unlock_md(ctx, &1))
  def table(ctx, "shipyard_ships", key), do: with_building(ctx, key, &ships_md(ctx, &1))

  defp with_building(ctx, key, fun) do
    case find_building(ctx.speed, key) do
      nil -> {:error, "unknown building `#{key}` for speed #{ctx.speed}"}
      b -> {:ok, fun.(b)}
    end
  end

  defp find_building(speed, key) do
    speed
    |> Data.buildings()
    |> Enum.find(&(&1.biome in @body_biomes and to_string(&1.key) == key))
  end

  defp shipyard?(speed, b), do: speed |> Data.ships() |> Enum.any?(&(&1.shipyard == b.key))

  # -- facts ---------------------------------------------------------------------

  defp facts_html(ctx, b) do
    body_type = data_name(ctx, ["patent_class", @biome_class[b.biome], "name"])

    workforce =
      if b.workforce > 0,
        do: "#{b.workforce} " <> icon_html(ctx, "resource/population") <> " " <> link_html(ctx, "workforce", ui(ctx, "card.building.mobilized") || ""),
        else: "0"

    # A siege picks a building whose content `outputs` carry `:defense` twice as
    # often as the others, whatever the building makes (StellarSystem damage
    # selection).
    siege =
      if :defense in b.outputs,
        do: [{t(ctx, :sieges), link_html(ctx, "siege", t(ctx, :siege_weight))}],
        else: []

    rows =
      [
        {t(ctx, :built_on), link_html(ctx, "stellar-bodies", body_type)},
        {t(ctx, :workforce), workforce},
        {t(ctx, :unlocked_by), patent_html(ctx, hd(b.levels).patent)},
        {t(ctx, :max_level), num(length(b.levels))}
      ] ++ siege

    dl = Enum.map_join(rows, fn {k, v} -> "<dt>#{Format.escape(k)}</dt><dd>#{v}</dd>" end)

    # Every building page leads back to the chapter, like a guide's leaves do.
    part_of =
      case resolve(ctx, "buildings") do
        nil ->
          ""

        {slug, anchor} ->
          link = Format.ref_html(slug, t(ctx, :buildings_guide), anchor)
          ~s(<p class="help-partof">#{String.replace(t(ctx, :part_of), "%{link}", link)}</p>)
      end

    ~s(<div class="help-catalog-facts">#{part_of}#{limit_html(ctx, b)}<dl class="help-facts">#{dl}</dl></div>)
  end

  defp limit_html(ctx, b) do
    case Map.get(@limits, b.limitation) do
      nil ->
        ""

      %{ui: key, link: target} ->
        label = ui(ctx, "card.building.#{key}") || key
        hint = ui(ctx, "card.building.#{key}_hint") || ""
        more = if resolve(ctx, target), do: " " <> link_html(ctx, target, t(ctx, :limit_link)), else: ""

        ~s(<p class="help-limit help-limit-#{key}"><span class="help-limit-badge" title="#{Format.escape(hint)}">#{Format.escape(label)}</span> ) <>
          ~s(<span class="help-limit-hint">#{Format.escape(hint)}</span>#{more}</p>)
    end
  end

  defp patent_html(ctx, nil), do: Format.escape(t(ctx, :none))
  defp patent_html(ctx, key), do: link_html(ctx, "patent/#{key}", patent_name(ctx, key))

  # -- card ----------------------------------------------------------------------

  defp card_html(ctx, b) do
    key = to_string(b.key)
    name = building_name(ctx, b)
    group = "help-bcard-#{key}"
    levels = b.levels

    level_badges = Enum.map_join(levels, &~s(<span class="help-bcard-level" data-level="#{&1.level}">#{&1.level}</span>))

    workforce =
      if b.workforce > 0 do
        ~s(<div class="help-bcard-workforce">#{b.workforce} #{icon_html(ctx, "resource/population")} ) <>
          ~s(#{Format.escape(ui(ctx, "card.building.mobilized") || "")}</div>)
      else
        ""
      end

    toast =
      case Map.get(@limits, b.limitation) do
        nil ->
          ""

        %{ui: ui_key} ->
          hint = ui(ctx, "card.building.#{ui_key}_hint") || ""
          label = ui(ctx, "card.building.#{ui_key}") || ui_key
          ~s(<span class="help-bcard-toast" title="#{Format.escape(hint)}">#{Format.escape(label)}</span>)
      end

    pips =
      if length(levels) > 1 do
        items =
          Enum.map_join(levels, fn l ->
            title = (ui(ctx, "card.building.level_preview") || "Level {n}") |> String.replace("{n}", to_string(l.level))
            checked = if l.level == 1, do: " checked", else: ""

            ~s(<label class="help-bcard-pip" title="#{Format.escape(title)}">) <>
              ~s(<input type="radio" name="#{group}" value="#{l.level}"#{checked}><span>#{l.level}</span></label>)
          end)

        ~s(<div class="help-bcard-pips" role="radiogroup" aria-label="#{Format.escape(t(ctx, :level))}">#{items}</div>)
      else
        ""
      end

    panels =
      Enum.map_join(levels, fn l ->
        ~s(<div class="help-bcard-panel" data-level="#{l.level}">#{Enum.map_join(l.bonus, &bonus_row(ctx, &1))}</div>)
      end)

    costs =
      Enum.map_join(levels, fn l ->
        ~s(<div class="help-bcard-cost" data-level="#{l.level}">) <>
          ~s(<span title="#{Format.escape(t(ctx, :production_cost))}">#{grouped(ctx, l.production)} #{icon_html(ctx, "resource/production")}</span>) <>
          ~s(<span title="#{Format.escape(t(ctx, :credit_cost))}">#{grouped(ctx, l.credit)} #{icon_html(ctx, "resource/credit")}</span></div>)
      end)

    ~s(<figure class="help-bcard" data-building="#{key}"><div class="help-bcard-card">) <>
      ~s(<div class="help-bcard-header"><div class="help-bcard-icon">#{icon_html(ctx, "building/#{key}", name)}#{level_badges}</div>) <>
      ~s(<div class="help-bcard-heading"><div class="help-bcard-name">#{Format.escape(name)}</div>#{workforce}</div></div>) <>
      ~s(<div class="help-bcard-illustration"><img src="/img/help/buildings/#{Format.escape(b.illustration)}" alt="" loading="lazy">#{toast}</div>) <>
      ~s(<div class="help-bcard-info">#{pips}#{panels}</div>#{costs}</div></figure>)
  end

  # One bonus as the in-game card shows it (CardComplexBonus.vue): the target's
  # name on the left, the value and the target's icon on the right. A bonus
  # that scales with something shows "value × <that thing's icon>".
  defp bonus_row(ctx, %Core.Bonus{} = b) do
    to_name = pipeline_out_name(ctx, b.to)

    out_icon =
      case Enum.find(Data.pipeline_out(), &(&1.key == b.to)) do
        %{icon: icon} when is_binary(icon) and icon != "resource/resource" -> icon_html(ctx, icon, to_name)
        _ -> ""
      end

    # Per-tick targets carry both units, like the cards with income per hour on.
    amount = if Format.per_tick_target?(b.to), do: amount_html(ctx, b.value), else: signed(b.value)

    value =
      cond do
        b.from == :direct and b.to == :dominion_rate ->
          pct(b.value)

        b.from == :direct ->
          amount

        b.from == b.to and b.type == :mul ->
          pct(b.value)

        true ->
          in_name = pipeline_in_name(ctx, b.from)

          in_icon =
            case Enum.find(Data.pipeline_in(), &(&1.key == b.from)) do
              %{icon: icon} when is_binary(icon) -> icon_html(ctx, icon, in_name)
              _ -> Format.escape(in_name)
            end
            |> link_around(ctx, Map.get(@input_pages, b.from))

          "#{amount} × #{in_icon}"
      end

    ~s(<div class="help-bcard-bonus"><span class="help-bcard-bonus-name">#{link_html(ctx, Map.get(@target_pages, b.to), to_name)}</span>) <>
      ~s(<span class="help-bcard-bonus-value"><strong>#{value}</strong>#{out_icon}</span></div>)
  end

  # -- tables --------------------------------------------------------------------

  defp levels_md(ctx, b) do
    rows =
      for l <- b.levels do
        [num(l.level), grouped(ctx, l.credit), grouped(ctx, l.production), requires_md(ctx, b, l), Enum.map_join(l.bonus, "; ", &bonus(ctx, &1))]
      end

    headers = [
      t(ctx, :level),
      "{icon:resource/credit} " <> t(ctx, :credit_cost),
      "{icon:resource/production} " <> t(ctx, :production_cost),
      t(ctx, :requires),
      t(ctx, :effects)
    ]

    table(headers, rows) <> Format.rate_legend(ctx, rows |> List.flatten() |> Enum.join(" "))
  end

  # What a level needs besides its cost: the level's patent, and on a planet
  # (not for the infrastructure building itself) the infrastructure building at
  # that level or higher. `Player.order_building/5`, `StellarSystem.order_building_production/2`.
  defp requires_md(ctx, b, l) do
    patent = if l.patent, do: patent_md(ctx, l.patent)
    infra_key = Map.get(@infrastructure, b.biome)

    infra =
      if infra_key && b.type != :infrastructure do
        name = data_name(ctx, ["building", to_string(infra_key), "name"])

        t(ctx, :level_n)
        |> String.replace("%{name}", Format.link_or_name(ctx, "building/#{infra_key}", name))
        |> String.replace("%{n}", num(l.level))
      end

    case Enum.reject([patent, infra], &is_nil/1) do
      [] -> "—"
      parts -> Enum.join(parts, ", ")
    end
  end

  # The patent that unlocks level 1 and its ancestors: a patent can only be
  # bought once its ancestor is owned (`Player.purchase_patent/3`).
  defp unlock_md(ctx, b) do
    case hd(b.levels).patent do
      nil ->
        t(ctx, :no_patent)

      key ->
        chain = patent_chain(ctx.speed, key)
        lead = String.replace(t(ctx, :unlocked_by_patent), "%{patent}", "**" <> patent_md(ctx, key) <> "**")

        if length(chain) > 1 do
          steps =
            chain
            |> Enum.with_index(1)
            |> Enum.map_join("\n", fn {p, i} -> "#{i}. " <> patent_icon(ctx, p.key) <> patent_md(ctx, p.key) end)

          lead <> " " <> t(ctx, :patent_path) <> "\n\n" <> steps
        else
          lead <> " " <> t(ctx, :patent_root)
        end
    end
  end

  defp patent_chain(speed, key) do
    patents = Map.new(Data.patents(speed), &{&1.key, &1})

    key
    |> Stream.unfold(fn
      nil ->
        nil

      k ->
        case Map.get(patents, k) do
          nil -> nil
          p -> {p, p.ancestor}
        end
    end)
    |> Enum.take(64)
    |> Enum.reverse()
  end

  defp ships_md(ctx, b) do
    classes =
      ctx.speed
      |> Data.ships()
      |> Enum.filter(&(&1.shipyard == b.key))
      |> Enum.map(& &1.class)
      |> Enum.uniq()

    case classes do
      [] -> "_#{t(ctx, :none)}_"
      _ -> t(ctx, :shipyard_intro) <> "\n\n" <> Enum.map_join(classes, "\n", &("- " <> class_md(ctx, &1)))
    end
  end

  # Ship class names only exist in portal.json (the match archive's tabs).
  defp class_md(ctx, class) do
    path = ["page", "play", "archive", "ships", to_string(class)]

    name =
      get_in(Map.get(ctx.locale, :portal, %{}), path) || get_in(Map.get(ctx.en, :portal, %{}), path) ||
        class |> to_string() |> String.capitalize()

    Format.link_or_name(ctx, "ship-class/#{class}", name)
  end

  # -- helpers -------------------------------------------------------------------

  defp amount_html(ctx, v), do: Format.unit_variants_html("help-amount", signed(v), Format.hour_amount(ctx, v))

  defp building_name(ctx, b), do: singular(data_name(ctx, ["building", to_string(b.key), "name"]))
  defp patent_name(ctx, key), do: singular(data_name(ctx, ["patent", to_string(key), "name"]))
  defp patent_md(ctx, key), do: Format.link_or_name(ctx, "patent/#{key}", patent_name(ctx, key))

  defp patent_icon(ctx, key) do
    name = "patent/#{key}"
    if MapSet.member?(ctx.icons, name), do: "{icon:#{name}} ", else: ""
  end

  defp icon_html(ctx, name, title \\ nil) do
    ~s(<i class="help-icon" data-icon="#{Format.escape(name)}" title="#{Format.escape(title || Compiler.icon_title(ctx, name))}"></i>)
  end

  defp resolve(_ctx, nil), do: nil

  defp resolve(ctx, target) do
    cond do
      Map.has_key?(ctx.index.slugs, target) -> {target, nil}
      slug = Map.get(ctx.index.aliases, target) -> {slug, get_in(ctx.index, [:alias_anchors, target, :anchor])}
      true -> nil
    end
  end

  defp link_html(ctx, target, label) do
    case resolve(ctx, target) do
      nil -> Format.escape(label)
      {slug, anchor} -> Format.ref_html(slug, label, anchor)
    end
  end

  # Wraps already-built HTML (an icon) in a page link, when the page exists.
  @inner_marker "HELPCATALOGINNER"
  defp link_around(inner_html, ctx, target) do
    case resolve(ctx, target) do
      nil -> inner_html
      {slug, anchor} -> slug |> Format.ref_html(@inner_marker, anchor) |> String.replace(@inner_marker, inner_html)
    end
  end
end
