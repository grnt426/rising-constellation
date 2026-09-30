defmodule RC.Help.ResearchCatalog do
  @moduledoc """
  Generated parts of the patent and lex catalog pages, and the Patents &
  lexes chapter's tables (`docs/help-review/patents/guide-map.md` D1-D3).

  A patent page lives in `priv/help/<lang>/patent/<key>.md` (slug
  `patent/<key>`, the slug `PatentCard.vue` opens), a lex page in
  `priv/help/<lang>/lex/<key>.md` (slug `lex/<key>`, `DoctrineCard.vue`).
  Their files hold only the prose slot. For every speed `RC.Help.Catalog`
  hands the page here, which wraps the prose in:

      patent                                   lex
      {facts:patent <key>}                     {facts:lex <key>}
      <prose slot>                             <prose slot>
      {card:patent <key>}                      {card:lex <key>}
      ## Unlocks      (buildings, ships…)      ## Effects    (benefits, then drawbacks)
      ## Unlocking    (path from the root)     ## Unlocking  (path from the root)

  A key missing at the page's speed renders `{absent:<kind> <key>}` instead
  (`RC.Help.Catalog`). Prices are base prices: the real price grows with every
  patent or lex the player owns, which the facts block says and links to the
  `price-scaling` page.

  Internally a lex is a `doctrine` (content, locale keys, icons); the
  manual never says so.
  """

  import RC.Help.Format, only: [t: 2, data_name: 2, singular: 1, grouped: 2, num: 1, table: 2, bonus: 2]

  alias RC.Help.{Catalog, Data, Format}

  # Bonus targets where a lower value is the better one: a negative value
  # there is a benefit, a positive one a drawback.
  @lower_is_better [:army_maintenance]

  # -- pages -------------------------------------------------------------------

  @doc "Markdown body of a patent or lex page for the context's speed."
  def body(ctx, kind, key, prose) do
    case find(ctx.speed, kind, key) do
      nil ->
        "{absent:#{kind} #{key}}"

      node ->
        details =
          case kind do
            :patent -> "## #{t(ctx, :unlocks)}\n\n" <> unlocks_md(ctx, node)
            :lex -> "## #{t(ctx, :effects)}\n\n" <> effects_md(ctx, node)
          end

        [
          "{facts:#{kind} #{key}}",
          prose,
          "{card:#{kind} #{key}}",
          details,
          "## #{t(ctx, :unlocking)}\n\n" <> path_md(ctx, kind, node),
          Catalog.also_used_md(ctx, kind, node.key)
        ]
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
    end
  end

  @doc "HTML of `{facts:patent|lex <key>}` and `{card:patent|lex <key>}`."
  def block(ctx, kind, type, key) do
    type = String.to_existing_atom(type)

    case find(ctx.speed, type, key) do
      nil -> {:error, "unknown #{type} `#{key}` for speed #{ctx.speed}"}
      node when kind == "facts" -> {:ok, facts_html(ctx, type, node)}
      node when kind == "card" -> {:ok, card_html(ctx, type, node)}
    end
  end

  @doc "The patent or lex with this key at a speed, or `nil`."
  def find(speed, kind, key), do: speed |> nodes(kind) |> Enum.find(&(to_string(&1.key) == to_string(key)))

  defp nodes(speed, :patent), do: Data.patents(speed)
  defp nodes(speed, :lex), do: Data.doctrines(speed)

  # -- facts -------------------------------------------------------------------

  defp facts_html(ctx, kind, node) do
    part_of =
      case Catalog.resolve(ctx, guide_slug(kind)) do
        nil ->
          ""

        {slug, anchor} ->
          link = Format.ref_html(slug, t(ctx, guide_label(kind)), anchor)
          ~s(<p class="help-partof">#{String.replace(t(ctx, :part_of), "%{link}", link)}</p>)
      end

    children = children(ctx.speed, kind, node.key)

    rows =
      [
        {t(ctx, :branch), Format.escape(branch_name(ctx, kind, node.class))},
        {t(ctx, :base_price), price_html(ctx, kind, node.cost) <> " " <> increase_html(ctx, kind)},
        {t(ctx, :requires), if(node.ancestor, do: node_link_html(ctx, kind, node.ancestor), else: Format.escape(t(ctx, :none)))},
        {t(ctx, :leads_to), if(children == [], do: "—", else: Enum.map_join(children, ", ", &node_link_html(ctx, kind, &1.key)))}
      ] ++ info_rows(ctx, kind, node)

    dl = Enum.map_join(rows, fn {k, v} -> "<dt>#{Format.escape(k)}</dt><dd>#{v}</dd>" end)
    ~s(<div class="help-catalog-facts">#{part_of}<dl class="help-facts">#{dl}</dl></div>)
  end

  defp info_rows(ctx, :patent, node) do
    case patent_info(ctx, node.key) do
      nil -> []
      info -> [{t(ctx, :effect), info_html(ctx, node.key, info)}]
    end
  end

  defp info_rows(_ctx, :lex, _node), do: []

  # The upgrade patents' info line links to the page on upgrades.
  defp info_html(ctx, key, info) do
    if String.starts_with?(to_string(key), "infra_"),
      do: Catalog.link_html(ctx, "upgrades", info),
      else: Format.escape(info)
  end

  defp increase_html(ctx, kind) do
    c = Map.fetch!(ctx.consts, ctx.speed)
    inc = if kind == :patent, do: c.patent_level_price_increase, else: c.doctrine_level_price_increase
    text = t(ctx, :"increase_#{kind}") |> String.replace("%{pct}", Format.num(inc * 100) <> " %")
    "(" <> Catalog.link_html(ctx, "price-scaling", text) <> ")"
  end

  # -- card --------------------------------------------------------------------

  defp card_html(ctx, kind, node) do
    key = to_string(node.key)
    name = node_name(ctx, kind, key)
    icon = "#{icon_group(kind)}/#{key}"
    img_dir = if kind == :patent, do: "patents", else: "lexes"

    rows =
      case kind do
        :patent -> patent_rows(ctx, node)
        :lex -> lex_rows(ctx, node)
      end

    ~s(<figure class="help-bcard help-rcard" data-#{kind}="#{Format.escape(key)}"><div class="help-bcard-card">) <>
      ~s(<div class="help-bcard-header"><div class="help-bcard-icon">#{Catalog.icon_html(ctx, icon, name)}</div>) <>
      ~s(<div class="help-bcard-heading"><div class="help-bcard-name">#{Format.escape(name)}</div></div></div>) <>
      ~s(<div class="help-bcard-illustration"><img src="/img/help/#{img_dir}/#{Format.escape(node.illustration)}" alt="" loading="lazy"></div>) <>
      ~s(<div class="help-bcard-info"><div class="help-bcard-panel" data-level="1">#{rows}</div></div>) <>
      ~s(<div class="help-bcard-cost" data-level="1"><span title="#{Format.escape(t(ctx, :base_price))}">#{price_html(ctx, kind, node.cost)}</span></div>) <>
      "</div></figure>"
  end

  # "Unlocks X" rows, as PatentCard.vue shows them, then the info line.
  defp patent_rows(ctx, node) do
    unlocks =
      Enum.map_join(node.unlock, fn u ->
        ~s(<div class="help-bcard-bonus"><span class="help-bcard-bonus-name">#{Format.escape(t(ctx, :unlocks))}</span>) <>
          ~s(<span class="help-bcard-bonus-value">#{unlock_html(ctx, u)}</span></div>)
      end)

    info =
      case patent_info(ctx, node.key) do
        nil -> ""
        text -> ~s(<div class="help-bcard-note">#{info_html(ctx, node.key, text)}</div>)
      end

    unlocks <> info
  end

  defp lex_rows(ctx, node) do
    quote_line =
      case data_name(ctx, ["doctrine", to_string(node.key), "quote"]) do
        q when q in [nil, "", "—", "quote"] -> ""
        q -> ~s(<div class="help-bcard-note help-bcard-quote">“#{Format.escape(q)}”</div>)
      end

    quote_line <> Enum.map_join(node.bonus, &Catalog.bonus_row(ctx, &1))
  end

  defp unlock_html(ctx, %{type: :building, key: k} = u) do
    name = singular(data_name(ctx, ["building", to_string(k), "name"]))
    label = if (u[:level] || 1) > 1, do: level_label(ctx, name, u.level), else: name
    icon_if(ctx, "building/#{k}") <> Catalog.link_html(ctx, "building/#{k}", label)
  end

  defp unlock_html(ctx, %{type: :ship, key: k}) do
    name = singular(data_name(ctx, ["ship", to_string(k), "name"]))
    icon_if(ctx, "ship/#{k}") <> Catalog.link_html(ctx, "ship/#{k}", name)
  end

  defp icon_if(ctx, name) do
    if MapSet.member?(ctx.icons, name), do: Catalog.icon_html(ctx, name) <> " ", else: ""
  end

  defp level_label(ctx, name, level),
    do: t(ctx, :level_n) |> String.replace("%{name}", name) |> String.replace("%{n}", num(level))

  # -- sections ----------------------------------------------------------------

  defp unlocks_md(ctx, node) do
    items =
      Enum.map(node.unlock, fn
        %{type: :building, key: k} = u ->
          name = singular(data_name(ctx, ["building", to_string(k), "name"]))
          label = if (u[:level] || 1) > 1, do: level_label(ctx, name, u.level), else: name
          "- " <> md_icon(ctx, "building/#{k}") <> Format.link_or_name(ctx, "building/#{k}", label)

        %{type: :ship, key: k} ->
          name = singular(data_name(ctx, ["ship", to_string(k), "name"]))
          "- " <> md_icon(ctx, "ship/#{k}") <> Format.link_or_name(ctx, "ship/#{k}", name)
      end)

    info =
      case patent_info(ctx, node.key) do
        nil ->
          []

        text ->
          if String.starts_with?(to_string(node.key), "infra_"),
            do: ["- " <> text <> ". " <> String.replace(t(ctx, :see), "%{link}", Format.link_or_name(ctx, "upgrades", "upgrades"))],
            else: ["- " <> text <> "."]
      end

    case items ++ info do
      [] -> "_#{t(ctx, :none)}_"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp effects_md(ctx, node) do
    {benefits, drawbacks} = Enum.split_with(node.bonus, &(not drawback?(&1)))
    list = fn bonuses -> Enum.map_join(bonuses, "\n", &("- " <> effect_md(ctx, &1))) end

    body =
      case {benefits, drawbacks} do
        {[], []} -> "_#{t(ctx, :none)}_"
        {_, []} -> list.(benefits)
        {[], _} -> "**#{t(ctx, :drawbacks)}**\n\n" <> list.(drawbacks)
        _ -> "**#{t(ctx, :benefits)}**\n\n" <> list.(benefits) <> "\n\n**#{t(ctx, :drawbacks)}**\n\n" <> list.(drawbacks)
      end

    body <> Format.rate_legend(ctx, body)
  end

  @doc "Whether a lex or tradition bonus works against the player."
  def drawback?(%Core.Bonus{to: to, value: v}) when to in @lower_is_better, do: v > 0
  def drawback?(%Core.Bonus{value: v}), do: v < 0

  # A bonus as `Format.bonus/2` writes it, with the target's name linked to
  # the page that explains it once that page exists.
  @doc false
  def effect_md(ctx, %Core.Bonus{} = b) do
    text = bonus(ctx, b)
    to_name = Format.pipeline_out_name(ctx, b.to)

    case Catalog.target_page(b.to) do
      nil ->
        text

      page ->
        linked = Format.link_or_name(ctx, page, to_name)
        if linked == to_name, do: text, else: replace_last(text, to_name, linked)
    end
  end

  defp replace_last(text, part, replacement) do
    case :binary.matches(text, part) do
      [] ->
        text

      matches ->
        {pos, len} = List.last(matches)
        binary_part(text, 0, pos) <> replacement <> binary_part(text, pos + len, byte_size(text) - pos - len)
    end
  end

  defp path_md(ctx, kind, node) do
    chain = chain(ctx.speed, kind, node.key)

    if length(chain) > 1 do
      steps =
        chain
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {n, i} -> "#{i}. " <> md_icon(ctx, "#{icon_group(kind)}/#{n.key}") <> node_md(ctx, kind, n.key) end)

      t(ctx, :"#{kind}_path") <> "\n\n" <> steps
    else
      t(ctx, :"#{kind}_root")
    end
  end

  # The node and its ancestors, root first: a patent or lex can only be bought
  # once its one ancestor is owned (`Player.purchase_patent/2`, `purchase_doctrine/2`).
  @doc false
  def chain(speed, kind, key) do
    by_key = speed |> nodes(kind) |> Map.new(&{&1.key, &1})

    key
    |> to_existing_key()
    |> Stream.unfold(fn
      nil ->
        nil

      k ->
        case Map.get(by_key, k) do
          nil -> nil
          n -> {n, n.ancestor}
        end
    end)
    |> Enum.take(100)
    |> Enum.reverse()
  end

  defp to_existing_key(key) when is_atom(key), do: key
  defp to_existing_key(key), do: String.to_existing_atom(key)

  defp children(speed, kind, key), do: speed |> nodes(kind) |> Enum.filter(&(&1.ancestor == key))

  # -- tables ------------------------------------------------------------------

  @doc """
  Markdown of the chapter's tables: `patents_list`, `lexes_list`,
  `price_scaling`, `lex_slot_costs`, `lex_change_waits`, `traditions`.
  """
  def render_table(ctx, "patents_list") do
    rows =
      for p <- tree_order(ctx.speed, :patent) do
        [
          md_icon(ctx, "patent/#{p.key}") <> node_md(ctx, :patent, p.key),
          branch_name(ctx, :patent, p.class),
          if(p.ancestor, do: node_md(ctx, :patent, p.ancestor), else: "—"),
          grouped(ctx, p.cost),
          unlock_summary(ctx, p)
        ]
      end

    headers = [t(ctx, :patent), t(ctx, :branch), t(ctx, :requires), "{icon:resource/technology} " <> t(ctx, :base_price), t(ctx, :unlocks)]
    {:ok, table(headers, rows) || "_#{t(ctx, :none)}_"}
  end

  def render_table(ctx, "lexes_list") do
    rows =
      for d <- tree_order(ctx.speed, :lex) do
        [
          md_icon(ctx, "doctrine/#{d.key}") <> node_md(ctx, :lex, d.key),
          branch_name(ctx, :lex, d.class),
          if(d.ancestor, do: node_md(ctx, :lex, d.ancestor), else: "—"),
          grouped(ctx, d.cost),
          Enum.map_join(d.bonus, "; ", &bonus(ctx, &1))
        ]
      end

    headers = [t(ctx, :lex), t(ctx, :branch), t(ctx, :requires), "{icon:resource/ideology} " <> t(ctx, :base_price), t(ctx, :effects)]
    body = table(headers, rows) || "_#{t(ctx, :none)}_"
    {:ok, body <> Format.rate_legend(ctx, body)}
  end

  # The same patent and lex bought as the player's 1st, 5th, 10th… purchase of
  # that kind: base × (1 + owned × increase) (`Player.purchase_patent/2`,
  # `purchase_doctrine/2`). The examples exist at every speed.
  @example_patent :shipyard_2
  @example_lex :credit_2
  @purchases [1, 5, 10, 20, 30, 40, 50, 60]

  def render_table(ctx, "price_scaling") do
    c = Map.fetch!(ctx.consts, ctx.speed)
    patent = find(ctx.speed, :patent, @example_patent)
    lex = find(ctx.speed, :lex, @example_lex)

    cond do
      is_nil(patent) or is_nil(lex) ->
        {:error, "example patent `#{@example_patent}` or lex `#{@example_lex}` is missing at #{ctx.speed}"}

      c.patent_level_price_increase != c.doctrine_level_price_increase ->
        {:error, "patent and lex price increases differ at #{ctx.speed}: the table needs a factor column per kind"}

      true ->
        inc = c.patent_level_price_increase
        n_patents = length(Data.patents(ctx.speed))
        n_lexes = length(Data.doctrines(ctx.speed))

        rows =
          for n <- @purchases, n <= max(n_patents, n_lexes) do
            factor = 1 + (n - 1) * inc
            price = fn base, count -> if n <= count, do: grouped(ctx, round(base * factor)), else: "—" end
            [ordinal(ctx, n), "×" <> Format.num(Float.round(factor * 1.0, 2)), price.(patent.cost, n_patents), price.(lex.cost, n_lexes)]
          end

        headers = [
          t(ctx, :purchase),
          t(ctx, :price_factor),
          "{icon:resource/technology} " <> node_md(ctx, :patent, @example_patent) <> " (#{grouped(ctx, patent.cost)})",
          "{icon:resource/ideology} " <> node_md(ctx, :lex, @example_lex) <> " (#{grouped(ctx, lex.cost)})"
        ]

        {:ok, table(headers, rows)}
    end
  end

  # Slot n+1 costs 2^(n-1) × the initial price, capped (`Player.purchase_policy_slot/1`).
  # Rows until the price reaches the cap; that row stands for every later slot.
  def render_table(ctx, "lex_slot_costs") do
    c = Map.fetch!(ctx.consts, ctx.speed)

    rows =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(fn owned -> {owned + 1, min(round(:math.pow(2, owned - 1)) * c.initial_policy_slot_cost, c.policy_slot_maximum_cost)} end)
      |> Enum.reduce_while([], fn {slot, price}, acc ->
        if price >= c.policy_slot_maximum_cost do
          label = String.replace(t(ctx, :slot_and_after), "%{nth}", ordinal(ctx, slot))
          {:halt, [[label, grouped(ctx, price)] | acc]}
        else
          {:cont, [[ordinal(ctx, slot), grouped(ctx, price)] | acc]}
        end
      end)
      |> Enum.reverse()

    {:ok, table([t(ctx, :lex_slot), "{icon:resource/ideology} " <> t(ctx, :price)], rows)}
  end

  # The wait after the player's nth change of active lexes:
  # initial + n × factor ticks (`Player.update_policies/2`, count starts at 1).
  def render_table(ctx, "lex_change_waits") do
    rows = for n <- 1..10, do: [ordinal(ctx, n), "{duration:#{lex_wait(ctx.speed, n)}}"]
    {:ok, table([t(ctx, :change), t(ctx, :wait_after)], rows)}
  end

  # Every playable faction's traditions (`Data.Game.Faction`): always on, the
  # same at every speed. The Rebellion (the Rebel Defense bot faction) has
  # traditions but no player can join it, so only playable factions are listed.
  def render_table(ctx, "traditions") do
    rows =
      for f <- Data.factions(), f.playable, tr <- f.traditions do
        tkey = to_string(tr.key)

        [
          data_name(ctx, ["faction", to_string(f.key), "name"]),
          data_name(ctx, ["tradition", tkey, "name"]),
          effect_md(ctx, tr.bonus),
          data_name(ctx, ["tradition", tkey, "description"])
        ]
      end

    body = table([t(ctx, :faction), t(ctx, :tradition), t(ctx, :effect), t(ctx, :description)], rows) || "_#{t(ctx, :none)}_"
    {:ok, body <> Format.rate_legend(ctx, body)}
  end

  @doc "Wait in ticks after the player's nth change of active lexes at a speed."
  def lex_wait(speed, n) do
    c = Data.constants(speed)
    c.initial_update_policies_cooldown + n * c.update_policies_cooldown_factor
  end

  # Roots first, then each branch in content order; inside a branch, a node
  # right after its ancestor (depth first), as the panels draw the tree.
  defp tree_order(speed, kind) do
    all = nodes(speed, kind)
    classes = all |> Enum.map(& &1.class) |> Enum.uniq()
    class_rank = fn c -> if c == :root, do: -1, else: Enum.find_index(classes, &(&1 == c)) end
    by_parent = Enum.group_by(all, & &1.ancestor)

    walk = fn walk, parent ->
      Enum.flat_map(Map.get(by_parent, parent, []), fn n -> [n | walk.(walk, n.key)] end)
    end

    walk.(walk, nil) |> Enum.sort_by(&class_rank.(&1.class))
  end

  defp unlock_summary(ctx, p) do
    names =
      Enum.map(p.unlock, fn
        %{type: :building, key: k} = u ->
          name = singular(data_name(ctx, ["building", to_string(k), "name"]))
          name = if (u[:level] || 1) > 1, do: level_label(ctx, name, u.level), else: name
          Format.link_or_name(ctx, "building/#{k}", name)

        %{type: :ship, key: k} ->
          Format.link_or_name(ctx, "ship/#{k}", singular(data_name(ctx, ["ship", to_string(k), "name"])))
      end)

    case {names, patent_info(ctx, p.key)} do
      {[], nil} -> "—"
      {[], info} -> info
      {names, _} -> Enum.join(names, ", ")
    end
  end

  # -- names and links ---------------------------------------------------------

  defp icon_group(:patent), do: "patent"
  defp icon_group(:lex), do: "doctrine"

  defp guide_slug(:patent), do: "patents"
  defp guide_slug(:lex), do: "lexes"

  defp guide_label(:patent), do: :patents_guide
  defp guide_label(:lex), do: :lexes_guide

  defp node_name(ctx, kind, key), do: singular(data_name(ctx, [icon_group(kind), to_string(key), "name"]))

  defp node_md(ctx, kind, key), do: Format.link_or_name(ctx, "#{kind}/#{key}", node_name(ctx, kind, key))

  defp node_link_html(ctx, kind, key), do: Catalog.link_html(ctx, "#{kind}/#{key}", node_name(ctx, kind, key))

  defp branch_name(ctx, :patent, class), do: data_name(ctx, ["patent_class", to_string(class), "name"])
  defp branch_name(ctx, :lex, class), do: data_name(ctx, ["doctrine_class", to_string(class), "name"])

  defp price_html(ctx, kind, cost) do
    res = if kind == :patent, do: "resource/technology", else: "resource/ideology"
    "#{grouped(ctx, cost)} " <> Catalog.icon_html(ctx, res)
  end

  defp patent_info(ctx, key) do
    key = to_string(key)

    # data_name/2 falls back to the key itself when the locale has no line.
    case data_name(ctx, ["patent_info", key]) do
      text when is_binary(text) and text != "" and text != key -> text
      _ -> nil
    end
  end

  defp md_icon(ctx, name), do: if(MapSet.member?(ctx.icons, name), do: "{icon:#{name}} ", else: "")

  defp ordinal(%{lang: "fr"}, 1), do: "1er"
  defp ordinal(%{lang: "fr"}, n), do: "#{n}e"

  defp ordinal(_ctx, n) do
    suffix =
      cond do
        rem(n, 100) in 11..13 -> "th"
        rem(n, 10) == 1 -> "st"
        rem(n, 10) == 2 -> "nd"
        rem(n, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{n}#{suffix}"
  end
end
