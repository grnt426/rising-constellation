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

  Errors: unknown links, icons, constants, names, UI strings, table
  generators; duplicate slugs/aliases; missing titles. Warnings: prose over
  the length cap, internal names or adjectives of quality in prose, missing
  terms, terms claimed by several pages, missing source files.
  """

  use Mix.Task

  @switches [page: :string, text: :string, speed: :string, lang: :string, quiet: :boolean]

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    if slug = opts[:page], do: show(slug, opts, :html)
    if slug = opts[:text], do: show(slug, opts, :text)

    errors = RC.Help.errors()
    warnings = RC.Help.warnings()

    unless opts[:quiet] do
      Enum.each(warnings, &print(&1, :yellow))
      Enum.each(errors, &print(&1, :red))
    end

    langs = RC.Help.languages()
    n = RC.Help.pages("en") |> map_size()

    Mix.shell().info(
      "help manual: #{n} page(s) × #{length(langs)} language(s) × #{length(RC.Help.speeds())} speeds, " <>
        "#{length(errors)} error(s), #{length(warnings)} warning(s)"
    )

    if errors != [] do
      Mix.shell().error("help.check failed")
      exit({:shutdown, 1})
    end
  end

  defp show(slug, opts, what) do
    lang = opts[:lang] || "en"
    speed = Enum.find(RC.Help.speeds(), :slow, &(Atom.to_string(&1) == (opts[:speed] || "slow")))

    case RC.Help.page(slug, lang) do
      nil ->
        Mix.shell().error("no page `#{slug}` (known: #{Enum.join(RC.Help.slugs(), ", ")})")

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
