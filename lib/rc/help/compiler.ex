defmodule RC.Help.Compiler do
  @moduledoc """
  Turns `priv/help` sources into per-language, per-speed HTML plus a lint
  report. Pure functions over `RC.Help.Data`; `RC.Help` calls `build/1` at
  compile time.

  Token syntax (see `docs/help-manual.md` §3.1):

      {icon:group/name}           inline icon, tooltip = UI name (or `{icon:x|Label}`)
      {const:key}                 Data.Game.Constant value for the current speed
      {rate:value|noun}           a rate, per tick or per hour for the reader (value = number or constant key)
      {duration:value}            a duration in ticks, or hours for the reader (value = number or constant key)
      {name:type.key}             localized name from data.json (`{name:building.hab_open}`)
      {ui:path.to.key}            UI string from game.json
      {shot:name#mark,mark|Caption}  screenshot from priv/help/shots/manifest.json with highlight boxes
      {chart:name args|Caption}   generated chart, see RC.Help.Charts
      [[slug]] / [[slug|label]]   link to another page (aliases resolve; a bare plain-word
                                  slug is shown as typed, other slugs show the page title)
      {table:generator args}      generated table, see RC.Help.Tables

  Text tokens are substituted before markdown rendering. Icons, links, rates,
  screenshots and charts become placeholders, survive markdown + sanitizer
  untouched, and are swapped for their HTML afterwards, so the sanitizer
  never sees (and never strips) the attributes they need.

  Rates, durations and charts carry both units in the HTML
  (`help-unit-tick` / `help-unit-hour`); the surfaces show one of them.
  Pages with `guide:` get a "Part of the … guide" line; guide pages
  (`kind: guide`) get the list of their pages appended.
  """

  alias RC.Help.{Charts, Data, Format, Page, Source, Tables}
  import RC.Help.Format, only: [t: 2, data_name: 2, has_data_key?: 2, ui: 2, singular: 1, sig: 1]

  @inline_re ~r/\{(icon|const|name|ui|rate|duration|shot):([^}|]+?)(?:\|([^}]*))?\}/
  @table_re ~r/\{table:([a-z_]+)([^}]*)\}/
  @chart_re ~r/\{chart:([a-z_]+)([^}|]*)(?:\|([^}]*))?\}/
  @link_re ~r/\[\[([^\]|]+?)(?:\|([^\]]*))?\]\]/
  @fence_re ~r/```.*?```/s
  @indented_code_re ~r/^(?: {4}|\t).*$/m

  # Style rule 3: UI names only. Rule 4: no adjectives of quality.
  @forbidden_internal ~r/\b(admirals?|speakers?|sp(?:y|ies)|doctrines?|sys_[a-z_]+|[a-z]+_coef)\b/i
  @forbidden_tone ~r/\b(powerful|crucial|amazing|exciting|essential|incredible|vital|game-changing)\b/i
  # Style rules 14-16: short sentences, no semicolons or dashes joining clauses,
  # time written with {rate:} / {duration:}.
  @max_words %{mechanic: 180, guide: 450}
  @max_sentence_words 25
  @typed_time_re ~r/\bper (?:tick|hour|day|minute)s?\b|\b\d[\d.,]*\s*(?:ticks?|hours?|days?)\b/i

  @type issue :: %{level: :error | :warning, page: String.t(), msg: String.t()}

  # -- build -----------------------------------------------------------------

  @doc """
  Compiles every page for `langs` (default `["en"]`). Returns

      %{pages: %{lang => %{slug => %Page{}}}, index: index, errors: [issue], warnings: [issue]}

  Lint issues are collected from the English pass only; other languages
  reuse the same sources with localized names.
  """
  def build(opts \\ []) do
    langs = Keyword.get(opts, :langs, ["en"])
    {en_pages, source_issues} = Source.load("en")
    {index, index_issues} = build_index(en_pages)
    base = base(index)

    locale_issues =
      if base.locale_missing?,
        do: [
          Source.issue(
            :error,
            "-",
            "front/src/locales/en/{data,game}.json not found; names and UI strings cannot be resolved"
          )
        ],
        else: []

    {pages_by_lang, compile_issues} =
      Enum.reduce(langs, {%{}, []}, fn lang, {acc, issues} ->
        {pages, _} = if lang == "en", do: {en_pages, []}, else: Source.load(lang)
        ctx = context(lang, base)

        {compiled, lang_issues} =
          Enum.map_reduce(pages, [], fn page, acc_issues ->
            {compiled, page_issues} = compile_page(page, ctx)
            {compiled, acc_issues ++ page_issues}
          end)

        issues = if lang == "en", do: issues ++ lang_issues, else: issues
        pages = compiled |> Map.new(&{&1.slug, &1}) |> decorate_guides(ctx)
        {Map.put(acc, lang, pages), issues}
      end)

    all = source_issues ++ index_issues ++ locale_issues ++ compile_issues ++ cross_page_issues(en_pages)
    all = Enum.uniq(all)

    %{
      pages: pages_by_lang,
      index: index,
      errors: Enum.filter(all, &(&1.level == :error)),
      warnings: Enum.filter(all, &(&1.level == :warning))
    }
  end

  @doc false
  def base(index \\ %{slugs: %{}, aliases: %{}, categories: %{}}) do
    en = Data.locale("en")

    %{
      index: Map.merge(%{kinds: %{}, guides: %{}, alias_anchors: %{}}, index),
      icons: Data.icons(),
      icons_available?: Data.icons_available?(),
      en: en || %{data: %{}, game: %{}},
      locale_missing?: is_nil(en),
      consts: Map.new(Data.speeds(), &{&1, Data.constants(&1)}),
      ticks_per_hour: Map.new(Data.speeds(), &{&1, Data.ticks_per_hour(&1)}),
      shots: Data.shots()
    }
  end

  @doc false
  def context(lang, base \\ base()) do
    Map.merge(base, %{lang: lang, locale: Data.locale(lang) || base.en, speed: :slow})
  end

  defp build_index(pages) do
    {slugs, issues} =
      Enum.reduce(pages, {%{}, []}, fn p, {acc, issues} ->
        if Map.has_key?(acc, p.slug),
          do: {acc, [Source.issue(:error, p.slug, "duplicate slug") | issues]},
          else: {Map.put(acc, p.slug, p.title), issues}
      end)

    # An alias may point at a section: `aliases: [bonus-stacking#how-bonuses-add-up]`.
    alias_entries = for p <- pages, a <- p.aliases, do: {p.slug, String.split(a, "#", parts: 2)}

    {aliases, issues} =
      alias_entries
      |> Enum.map(fn {slug, [name | _]} -> {name, slug} end)
      |> Enum.reduce({%{}, issues}, &add_alias(&1, &2, slugs))

    headings =
      Map.new(pages, fn p ->
        {p.slug, ~r/^\#{2,3}\s+(.+?)\s*$/m |> Regex.scan(p.body) |> Map.new(fn [_, h] -> {anchor_id(h), h} end)}
      end)

    {alias_anchors, issues} =
      Enum.reduce(alias_entries, {%{}, issues}, fn
        {slug, [name, anchor]}, {acc, issues} ->
          case get_in(headings, [slug, anchor]) do
            nil ->
              {acc, [Source.issue(:error, slug, "alias `#{name}##{anchor}`: no heading with that anchor") | issues]}

            heading ->
              {Map.put(acc, name, %{anchor: anchor, heading: ui_text(heading)}), issues}
          end

        _, acc ->
          acc
      end)

    categories = pages |> Enum.group_by(& &1.category, & &1.slug) |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)
    kinds = Map.new(pages, &{&1.slug, &1.kind})
    guides = pages |> Enum.filter(& &1.guide) |> Enum.group_by(& &1.guide, & &1.slug)

    {%{
       slugs: slugs,
       aliases: aliases,
       alias_anchors: alias_anchors,
       categories: categories,
       kinds: kinds,
       guides: guides
     }, Enum.reverse(issues)}
  end

  @doc "Anchor id of a heading: `How bonuses add up` → `how-bonuses-add-up`."
  def anchor_id(text) do
    text
    |> String.replace(~r/\{[^}]*\}|\[\[|\]\]|<[^>]+>/, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp add_heading_ids(html) do
    Regex.replace(~r/<h([23])>\s*(.*?)\s*<\/h\1>/s, html, fn _, level, inner ->
      ~s(<h#{level} id="#{anchor_id(inner)}">#{inner}</h#{level}>)
    end)
  end

  defp add_alias({a, slug}, {amap, issues}, slugs) do
    cond do
      Map.has_key?(slugs, a) -> {amap, [Source.issue(:error, slug, "alias `#{a}` is also a page slug") | issues]}
      Map.has_key?(amap, a) -> {amap, [Source.issue(:error, slug, "alias `#{a}` used by two pages") | issues]}
      true -> {Map.put(amap, a, slug), issues}
    end
  end

  # -- page ------------------------------------------------------------------

  @doc false
  def compile_page(%Page{} = page, ctx) do
    {html, token_issues} =
      Enum.map_reduce(Data.speeds(), [], fn speed, issues ->
        {md, placeholders, expand_issues} = expand(page.body, %{ctx | speed: speed}, page.slug)
        html = md |> render(placeholders) |> add_heading_ids()
        {{speed, html}, issues ++ expand_issues}
      end)

    html = Map.new(html)

    page = %{
      page
      | lang: ctx.lang,
        html: html,
        text: to_text(html[:slow]),
        speed_sensitive: html |> Map.values() |> Enum.uniq() |> length() > 1
    }

    {page, Enum.uniq(token_issues) ++ lint_meta(page, ctx) ++ lint_prose(page)}
  end

  @doc """
  Guide navigation, added after every page of a language is compiled: a page
  whose `guide:` names a guide page starts with "Part of the … guide"; a
  guide page ends with its pages and the first sentence of each. The plain
  `text` (search) is left as it was.
  """
  def decorate_guides(pages, ctx) do
    Map.new(pages, fn {slug, page} ->
      page =
        case page.guide && Map.get(pages, page.guide) do
          %Page{kind: :guide} = guide ->
            link = ref_html(guide.slug, guide.title)
            line = ~s(<p class="help-partof">#{String.replace(t(ctx, :part_of), "%{link}", link)}</p>)
            %{page | html: Map.new(page.html, fn {speed, h} -> {speed, line <> h} end)}

          _ ->
            page
        end

      members =
        if page.kind == :guide do
          pages
          |> Map.values()
          |> Enum.filter(&(&1.guide == slug))
          |> Enum.sort_by(& &1.title)
        else
          []
        end

      page =
        if members == [] do
          page
        else
          items =
            Enum.map_join(members, fn p ->
              ~s(<li>#{ref_html(p.slug, p.title)} <span class="help-guide-blurb">#{escape(first_sentence(p.text))}</span></li>)
            end)

          nav = ~s(<nav class="help-guide-pages"><h2>#{escape(t(ctx, :guide_pages))}</h2><ul>#{items}</ul></nav>)
          %{page | html: Map.new(page.html, fn {speed, h} -> {speed, h <> nav} end)}
        end

      {slug, page}
    end)
  end

  defp first_sentence(text) do
    s =
      case Regex.run(~r/^.*?[.!?](?=\s|$)/u, text || "") do
        [m] -> m
        _ -> text || ""
      end

    if String.length(s) > 160, do: String.slice(s, 0, 157) <> "…", else: s
  end

  defp ref_html(slug, label, anchor \\ nil)

  defp ref_html(slug, label, nil),
    do: ~s(<a href="/help/#{escape(slug)}" class="help-ref" data-help="#{escape(slug)}">#{escape(label)}</a>)

  defp ref_html(slug, label, anchor) do
    ~s(<a href="/help/#{escape(slug)}##{escape(anchor)}" class="help-ref" data-help="#{escape(slug)}" data-anchor="#{escape(anchor)}">#{escape(label)}</a>)
  end

  @doc """
  Expands tables, charts, text tokens and links in a body for one speed.
  Returns `{markdown, placeholders, issues}` where `placeholders` maps the
  opaque markers left in the markdown to the HTML that replaces them after
  rendering.
  """
  def expand(body, ctx, slug) do
    {body, table_issues} = expand_tables(body, ctx, slug)
    {body, chart_placeholders, chart_issues} = expand_charts(body, ctx, slug)

    inline = Regex.scan(@inline_re, body) |> Enum.map(&List.first/1) |> Enum.uniq()
    links = Regex.scan(@link_re, body) |> Enum.map(&List.first/1) |> Enum.uniq()

    resolved =
      Map.new(inline ++ links, fn full ->
        {full, resolve(full, ctx, slug)}
      end)

    md =
      body
      |> then(&Regex.replace(@inline_re, &1, fn full, _, _, _ -> resolved[full].text end))
      |> then(&Regex.replace(@link_re, &1, fn full, _, _ -> resolved[full].text end))

    placeholders =
      for {_, %{html: html, text: ph}} when is_binary(html) <- resolved, into: chart_placeholders, do: {ph, html}

    issues = table_issues ++ chart_issues ++ Enum.flat_map(resolved, fn {_, r} -> r.issues end)
    {md, placeholders, issues}
  end

  defp expand_tables(body, ctx, slug) do
    matches = Regex.scan(@table_re, body) |> Enum.uniq()

    Enum.reduce(matches, {body, []}, fn [full, gen, args], {acc, issues} ->
      args = args |> String.trim() |> String.split(~r/\s+/, trim: true)

      case Tables.render(ctx, gen, args) do
        {:ok, md} ->
          {String.replace(acc, full, "\n" <> md <> "\n"), issues}

        {:error, msg} ->
          marker = "**[#{t(ctx, :missing_table)}: #{gen}]**"
          {String.replace(acc, full, marker), [Source.issue(:error, slug, "table #{gen}: #{msg}") | issues]}
      end
    end)
  end

  defp expand_charts(body, ctx, slug) do
    @chart_re
    |> Regex.scan(body)
    |> Enum.uniq()
    |> Enum.reduce({body, %{}, []}, fn [full, name, args | rest], {acc, phs, issues} ->
      caption = Enum.find(rest, &(&1 != ""))
      args = args |> String.trim() |> String.split(~r/\s+/, trim: true)

      case Charts.render(ctx, name, args) do
        {:ok, chart} ->
          ph = placeholder(full)

          html =
            ~s(<figure class="help-chart"><div class="help-unit-tick">#{chart.tick}</div>) <>
              ~s(<div class="help-unit-hour">#{chart.hour}</div>) <>
              ~s(<figcaption>#{escape(caption || chart.caption)}</figcaption></figure>)

          {String.replace(acc, full, "\n\n" <> ph <> "\n\n"), Map.put(phs, ph, html), issues}

        {:error, msg} ->
          {String.replace(acc, full, "**[missing chart: #{name}]**"), phs,
           [Source.issue(:error, slug, "chart #{name}: #{msg}") | issues]}
      end
    end)
  end

  defp resolve(full, ctx, slug) do
    case Regex.run(@inline_re, full) do
      [_, kind, arg, label] ->
        resolve_inline(kind, String.trim(arg), blank_to_nil(label), full, ctx, slug)

      [_, kind, arg] ->
        resolve_inline(kind, String.trim(arg), nil, full, ctx, slug)

      nil ->
        case Regex.run(@link_re, full) do
          [_, target, label] -> resolve_link(String.trim(target), blank_to_nil(label), full, ctx, slug)
          [_, target] -> resolve_link(String.trim(target), nil, full, ctx, slug)
        end
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp resolve_inline("icon", name, label, full, ctx, slug) do
    issues =
      if ctx.icons_available? and not MapSet.member?(ctx.icons, name),
        do: [Source.issue(:error, slug, "unknown icon `#{name}`")],
        else: []

    title = label || icon_title(ctx, name)
    html = ~s(<i class="help-icon" data-icon="#{escape(name)}" title="#{escape(title)}"></i>)
    %{text: placeholder(full), html: html, issues: issues}
  end

  defp resolve_inline("const", key, _label, _full, ctx, slug) do
    case const_value(key, ctx, slug) do
      {:ok, value, issues} -> %{text: Format.num(value), html: nil, issues: issues}
      {:error, issues} -> %{text: "?", html: nil, issues: issues}
    end
  end

  defp resolve_inline("rate", arg, noun, full, ctx, slug) do
    case number_or_const(arg, ctx, slug) do
      {:ok, v, issues} ->
        noun = if noun, do: " #{noun}", else: ""
        tick = "#{sig(v)}#{noun} #{t(ctx, :per_tick)}"
        hour = "#{sig(v * ctx.ticks_per_hour[ctx.speed])}#{noun} #{t(ctx, :per_hour)}"
        %{text: placeholder(full), html: units_html("help-rate", tick, hour), issues: issues}

      {:error, issues} ->
        %{text: "?", html: nil, issues: issues}
    end
  end

  defp resolve_inline("duration", arg, _label, full, ctx, slug) do
    case number_or_const(arg, ctx, slug) do
      {:ok, v, issues} ->
        hours = v / ctx.ticks_per_hour[ctx.speed]
        tick = "#{sig(v)} #{t(ctx, if(v == 1, do: :tick, else: :ticks))}"
        hour = "#{sig(hours)} #{t(ctx, if(hours == 1, do: :hour, else: :hours))}"
        %{text: placeholder(full), html: units_html("help-duration", tick, hour), issues: issues}

      {:error, issues} ->
        %{text: "?", html: nil, issues: issues}
    end
  end

  defp resolve_inline("shot", arg, caption, full, ctx, slug) do
    {name, marks} =
      case String.split(arg, "#", parts: 2) do
        [name, marks] -> {name, marks |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}
        [name] -> {name, []}
      end

    case Map.get(ctx.shots, name) do
      nil ->
        %{
          text: caption || name,
          html: nil,
          issues: [
            Source.issue(:error, slug, "unknown screenshot `#{name}` (priv/help/shots/manifest.json, capture with e2e/help-shots)")
          ]
        }

      shot ->
        known = Map.get(shot, "marks", %{})
        numbered? = length(marks) > 1

        {spans, issues} =
          marks
          |> Enum.with_index(1)
          |> Enum.map_reduce([], fn {mark, n}, issues ->
            case Map.get(known, mark) do
              %{"x" => x, "y" => y, "w" => w, "h" => h} ->
                style = "left:#{pct(x)}%;top:#{pct(y)}%;width:#{pct(w)}%;height:#{pct(h)}%"
                n_attr = if numbered?, do: ~s( data-n="#{n}"), else: ""
                {~s(<span class="help-shot-mark"#{n_attr} style="#{style}"></span>), issues}

              _ ->
                {"", [Source.issue(:error, slug, "screenshot `#{name}` has no mark `#{mark}`") | issues]}
            end
          end)

        w = shot["width"]
        h = shot["height"]
        caption_html = if caption, do: "<figcaption>#{escape(caption)}</figcaption>", else: ""

        html =
          ~s(<figure class="help-shot" data-shot="#{escape(name)}"><div class="help-shot-frame" style="aspect-ratio: #{w} / #{h}">) <>
            ~s(<img src="/img/help/shots/#{escape(shot["file"])}" alt="#{escape(shot["alt"] || "")}" width="#{w}" height="#{h}" loading="lazy">) <>
            Enum.join(spans) <> "</div>" <> caption_html <> "</figure>"

        %{text: placeholder(full), html: html, issues: Enum.reverse(issues)}
    end
  end

  defp resolve_inline("name", key, _label, _full, ctx, slug) do
    path = String.split(key, ".")

    if has_data_key?(ctx, path ++ ["name"]) do
      # Some data.json names carry <strong> for the game's own rendering.
      %{text: ui_text(singular(data_name(ctx, path ++ ["name"]))), html: nil, issues: []}
    else
      %{text: List.last(path), html: nil, issues: [Source.issue(:error, slug, "unknown name `#{key}` (data.json)")]}
    end
  end

  defp resolve_inline("ui", key, _label, _full, ctx, slug) do
    case ui(ctx, key) do
      s when is_binary(s) -> %{text: ui_text(s), html: nil, issues: []}
      _ -> %{text: key, html: nil, issues: [Source.issue(:error, slug, "unknown UI string `#{key}` (game.json)")]}
    end
  end

  defp const_value(key, ctx, slug) do
    case Enum.find(Map.keys(ctx.consts[:slow]), &(to_string(&1) == key)) do
      nil ->
        {:error, [Source.issue(:error, slug, "unknown constant `#{key}`")]}

      atom ->
        missing = for {speed, map} <- ctx.consts, not Map.has_key?(map, atom), do: speed

        issues =
          if missing == [],
            do: [],
            else: [Source.issue(:error, slug, "constant `#{key}` missing for speeds #{inspect(missing)}")]

        {:ok, Map.get(ctx.consts[ctx.speed], atom), issues}
    end
  end

  defp number_or_const(arg, ctx, slug) do
    case Float.parse(arg) do
      {n, ""} -> {:ok, if(n == trunc(n), do: trunc(n), else: n), []}
      _ -> const_value(arg, ctx, slug)
    end
  end

  defp units_html(class, tick, hour) do
    ~s(<span class="#{class}"><span class="help-unit-tick">#{escape(tick)}</span><span class="help-unit-hour">#{escape(hour)}</span></span>)
  end

  defp pct(v), do: :erlang.float_to_binary(v * 100.0, decimals: 2)

  # UI strings may carry a little HTML (<strong>, <em>, <br>) for v-html
  # rendering. Markdown would escape it, so translate the emphasis to
  # markdown and drop anything else before the string joins the page.
  @doc false
  def ui_text(s) do
    s
    |> String.replace(~r/<\/?strong>/, "**")
    |> String.replace(~r/<\/?(?:em|i)>/, "*")
    |> String.replace(~r/<br\s*\/?>/, " ")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&nbsp;", " ")
  end

  defp resolve_link(target, label, full, ctx, slug) do
    canonical = if Map.has_key?(ctx.index.slugs, target), do: target, else: ctx.index.aliases[target]

    case canonical do
      nil ->
        %{text: label || target, html: nil, issues: [Source.issue(:error, slug, "unknown link target `#{target}`")]}

      canonical ->
        case Map.get(ctx.index.alias_anchors, target) do
          %{anchor: anchor, heading: heading} ->
            %{text: placeholder(full), html: ref_html(canonical, label || heading, anchor), issues: []}

          nil ->
            text = label || default_label(target, ctx.index.slugs[canonical] || canonical)
            %{text: placeholder(full), html: ref_html(canonical, text), issues: []}
        end
    end
  end

  # `[[taxes]]` reads as "taxes" mid-sentence; `[[building/hab-open]]` is not
  # readable as typed, so prefixed or hyphenated targets fall back to the title.
  defp default_label(target, title) do
    if String.contains?(target, ["/", "-"]), do: title, else: target
  end

  defp placeholder(full), do: "HELPPH#{:erlang.phash2(full)}END"

  # Block placeholders (charts, screenshots) sit alone in a paragraph; the
  # <p> wrapper is dropped so a <figure> never ends up inside a <p>.
  @doc false
  def render(md, placeholders) do
    html = RC.Markdown.render_inline(md, smartypants: false)

    Enum.reduce(placeholders, html, fn {ph, h}, acc ->
      acc |> String.replace("<p>#{ph}</p>", h) |> String.replace(ph, h)
    end)
  end

  defp escape(s), do: s |> to_string() |> Plug.HTML.html_escape()

  @doc "Tooltip for an icon: the UI name of the thing it depicts, when known."
  def icon_title(ctx, name), do: icon_title_parts(ctx, String.split(name, "/"))

  @named_groups ~w(building patent doctrine ship stellar_body stellar_system faction)

  defp icon_title_parts(ctx, [group, key]) when group in @named_groups, do: data_name(ctx, [group, key, "name"])

  defp icon_title_parts(ctx, ["agent", key]) when key in ~w(admiral speaker spy),
    do: singular(data_name(ctx, ["character", key, "name"]))

  defp icon_title_parts(ctx, ["resource", key]) do
    case Enum.find(Data.pipeline_out(), &(&1.to == :stellar_system and to_string(&1.to_key) == key)) do
      nil -> humanize(key)
      out -> Format.pipeline_out_name(ctx, out.key)
    end
  end

  # character_reaction.* strings read "<strong>Fury</strong>, attacks…"; the name is the strong part.
  defp icon_title_parts(ctx, ["reaction", key]) do
    with s when is_binary(s) <- ui(ctx, "character_reaction.#{key}"),
         [_, name] <- Regex.run(~r/<strong>(.*?)<\/strong>/, s) do
      name
    else
      _ -> humanize(key)
    end
  end

  defp icon_title_parts(ctx, ["action", key]) do
    case ui(ctx, "galaxy.system.actions.#{key}") do
      s when is_binary(s) -> s
      _ -> humanize(key)
    end
  end

  defp icon_title_parts(_ctx, parts), do: parts |> List.last() |> humanize()

  defp humanize(key), do: key |> String.replace(~r/[_-]+/, " ") |> String.capitalize()

  defp to_text(nil), do: ""

  defp to_text(html) do
    html
    # Chart drawings and the per-hour variants are not searchable text.
    |> String.replace(~r/<svg\b.*?<\/svg>/s, " ")
    |> String.replace(~r/<(span|div) class="help-unit-hour">.*?<\/\1>/s, " ")
    # Block boundaries become spaces so words never fuse; inline tags vanish.
    |> String.replace(~r/<\/?(?:p|li|ul|ol|h[1-6]|td|th|tr|table|thead|tbody|pre|blockquote|br|figure|figcaption|div)\b[^>]*>/, " ")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(["&amp;", "&lt;", "&gt;", "&quot;", "&#39;", "&nbsp;"], fn
      "&amp;" -> "&"
      "&lt;" -> "<"
      "&gt;" -> ">"
      "&quot;" -> "\""
      "&#39;" -> "'"
      "&nbsp;" -> " "
    end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # -- lint ------------------------------------------------------------------

  defp lint_meta(%Page{} = page, ctx) do
    icon =
      if page.icon && ctx.icons_available? && not MapSet.member?(ctx.icons, page.icon),
        do: [Source.issue(:error, page.slug, "unknown icon `#{page.icon}` in frontmatter")],
        else: []

    related =
      for r <- page.related,
          not Map.has_key?(ctx.index.slugs, r),
          not Map.has_key?(ctx.index.aliases, r),
          do: Source.issue(:error, page.slug, "unknown related page `#{r}`")

    sources =
      for s <- page.sources,
          path = s |> String.split(":") |> hd(),
          not File.exists?(Path.expand(path, File.cwd!())),
          do: Source.issue(:warning, page.slug, "source file not found: #{path}")

    terms =
      if page.kind in [:mechanic, :guide] and page.terms == [],
        do: [Source.issue(:warning, page.slug, "no `terms:`; the page will be missing from the glossary")],
        else: []

    guide =
      cond do
        is_nil(page.guide) ->
          []

        Map.get(ctx.index.kinds, page.guide) == :guide ->
          []

        Map.has_key?(ctx.index.slugs, page.guide) ->
          [Source.issue(:error, page.slug, "`guide: #{page.guide}` is not a guide page (it needs `kind: guide`)")]

        true ->
          [Source.issue(:error, page.slug, "unknown guide `#{page.guide}`")]
      end

    icon ++ related ++ sources ++ terms ++ guide
  end

  @doc false
  def lint_prose(%Page{} = page) do
    prose =
      page.body
      |> String.replace(@fence_re, " ")
      |> String.replace(@indented_code_re, " ")
      |> String.replace(@table_re, " ")
      |> String.replace(@chart_re, " ")
      |> String.replace(@inline_re, " ")
      |> then(&Regex.replace(@link_re, &1, fn _, t, label -> if label == "", do: t, else: label end))
      |> String.replace(~r/^#+\s.*$/m, " ")
      |> String.replace(~r/^\s*\|.*\|\s*$/m, " ")

    words = prose |> String.split(~r/\s+/, trim: true) |> length()
    cap = Map.get(@max_words, page.kind)

    # Style rule 18: the cap is a signal. A page that is long on purpose says
    # so (`length: long` + `length_reason:`) instead of squeezing sentences.
    length_issue =
      cond do
        page.length == "long" and String.trim(page.length_reason || "") == "" ->
          [Source.issue(:warning, page.slug, "`length: long` needs a `length_reason:` saying why the page is long")]

        page.length == "long" ->
          []

        cap && words > cap ->
          [
            Source.issue(
              :warning,
              page.slug,
              "#{words} words of prose; the cap for a #{page.kind} page is #{cap}. " <>
                "Link or split a second topic, or record `length: long` with a `length_reason:` (never cut meaning to fit)"
            )
          ]

        true ->
          []
      end

    internal = @forbidden_internal |> Regex.scan(prose) |> Enum.map(&(&1 |> hd() |> String.downcase())) |> Enum.uniq()
    tone = @forbidden_tone |> Regex.scan(prose) |> Enum.map(&(&1 |> hd() |> String.downcase())) |> Enum.uniq()

    internal_issue =
      if internal == [],
        do: [],
        else: [
          Source.issue(:warning, page.slug, "internal names in prose (use UI names): #{Enum.join(internal, ", ")}")
        ]

    tone_issue =
      if tone == [],
        do: [],
        else: [Source.issue(:warning, page.slug, "adjectives of quality: #{Enum.join(tone, ", ")}")]

    semicolons = length(Regex.scan(~r/;/, prose))

    semicolon_issue =
      if semicolons > 0,
        do: [Source.issue(:warning, page.slug, "#{semicolons} semicolon(s) in prose: split into separate sentences")],
        else: []

    dashes = length(Regex.scan(~r/[—–]/u, prose))

    dash_issue =
      if dashes > 0,
        do: [Source.issue(:warning, page.slug, "#{dashes} dash(es) in prose: use a period or a plain sentence instead")],
        else: []

    long =
      prose
      |> String.split(~r/(?<=[.!?:])\s+|\n\s*\n|\n\s*[-*]\s+/u, trim: true)
      |> Enum.map(&String.split(&1, ~r/\s+/, trim: true))
      |> Enum.filter(&(length(&1) > @max_sentence_words))

    long_issue =
      if long == [],
        do: [],
        else: [
          Source.issue(
            :warning,
            page.slug,
            "#{length(long)} sentence(s) over #{@max_sentence_words} words: " <>
              Enum.map_join(Enum.take(long, 3), "; ", &("\"" <> Enum.join(Enum.take(&1, 6), " ") <> " …\""))
          )
        ]

    typed_time = @typed_time_re |> Regex.scan(prose) |> Enum.map(&hd/1) |> Enum.uniq()

    time_issue =
      if typed_time == [],
        do: [],
        else: [
          Source.issue(
            :warning,
            page.slug,
            "time typed in prose (#{Enum.join(Enum.take(typed_time, 3), ", ")}): use {rate:} or {duration:}"
          )
        ]

    length_issue ++ internal_issue ++ tone_issue ++ semicolon_issue ++ dash_issue ++ long_issue ++ time_issue
  end

  defp cross_page_issues(pages) do
    pages
    |> Enum.flat_map(fn p -> Enum.map(p.terms, &{String.downcase(&1), p.slug}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_, slugs} -> length(Enum.uniq(slugs)) > 1 end)
    |> Enum.map(fn {term, slugs} ->
      Source.issue(:warning, hd(slugs), "term `#{term}` claimed by several pages: #{Enum.join(Enum.uniq(slugs), ", ")}")
    end)
  end
end
