defmodule Portal.HelpLive do
  @moduledoc """
  Public help manual: `/help` (index, search, glossary) and `/help/:slug`.

  Everything comes from the compile-time bundle in `RC.Help`; this module
  only picks the language and speed, swaps the compiled icon markers for
  `<svg><use>` references into the sprite, and renders. The first (dead)
  render is complete HTML, so the pages work and are crawlable without JS.

  Query params: `speed=fast|medium|slow` (default slow, the Legacy rules),
  `lang=en|fr` (default en), `unit=tick|hour` (default tick: which of the
  two compiled rate/duration variants shows, see `.help-units-hour` in
  `_help.scss`), `q=` search on the index.
  """

  use Portal, :live_view

  alias RC.Help

  defmodule NotFound do
    defexception message: "help page not found", plug_status: 404
  end

  @speeds %{"fast" => :fast, "medium" => :medium, "slow" => :slow}
  @default_speed :slow
  @default_lang "en"
  @units ["tick", "hour"]
  @default_unit "tick"
  @icon_re ~r/<i class="help-icon" data-icon="([^"]+)" title="([^"]*)"><\/i>/
  @link_re ~r/href="\/help\/([^"?#]+)"/

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    lang = if params["lang"] in Help.languages(), do: params["lang"], else: @default_lang
    speed = Map.get(@speeds, params["speed"], @default_speed)
    unit = if params["unit"] in @units, do: params["unit"], else: @default_unit
    query = String.trim(params["q"] || "")

    socket =
      assign(socket,
        lang: lang,
        speed: speed,
        unit: unit,
        query: query,
        speed_names: Help.speed_names(lang),
        sprite: Routes.static_path(socket, "/img/help-icons.svg"),
        link_query: link_query(lang, speed, unit)
      )

    case socket.assigns.live_action do
      :show -> {:noreply, show(socket, params["slug"])}
      _ -> {:noreply, index(socket)}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(query: String.trim(q)) |> index()}
  end

  defp index(socket) do
    %{lang: lang, speed: speed, query: query} = socket.assigns
    bundle = Help.bundle(lang, speed)
    by_slug = Map.new(bundle.pages, &{&1.slug, &1})

    assign(socket,
      page: nil,
      page_title: "Manual",
      categories:
        Enum.map(bundle.categories, fn cat ->
          %{cat | slugs: cat.slugs |> Enum.map(&by_slug[&1]) |> Enum.reject(&is_nil/1) |> Enum.sort_by(& &1.title)}
        end),
      glossary: bundle.glossary,
      results: if(query == "", do: nil, else: search(bundle.pages, query)),
      page_count: length(bundle.pages)
    )
  end

  defp show(socket, slug) do
    %{lang: lang, speed: speed} = socket.assigns
    page = Help.page(slug, lang) || raise NotFound, message: "no help page #{inspect(slug)}"
    pages = Help.pages(lang)
    html = prepare_html(Map.fetch!(page.html, speed), socket.assigns)

    assign(socket,
      page: page,
      page_title: "#{page.title} — Manual",
      html: html,
      # The per tick / per hour toggle only shows on pages that have rates.
      show_units: String.contains?(html, "help-unit-"),
      related:
        page.related
        |> Enum.map(&Help.resolve/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&{&1, pages[&1].title})
    )
  end

  defp search(pages, query) do
    q = String.downcase(query)

    pages
    |> Enum.filter(fn p ->
      String.contains?(String.downcase(p.title), q) or
        Enum.any?(p.terms, &String.contains?(String.downcase(&1), q)) or
        String.contains?(String.downcase(p.text), q)
    end)
    |> Enum.sort_by(fn p -> {not String.contains?(String.downcase(p.title), q), p.title} end)
  end

  # Icons: the compiler emits <i class="help-icon" data-icon="group/name" title="…"></i>
  # (see RC.Help.Compiler); here they become <svg><use> into the sprite.
  # Links: keep a non-default speed/lang/unit while the reader follows [[links]].
  defp prepare_html(html, assigns) do
    html
    |> then(
      &Regex.replace(@icon_re, &1, fn _, name, title ->
        ~s(<svg class="help-icon" role="img" aria-label="#{title}"><title>#{title}</title><use href="#{assigns.sprite}##{sprite_id(name)}"/></svg>)
      end)
    )
    |> then(fn html ->
      if assigns.link_query == "",
        do: html,
        else: Regex.replace(@link_re, html, ~s(href="/help/\\1#{assigns.link_query}"))
    end)
  end

  @doc false
  def sprite_id(name), do: String.replace(name, "/", "--")

  # "" or "?lang=…&speed=…&unit=…" with only the non-default params. Public so
  # the template can build the speed and unit switch links with it.
  @doc false
  def link_query(lang, speed, unit) do
    params = []
    params = if speed == @default_speed, do: params, else: [{"speed", Atom.to_string(speed)} | params]
    params = if lang == @default_lang, do: params, else: [{"lang", lang} | params]
    params = if unit == @default_unit, do: params, else: params ++ [{"unit", unit}]
    if params == [], do: "", else: "?" <> URI.encode_query(params)
  end

  @doc false
  def other_speeds(speed), do: Enum.reject([:slow, :medium, :fast], &(&1 == speed))
end
