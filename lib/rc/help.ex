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

  for path <- @source_files ++ Data.locale_files(@langs) ++ Data.content_files() ++ shots do
    @external_resource path
  end

  @doc false
  def __mix_recompile__?, do: Source.files(@langs) != @source_files

  @build Compiler.build(langs: @langs)

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
  def pages(lang \\ "en"), do: Map.get(@build.pages, lang) || Map.fetch!(@build.pages, "en")

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
      Map.has_key?(@build.index.slugs, slug) -> slug
      Map.has_key?(@build.index.aliases, slug) -> @build.index.aliases[slug]
      true -> nil
    end
  end

  def slugs, do: @build.index.slugs |> Map.keys() |> Enum.sort()
  def categories, do: @build.index.categories

  @doc "Lint errors found at compile time (`[%{level:, page:, msg:}]`)."
  def errors, do: @build.errors

  @doc "Lint warnings found at compile time."
  def warnings, do: @build.warnings

  @doc """
  JSON-ready bundle for one language and speed: what the SPA fetches once
  and what the public pages render from.
  """
  def bundle(lang, speed) when speed in [:fast, :medium, :slow] do
    pages = pages(lang)

    %{
      lang: lang,
      speed: speed,
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
            # Section aliases (`name#anchor`) resolve by name in the SPA store.
            aliases: Enum.map(p.aliases, &(&1 |> String.split("#") |> hd())),
            status: p.status,
            speed_sensitive: p.speed_sensitive,
            html: Map.fetch!(p.html, speed),
            text: p.text
          }
        end),
      categories:
        @build.index.categories
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
