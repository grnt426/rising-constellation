defmodule Edict.EditorKitTest do
  # The editor kits are generated from the catalog: these tests check that
  # each file is well formed and covers the whole language, then run the
  # JavaScript tests (test/edict/editors/) against the generated kit.
  use ExUnit.Case, async: true

  alias Edict.{Catalog, EditorKit, Lexer}

  test "the catalog covers every name the language has, with docs" do
    c = EditorKit.catalog()
    assert Enum.map(c.builtins, & &1.name) == Catalog.builtin_names()
    assert Enum.map(c.actions, & &1.name) == Catalog.action_names()
    assert Enum.sort(c.keywords) == Enum.sort(Lexer.keywords())
    for kw <- Lexer.keywords(), do: assert(c.keyword_docs[kw], "no doc for #{kw}")
    for root <- Catalog.world_roots(), do: assert(c.root_docs[root], "no doc for #{root}")
    assert "capital_1" in c.enums.patents
    assert Enum.all?(c.enums.mutators, &is_binary(&1.name))
    # it survives JSON
    assert {:ok, _} = c |> Jason.encode!() |> Jason.decode()
  end

  test "the grammar names every action and builtin, and its patterns compile" do
    grammar = EditorKit.grammar()
    patterns = grammar["repository"]["code"]["patterns"]
    actions = Enum.find(patterns, &(&1["name"] == "support.function.action.edict"))["match"]
    builtins = Enum.find(patterns, &(&1["name"] == "support.function.builtin.edict"))["match"]
    for name <- Catalog.action_names(), do: assert(actions =~ ~r/\b#{name}\b/)
    for name <- Catalog.builtin_names(), do: assert(builtins =~ ~r/\b#{name}\b/)

    regexes = collect_regexes(grammar)
    assert length(regexes) > 30
    for source <- regexes, do: assert({:ok, _} = Regex.compile(source, "u"), source)

    # the hidden-direction characters are escaped in the file, not written raw
    json = Jason.encode!(grammar, escape: :unicode_safe)
    refute String.contains?(json, <<0x202E::utf8>>)
  end

  test "the .vsix is an extension package VS Code can install" do
    {:ok, files} = :zip.unzip(EditorKit.vsix(), [:memory])
    files = Map.new(files, fn {name, bin} -> {to_string(name), bin} end)

    for path <- ~w(extension.vsixmanifest [Content_Types].xml extension/package.json extension/extension.js
                  extension/core.js extension/catalog.json extension/language-configuration.json
                  extension/syntaxes/edict.tmLanguage.json extension/README.md) do
      assert Map.has_key?(files, path), path
    end

    manifest = files["extension.vsixmanifest"]
    assert {_doc, _rest} = :xmerl_scan.string(String.to_charlist(manifest), quiet: true)
    assert manifest =~ ~s(Version="#{EditorKit.version()}")

    pkg = Jason.decode!(files["extension/package.json"])
    assert pkg["version"] == EditorKit.version()
    assert pkg["main"] == "./extension.js"
    assert [%{"extensions" => [".edict"]}] = pkg["contributes"]["languages"]
    assert files["extension/README.md"] =~ EditorKit.version()
  end

  test "the Notepad++ files are well formed, and auto-completion is sorted for its binary search" do
    for xml <- [EditorKit.notepadpp_udl(), EditorKit.notepadpp_autocomplete()] do
      assert {_doc, _rest} = :xmerl_scan.string(String.to_charlist(xml), quiet: true)
    end

    names =
      ~r/<KeyWord name="([^"]+)"/
      |> Regex.scan(EditorKit.notepadpp_autocomplete())
      |> Enum.map(fn [_, name] -> name end)

    assert names == Enum.sort(names)
    assert names == Enum.uniq(names)
    for name <- Catalog.builtin_names() ++ Catalog.action_names(), do: assert(name in names)
    assert "player.income.credit" in names

    udl = EditorKit.notepadpp_udl()
    assert udl =~ ~s(ext="edict")
    for name <- Catalog.action_names(), do: assert(udl =~ name)
  end

  test "downloads are built once and named by version" do
    assert {"edict-" <> _, vsix} = EditorKit.download("vscode")
    assert {name, kit} = EditorKit.download("kit")
    assert name =~ ~r/^edict-editor-kit-\d+\.\d+\.\d+\.zip$/
    assert {:ok, entries} = :zip.list_dir(kit)

    paths = for {:zip_file, path, _, _, _, _} <- entries, do: to_string(path)
    assert "lsp/edict-lsp.js" in paths and "textmate/package.json" in paths and "notepad++/Edict.xml" in paths
    assert Enum.any?(paths, &String.ends_with?(&1, ".vsix"))
    assert EditorKit.download("vscode") |> elem(1) == vsix
    assert EditorKit.download("nope") == :error
  end

  @tag timeout: 300_000
  @tag :tmp_dir
  test "the JavaScript tests pass against the generated kit", %{tmp_dir: dir} do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[editor kit] node not found; skipping the JavaScript tests")

      node ->
        EditorKit.write(dir)
        tests = Path.wildcard("test/edict/editors/*.test.js")
        assert length(tests) >= 3

        {out, status} =
          System.cmd(node, ["--test" | tests],
            env: [{"EDICT_KIT", dir}, {"EDICT_EXAMPLES", Path.expand("priv/edict/examples")}],
            stderr_to_stdout: true
          )

        assert status == 0, out
    end
  end

  defp collect_regexes(map) when is_map(map) do
    own = for key <- ["match", "begin", "end"], is_binary(map[key]), do: map[key]
    own ++ Enum.flat_map(Map.values(map), &collect_regexes/1)
  end

  defp collect_regexes(list) when is_list(list), do: Enum.flat_map(list, &collect_regexes/1)
  defp collect_regexes(_), do: []
end
