defmodule Mix.Tasks.Help.Check do
  @shortdoc "Lint the help manual sources (priv/help) and show compiled pages"

  @moduledoc """
  Compiles the project (which compiles the manual into `RC.Help`) and prints
  the lint report. Exits non-zero when there are errors, so CI can gate on
  it.

      mix help.check                       # report
      mix help.check --page mobility       # also print the compiled HTML (Legacy, en)
      mix help.check --page mobility --speed fast --lang fr
      mix help.check --text mobility       # print the plain-text search form instead
      mix help.check --live --only mobility,taxes

  `--live` skips compilation and builds the manual from the files on disk at
  run time, so it sees edits immediately and never touches `_build`. Several
  `--live` runs can go at once (the agent pipeline relies on this); run it
  with `mix run`'s build already compiled. `--only` limits the printed issues
  to a comma-separated list of slugs (the counts still cover every page).

  Errors: unknown links, icons, constants, names, UI strings, table
  generators; duplicate slugs/aliases; missing titles. Warnings: prose over
  the length cap, internal names or adjectives of quality in prose, missing
  terms, terms claimed by several pages, missing source files.
  """

  use Mix.Task

  @switches [
    page: :string,
    text: :string,
    speed: :string,
    lang: :string,
    quiet: :boolean,
    live: :boolean,
    only: :string
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    manual = if opts[:live], do: live(opts), else: compiled()

    if slug = opts[:page], do: show(manual, slug, opts, :html)
    if slug = opts[:text], do: show(manual, slug, opts, :text)

    only = if opts[:only], do: opts[:only] |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    shown? = fn issue -> is_nil(only) or issue.page in only end

    unless opts[:quiet] do
      manual.warnings |> Enum.filter(shown?) |> Enum.each(&print(&1, :yellow))
      manual.errors |> Enum.filter(shown?) |> Enum.each(&print(&1, :red))
    end

    Mix.shell().info(
      "help manual#{if opts[:live], do: " (live)"}: #{map_size(manual.pages.("en"))} page(s) × " <>
        "#{length(manual.langs)} language(s) × #{length(RC.Help.speeds())} speeds, " <>
        "#{length(manual.errors)} error(s), #{length(manual.warnings)} warning(s)"
    )

    if manual.errors != [] do
      Mix.shell().error("help.check failed")
      exit({:shutdown, 1})
    end
  end

  defp compiled do
    Mix.Task.run("compile")

    %{
      langs: RC.Help.languages(),
      errors: RC.Help.errors(),
      warnings: RC.Help.warnings(),
      pages: &RC.Help.pages/1,
      page: &RC.Help.page/2
    }
  end

  defp live(opts) do
    Mix.Task.run("loadpaths", ["--no-compile"])
    lang = opts[:lang] || "en"
    langs = Enum.uniq(["en", lang])
    build = RC.Help.Compiler.build(langs: langs)
    pages = fn l -> Map.get(build.pages, l) || Map.fetch!(build.pages, "en") end

    %{
      langs: langs,
      errors: build.errors,
      warnings: build.warnings,
      pages: pages,
      page: fn slug, l -> Map.get(pages.(l), Map.get(build.index.aliases, slug, slug)) end
    }
  end

  defp show(manual, slug, opts, what) do
    lang = opts[:lang] || "en"
    speed = Enum.find(RC.Help.speeds(), :slow, &(Atom.to_string(&1) == (opts[:speed] || "slow")))

    case manual.page.(slug, lang) do
      nil ->
        known = manual.pages.(lang) |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        Mix.shell().error("no page `#{slug}` (known: #{known})")

      page ->
        Mix.shell().info("# #{page.title} [#{page.slug}] #{lang}/#{speed} speed_sensitive=#{page.speed_sensitive}\n")
        Mix.shell().info(if what == :html, do: Map.fetch!(page.html, speed), else: page.text)
        Mix.shell().info("")
    end
  end

  defp print(%{level: level, page: page, msg: msg}, color) do
    Mix.shell().info(IO.ANSI.format([color, "#{level}", :reset, " [#{page}] #{msg}"]))
  end
end
