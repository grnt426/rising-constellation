defmodule RC.Help do
  @moduledoc """
  The compiled help manual. `priv/help/**/*.md`, the front-end locale files
  and the game content modules are compiled into this module's constants,
  so `RC.Help.page/2` is a map lookup at runtime and every consumer (the
  public `/help` pages, the SPA bundle endpoint) reads the same artifact.

  Lint problems do not fail compilation; they are reported by
  `mix help.check` (and as a one-line compile warning) so a broken link
  cannot take the game down but cannot pass CI either.

  Design: `docs/help-manual.md`.
  """

  alias RC.Help.{Compiler, Data, Page, Source}

  @langs ["en", "fr"]

  shots = Enum.filter([Data.shots_file()], &File.exists?/1)

  # The page files this build was compiled from. A new page is not an
  # @external_resource of the previous compile, so Mix would never notice it
  # (a restart kept serving the old manual): __mix_recompile__?/0 recompiles
  # whenever the set of files changes, not only when a listed file does.
  @source_files Source.files(@langs)

  for path <- @source_files ++ Data.locale_files(@langs) ++ Data.content_files() ++ shots ++ RC.SystemPlanner.Presets.files() do
    @external_resource path
  end

  # The "Basics of Play" pages, in reading order. Both manual indexes show
  # them as cards above the page list, and leave them out of that list.
  @featured ~w(strategy-basics early-game resource-focus late-game)

  @doc false
  def __mix_recompile__?, do: Source.files(@langs) != @source_files

  @build Compiler.build(langs: @langs)

  # The whole manual is one multi-megabyte term. Each `@build` in a function
  # body pastes its own copy of it into that function, and every copy costs
  # the compiler seconds: ten of them made this file 21s of a 26s project
  # compile, and a 7MB beam. Functions read it through this one accessor.
  defp build, do: @build

  if @build.errors != [] do
    IO.puts(:stderr, "help manual: #{length(@build.errors)} lint error(s) — run `mix help.check`")
  end

  # Speed display names ("Flash" / "Tactic" / "Legacy") per language, from
  # data.json, frozen here because the locale files are not shipped in the
  # release.
  @speed_names Map.new(@langs, fn lang ->
                 locale = Data.locale(lang) || Data.locale("en") || %{data: %{}}

                 {lang,
                  Map.new(Data.speeds(), fn speed ->
                    {speed, get_in(locale.data, ["speed", Atom.to_string(speed), "name"]) || Atom.to_string(speed)}
                  end)}
               end)

  @doc "Display names of the speeds for a language, e.g. `%{slow: \"Legacy\"}`."
  def speed_names(lang), do: Map.get(@speed_names, lang) || Map.fetch!(@speed_names, "en")

  # Changes whenever any page, name or number changes; the SPA endpoint
  # uses it as an ETag.
  @version @build |> :erlang.phash2() |> Integer.to_string(36)

  @doc "Content fingerprint of the compiled manual."
  def version, do: @version

  @doc "Languages the manual is compiled for."
  def languages, do: @langs

  @doc "Speeds every page is compiled for."
  def speeds, do: Data.speeds()

  @doc "All pages of a language, keyed by slug."
  def pages(lang \\ "en"), do: Map.get(build().pages, lang) || Map.fetch!(build().pages, "en")

  @doc "One page by slug or alias, or `nil`."
  def page(slug, lang \\ "en") do
    case resolve(slug) do
      nil -> nil
      canonical -> Map.get(pages(lang), canonical)
    end
  end

  @doc "Canonical slug for a slug or alias, or `nil`."
  def resolve(slug) do
    cond do
      Map.has_key?(build().index.slugs, slug) -> slug
      Map.has_key?(build().index.aliases, slug) -> build().index.aliases[slug]
      true -> nil
    end
  end

  @doc """
  The anchor an alias opens its page at, or `nil`: a section's heading id
  (`aliases: [taxes#taxes]`), or a patent family's level (`patent/infra_open_3`
  → `"level-3"`).
  """
  def alias_anchor(slug), do: get_in(build().index.alias_anchors, [slug, :anchor])

  @doc """
  The Basics of Play pages in reading order, each with its one-line summary
  (the page's opening sentence): `[%{slug:, title:, icon:, summary:}]`.
  """
  def featured(lang \\ "en") do
    pages = pages(lang)

    for slug <- @featured, %Page{} = p <- [Map.get(pages, slug)] do
      %{slug: p.slug, title: p.title, icon: p.icon, summary: Compiler.first_sentence(p.text)}
    end
  end

  @doc "Heading of the Basics of Play cards."
  def featured_title(lang \\ "en"), do: RC.Help.Format.t(%{lang: lang}, :basics_of_play)

  def slugs, do: build().index.slugs |> Map.keys() |> Enum.sort()
  def categories, do: build().index.categories

  @doc "Lint errors found at compile time (`[%{level:, page:, msg:}]`)."
  def errors, do: build().errors

  @doc "Lint warnings found at compile time."
  def warnings, do: build().warnings

  @doc """
  JSON-ready bundle for one language and speed: what the SPA fetches once
  and what the public pages render from.
  """
  def bundle(lang, speed) when speed in [:fast, :medium, :slow] do
    pages = pages(lang)

    %{
      lang: lang,
      speed: speed,
      featured: %{title: featured_title(lang), pages: featured(lang)},
      pages:
        pages
        |> Map.values()
        |> Enum.sort_by(& &1.slug)
        |> Enum.map(fn %Page{} = p ->
          %{
            slug: p.slug,
            title: p.title,
            category: p.category,
            kind: p.kind,
            icon: p.icon,
            terms: p.terms,
            related: p.related,
            # Section aliases (`name#anchor`) resolve by name in the SPA store,
            # which opens the page at the alias's anchor.
            aliases: Enum.map(p.aliases, &(&1 |> String.split("#") |> hd())),
            alias_anchors: for(a <- p.aliases, [name, anchor] <- [String.split(a, "#", parts: 2)], into: %{}, do: {name, anchor}),
            status: p.status,
            speed_sensitive: p.speed_sensitive,
            html: Map.fetch!(p.html, speed),
            text: p.text
          }
        end),
      categories:
        build().index.categories
        |> Enum.sort()
        |> Enum.map(fn {key, slugs} ->
          %{key: key, title: key |> String.replace("-", " ") |> String.capitalize(), slugs: slugs}
        end),
      glossary:
        pages
        |> Map.values()
        |> Enum.flat_map(fn p -> Enum.map(p.terms, &%{term: &1, slug: p.slug, title: p.title}) end)
        |> Enum.sort_by(&String.downcase(&1.term))
    }
  end
end
