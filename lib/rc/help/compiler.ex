defmodule RC.Help.Compiler do
  @moduledoc """
  Turns `priv/help` sources into per-language, per-speed HTML plus a lint
  report. Pure functions over `RC.Help.Data`; `RC.Help` calls `build/1` at
  compile time.

  Token syntax (see `docs/help-manual.md` §3.1):

      {icon:group/name}           inline icon, tooltip = UI name (or `{icon:x|Label}`)
      {const:key}                 Data.Game.Constant value for the current speed
      {name:type.key}             localized name from data.json (`{name:building.hab_open}`)
      {ui:path.to.key}            UI string from game.json
      [[slug]] / [[slug|label]]   link to another page (aliases resolve; a bare plain-word
                                  slug is shown as typed, other slugs show the page title)
      {table:generator args}      generated table, see RC.Help.Tables

  Text tokens are substituted before markdown rendering. Icons and links
  become placeholders, survive markdown + sanitizer untouched, and are
  swapped for their HTML afterwards, so the sanitizer never sees (and never
  strips) the `class` / `data-*` attributes they need.
  """

  alias RC.Help.{Data, Format, Page, Source, Tables}
  import RC.Help.Format, only: [t: 2, data_name: 2, has_data_key?: 2, ui: 2, singular: 1]

  @inline_re ~r/\{(icon|const|name|ui):([^}|]+?)(?:\|([^}]*))?\}/
  @table_re ~r/\{table:([a-z_]+)([^}]*)\}/
  @link_re ~r/\[\[([^\]|]+?)(?:\|([^\]]*))?\]\]/
  @fence_re ~r/```.*?```/s
  @indented_code_re ~r/^(?: {4}|\t).*$/m

  # Style rule 3: UI names only. Rule 4: no adjectives of quality.
  @forbidden_internal ~r/\b(admirals?|speakers?|sp(?:y|ies)|doctrines?|sys_[a-z_]+|[a-z]+_coef)\b/i
  @forbidden_tone ~r/\b(powerful|crucial|amazing|exciting|essential|incredible|vital|game-changing)\b/i
  @max_words 250

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
        {Map.put(acc, lang, Map.new(compiled, &{&1.slug, &1})), issues}
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
      index: index,
      icons: Data.icons(),
      icons_available?: Data.icons_available?(),
      en: en || %{data: %{}, game: %{}},
      locale_missing?: is_nil(en),
      consts: Map.new(Data.speeds(), &{&1, Data.constants(&1)})
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

    {aliases, issues} =
      pages
      |> Enum.flat_map(fn p -> Enum.map(p.aliases, &{&1, p.slug}) end)
      |> Enum.reduce({%{}, issues}, &add_alias(&1, &2, slugs))

    categories = pages |> Enum.group_by(& &1.category, & &1.slug) |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)
    {%{slugs: slugs, aliases: aliases, categories: categories}, Enum.reverse(issues)}
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
        html = render(md, placeholders)
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
  Expands tables, text tokens and links in a body for one speed. Returns
  `{markdown, placeholders, issues}` where `placeholders` maps the opaque
  markers left in the markdown to the HTML that replaces them after
  rendering.
  """
  def expand(body, ctx, slug) do
    {body, table_issues} = expand_tables(body, ctx, slug)

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
      for {_, %{html: html, text: ph}} when is_binary(html) <- resolved, into: %{}, do: {ph, html}

    issues = table_issues ++ Enum.flat_map(resolved, fn {_, r} -> r.issues end)
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
    case Enum.find(Map.keys(ctx.consts[:slow]), &(to_string(&1) == key)) do
      nil ->
        %{text: "?", html: nil, issues: [Source.issue(:error, slug, "unknown constant `#{key}`")]}

      atom ->
        missing = for {speed, map} <- ctx.consts, not Map.has_key?(map, atom), do: speed

        issues =
          if missing == [],
            do: [],
            else: [Source.issue(:error, slug, "constant `#{key}` missing for speeds #{inspect(missing)}")]

        %{text: Format.num(Map.get(ctx.consts[ctx.speed], atom)), html: nil, issues: issues}
    end
  end

  defp resolve_inline("name", key, _label, _full, ctx, slug) do
    path = String.split(key, ".")

    if has_data_key?(ctx, path ++ ["name"]) do
      %{text: singular(data_name(ctx, path ++ ["name"])), html: nil, issues: []}
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
        text = label || default_label(target, ctx.index.slugs[canonical] || canonical)

        html =
          ~s(<a href="/help/#{escape(canonical)}" class="help-ref" data-help="#{escape(canonical)}">#{escape(text)}</a>)

        %{text: placeholder(full), html: html, issues: []}
    end
  end

  # `[[taxes]]` reads as "taxes" mid-sentence; `[[building/hab-open]]` is not
  # readable as typed, so prefixed or hyphenated targets fall back to the title.
  defp default_label(target, title) do
    if String.contains?(target, ["/", "-"]), do: title, else: target
  end

  defp placeholder(full), do: "HELPPH#{:erlang.phash2(full)}END"

  @doc false
  def render(md, placeholders) do
    html = RC.Markdown.render_inline(md, smartypants: false)
    Enum.reduce(placeholders, html, fn {ph, h}, acc -> String.replace(acc, ph, h) end)
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
    # Block boundaries become spaces so words never fuse; inline tags vanish.
    |> String.replace(~r/<\/?(?:p|li|ul|ol|h[1-6]|td|th|tr|table|thead|tbody|pre|blockquote|br)\b[^>]*>/, " ")
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
      if page.kind == :mechanic and page.terms == [],
        do: [Source.issue(:warning, page.slug, "no `terms:`; the page will be missing from the glossary")],
        else: []

    icon ++ related ++ sources ++ terms
  end

  @doc false
  def lint_prose(%Page{} = page) do
    prose =
      page.body
      |> String.replace(@fence_re, " ")
      |> String.replace(@indented_code_re, " ")
      |> String.replace(@table_re, " ")
      |> String.replace(@inline_re, " ")
      |> then(&Regex.replace(@link_re, &1, fn _, _t, label -> label end))
      |> String.replace(~r/^#+\s.*$/m, " ")

    words = prose |> String.split(~r/\s+/, trim: true) |> length()

    length_issue =
      if page.kind == :mechanic and words > @max_words,
        do: [Source.issue(:warning, page.slug, "#{words} words of prose; the cap for a mechanic page is #{@max_words}")],
        else: []

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

    length_issue ++ internal_issue ++ tone_issue
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
