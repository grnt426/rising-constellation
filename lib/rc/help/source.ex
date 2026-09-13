defmodule RC.Help.Source do
  @moduledoc """
  Discovers and parses help-manual sources under `priv/help/<lang>/`.

  A source file is markdown with a small frontmatter block:

      ---
      title: Mobility
      icon: resource/mobility
      terms: [mobility, mobility bonus]
      related: [taxes, population]
      sources:
        - lib/game/instance/stellar_system/stellar_system.ex:1831-1857
      status: draft
      ---
      body…

  Supported keys: `id`, `title`, `category`, `kind`, `icon`, `terms`,
  `related`, `aliases`, `sources`, `status`. Values are scalars,
  `[a, b, c]` inline lists, or `- item` block lists. No YAML library is
  involved on purpose: the grammar is small enough that a strict parser is
  better than a permissive one.

  The slug defaults to the file name. Files under a catalog directory
  (`building/`, `patent/`, `lex/`, `ship/`, `mutator/`, `faction/`,
  `tradition/`, `skill/`) keep the directory as a prefix, so
  `priv/help/en/building/hab-open.md` is `building/hab-open`.
  """

  alias RC.Help.Page

  @root Path.expand("priv/help", File.cwd!())
  @known_keys ~w(id title category kind icon terms related aliases sources status)
  @list_keys ~w(terms related aliases sources)
  @catalog_dirs ~w(building patent lex ship mutator faction tradition skill)

  def root, do: @root

  @doc "Every source file for the given languages (for `@external_resource`)."
  def files(langs) do
    for lang <- langs, path <- Path.wildcard(Path.join([@root, lang, "**", "*.md"])), do: path
  end

  @doc """
  Loads every page for `lang`. A language without its own directory falls
  back to `fallback` (English prose, localized names). Returns
  `{pages, issues}`; a page that fails to parse becomes an issue and is
  dropped.
  """
  def load(lang, fallback \\ "en") do
    dir = Path.join(@root, lang)
    dir = if File.dir?(dir), do: dir, else: Path.join(@root, fallback)

    Path.wildcard(Path.join([dir, "**", "*.md"]))
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn path, {pages, issues} ->
      case parse_file(path, lang, dir) do
        {:ok, page, warnings} -> {[page | pages], warnings ++ issues}
        {:error, issue} -> {pages, [issue | issues]}
      end
    end)
    |> then(fn {pages, issues} -> {Enum.reverse(pages), Enum.reverse(issues)} end)
  end

  @doc false
  def parse_file(path, lang, dir) do
    rel = Path.relative_to(path, dir)
    segments = rel |> Path.rootname() |> Path.split()
    {dirs, base} = Enum.split(segments, -1)
    base = hd(base)
    category = List.first(dirs) || "misc"

    default_slug =
      case dirs do
        [d | _] when d in @catalog_dirs -> "#{d}/#{base}"
        _ -> base
      end

    with {:ok, content} <- File.read(path),
         {:ok, meta, body, warnings} <- parse_frontmatter(content) do
      slug = Map.get(meta, "id", default_slug)

      kind =
        case Map.get(meta, "kind") do
          nil -> if category in @catalog_dirs, do: :catalog, else: :mechanic
          "catalog" -> :catalog
          "index" -> :index
          _ -> :mechanic
        end

      page = %Page{
        slug: slug,
        title: Map.get(meta, "title"),
        category: Map.get(meta, "category", category),
        kind: kind,
        icon: Map.get(meta, "icon"),
        terms: Map.get(meta, "terms", []),
        related: Map.get(meta, "related", []),
        aliases: Map.get(meta, "aliases", []),
        sources: Map.get(meta, "sources", []),
        status: Map.get(meta, "status", "draft"),
        lang: lang,
        path: path,
        body: body
      }

      warnings = Enum.map(warnings, &issue(:warning, slug, &1))

      if is_nil(page.title) do
        {:error, issue(:error, slug, "missing `title:` in frontmatter (#{rel})")}
      else
        {:ok, page, warnings}
      end
    else
      {:error, {:frontmatter, reason}} -> {:error, issue(:error, default_slug, "#{reason} (#{rel})")}
      {:error, posix} -> {:error, issue(:error, default_slug, "cannot read #{rel}: #{inspect(posix)}")}
    end
  end

  @doc """
  Splits a source into `{:ok, meta, body, warnings}`. `meta` is a string
  keyed map; list keys are always lists.
  """
  def parse_frontmatter(content) do
    content = String.replace(content, "\r\n", "\n")

    case String.split(content, "\n", parts: 2) do
      ["---", rest] ->
        case String.split(rest, "\n---\n", parts: 2) do
          [front, body] -> parse_meta(front, body)
          [_] -> {:error, {:frontmatter, "unterminated frontmatter (missing closing ---)"}}
        end

      _ ->
        {:error, {:frontmatter, "file must start with a `---` frontmatter block"}}
    end
  end

  defp parse_meta(front, body) do
    front
    |> String.split("\n")
    |> Enum.reduce_while({:ok, %{}, nil, []}, fn line, {:ok, meta, open_list, warnings} ->
      cond do
        String.trim(line) == "" ->
          {:cont, {:ok, meta, open_list, warnings}}

        String.match?(line, ~r/^\s+-\s+/) and open_list != nil ->
          item = line |> String.replace(~r/^\s+-\s+/, "") |> unquote_value()
          {:cont, {:ok, Map.update(meta, open_list, [item], &(&1 ++ [item])), open_list, warnings}}

        String.match?(line, ~r/^[a-z_]+:/) ->
          [key, value] = String.split(line, ":", parts: 2)
          value = String.trim(value)

          warnings =
            if key in @known_keys, do: warnings, else: ["unknown frontmatter key `#{key}`" | warnings]

          cond do
            value == "" and key in @list_keys ->
              {:cont, {:ok, Map.put(meta, key, []), key, warnings}}

            value == "" ->
              {:cont, {:ok, meta, nil, ["empty value for `#{key}`" | warnings]}}

            String.starts_with?(value, "[") ->
              if String.ends_with?(value, "]") do
                items =
                  value
                  |> String.slice(1..-2//1)
                  |> String.split(",")
                  |> Enum.map(&unquote_value/1)
                  |> Enum.reject(&(&1 == ""))

                {:cont, {:ok, Map.put(meta, key, items), nil, warnings}}
              else
                {:halt, {:error, {:frontmatter, "unterminated list for `#{key}`"}}}
              end

            key in @list_keys ->
              {:cont, {:ok, Map.put(meta, key, [unquote_value(value)]), nil, warnings}}

            true ->
              {:cont, {:ok, Map.put(meta, key, unquote_value(value)), nil, warnings}}
          end

        true ->
          {:halt, {:error, {:frontmatter, "cannot parse frontmatter line: #{inspect(line)}"}}}
      end
    end)
    |> case do
      {:ok, meta, _open, warnings} -> {:ok, meta, String.trim_leading(body, "\n"), Enum.reverse(warnings)}
      {:error, _} = err -> err
    end
  end

  defp unquote_value(v) do
    v = String.trim(v)

    cond do
      String.length(v) >= 2 and String.starts_with?(v, "\"") and String.ends_with?(v, "\"") ->
        String.slice(v, 1..-2//1)

      String.length(v) >= 2 and String.starts_with?(v, "'") and String.ends_with?(v, "'") ->
        String.slice(v, 1..-2//1)

      true ->
        v
    end
  end

  @doc false
  def issue(level, slug, msg), do: %{level: level, page: slug, msg: msg}
end
