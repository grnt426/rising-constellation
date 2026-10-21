defmodule Edict.EditorKit do
  @moduledoc """
  Edict support for code editors, generated from `Edict.Catalog`.

  Players who would rather write scripts in their own editor download a kit
  from the Scenario Workshop (`GET /api/edict/editors/:kind`):

    * **VS Code** (and Cursor, VSCodium): an extension (`.vsix`) with syntax
      highlighting, completion, hover docs, signature help, an outline,
      go-to-definition and the lexer's checks.
    * **JetBrains IDEs, Neovim, Sublime Text, Zed, Helix, Emacs:** a TextMate
      grammar for highlighting and a language server (`lsp/edict-lsp.js`,
      run with Node) for the rest.
    * **Notepad++:** a user-defined language and an auto-completion file with
      call tips.

  Everything a kit suggests comes from `catalog/0`, built from the same
  tables the checker and the interpreter use, so editor and game can't
  disagree about what exists. The JavaScript that reads it lives in
  `priv/edict/editors/` (`core.js` is shared by both adapters). The kits only
  help write text: the full check stays on the server, and the workshop can
  open or link a file to show it.
  """

  alias Edict.{Catalog, Lexer}

  @publisher "tetrarchyfalls"
  @kinds %{
    "vscode" => :vsix,
    "kit" => :kit,
    "notepadpp" => :notepadpp
  }

  @doc "The downloads, by URL name."
  def kinds, do: Map.keys(@kinds)

  @doc "The app version the kit is stamped with (semver, as VS Code requires)."
  def version, do: :rc |> Application.spec(:vsn) |> to_string()

  @doc """
  `{filename, zip}` for a download kind, or `:error`. Built once per boot
  (the catalog is fixed at compile time) and kept in `:persistent_term`.
  """
  def download(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, what} ->
        key = {__MODULE__, what}

        case :persistent_term.get(key, nil) do
          nil ->
            built = build(what)
            :persistent_term.put(key, built)
            built

          built ->
            built
        end

      :error ->
        :error
    end
  end

  defp build(:vsix), do: {"edict-#{version()}.vsix", vsix()}
  defp build(:kit), do: {"edict-editor-kit-#{version()}.zip", zip(kit_files())}
  defp build(:notepadpp), do: {"edict-notepad-plus-plus-#{version()}.zip", zip(notepadpp_files())}

  # --- the catalog editors read ------------------------------------------------

  @keyword_docs %{
    "setup" =>
      "**setup { … }** The world the scenario starts from: name, description, time limit, faction, the sector, a rival court, mutators and patents.",
    "score" => "**score** *value*: how players are ranked. Counted when the run ends; higher ranks first.",
    "tiebreak" => "**tiebreak** *value*: breaks ties between equal scores. Higher ranks first.",
    "var" =>
      "**var** *name* = *value*: state the scenario keeps between events. It starts at its value and handlers can change it.",
    "let" => "**let** *name* = *value*: a name for a value, inside a handler or a function.",
    "fn" =>
      "**fn** *name*(*a*, *b*) { … }: a function, callable from anywhere, by position or by name: `area(h: 3, w: 4)`.",
    "return" => "**return** *value*: ends the function, giving back the value.",
    "if" =>
      "**if** *condition* { … } else { … }: runs steps only when the condition is true. As a value: `if a then b else c`.",
    "then" => "`if a then b else c`: a value that depends on a condition.",
    "else" => "The other branch of an `if`.",
    "for" => "**for** *item* **in** *list* { … }: repeats the steps for each item of the list.",
    "in" =>
      "In `for item in list`, the list to walk. As an operator, true when the left value is in the list, text or record on the right: `\"armoring\" in player.patents`.",
    "while" =>
      "**while** *condition* { … }: repeats the steps while the condition is true. Every step costs fuel, so an endless loop is stopped.",
    "break" => "Leaves the loop.",
    "continue" => "Skips to the loop's next item.",
    "on" => "**on start { … }**: runs once, as the run begins.",
    "on_end" => "**on end { … }**: runs once when the run ends, after the score is counted.",
    "every" =>
      "**every** 15s [from 1m] [until 20m] [as n] { … }: runs again and again on a schedule, counted from the run's start. `as n` numbers the runs 1, 2, 3 …",
    "at" => "**at** 10m { … }: runs once, when the clock reaches that time.",
    "when" =>
      "**when** *condition* { … }: runs each time the condition turns true (checked every second), then waits for it to turn false.",
    "as" => "`every 15s as n`: names the run count (1, 2, 3 …).",
    "from" => "`every 1m from 5m`: the first run's time.",
    "until" => "`every 1m until 20m`: no runs after this time.",
    "draft" =>
      "**draft { … }**: code that isn't wired into anything yet (the canvas's loose nodes). It never runs and is never checked.",
    "and" => "True when both sides are true.",
    "or" => "True when either side is true.",
    "not" => "Turns true into false and false into true.",
    "true" => "Yes.",
    "false" => "No.",
    "nil" => "No value."
  }

  @root_docs %{
    "time" => "The clock, in seconds: `time.elapsed`, `time.left`, `time.limit`.",
    "player" => "The player: stocks, income, systems, agents, patents and wonders.",
    "rival" => "The rival court (`rival = true` in setup): `present`, `faction`, `agents_sent`, `agents_left`.",
    "scenario" => "This scenario: `name`, `systems`, `time_limit`."
  }

  @doc "Everything an editor needs to know about the language, as JSON-ready data."
  def catalog do
    json = Catalog.to_json()

    %{
      version: version(),
      keywords: Enum.sort(Lexer.keywords()),
      keyword_docs: @keyword_docs,
      root_docs: @root_docs,
      builtins: json.builtins,
      actions: json.actions,
      events: json.events,
      world: json.world,
      world_docs: json.world_docs,
      setup: json.setup,
      docs: Edict.Docs.all(),
      enums: %{
        resources: Catalog.resources(),
        factions: Catalog.factions(),
        patents: Catalog.patent_names(),
        patent_titles: Map.new(Catalog.patent_names(), &{&1, Catalog.patent_title(&1)}),
        mutators: Enum.map(json.mutators, &Map.take(&1, [:key, :name, :polarity, :description]))
      }
    }
  end

  # --- TextMate grammar (VS Code, JetBrains, Sublime, …) ---------------------------------

  @ident "[A-Za-z_][A-Za-z0-9_]*"
  @num "\\d[\\d_]*(?:\\.\\d+)?"
  @bidi "[\u202A-\u202E\u2066-\u2069\u200E\u200F]"

  @doc "The TextMate grammar, scope `source.edict`."
  def grammar do
    words = fn names -> Enum.join(Enum.sort(names), "|") end

    %{
      "$schema" => "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
      "name" => "Edict",
      "scopeName" => "source.edict",
      "fileTypes" => ["edict"],
      "patterns" => [%{"include" => "#comment"}, %{"include" => "#code"}],
      "repository" => %{
        "comment" => %{
          "name" => "comment.line.number-sign.edict",
          "begin" => "#",
          "end" => "$",
          "beginCaptures" => %{"0" => %{"name" => "punctuation.definition.comment.edict"}},
          "patterns" => [%{"include" => "#bidi"}]
        },
        "bidi" => %{"name" => "invalid.illegal.bidi.edict", "match" => @bidi},
        "string" => %{
          "name" => "string.quoted.double.edict",
          "begin" => "\"",
          "end" => "(\")|(?=$)",
          "beginCaptures" => %{"0" => %{"name" => "punctuation.definition.string.begin.edict"}},
          "endCaptures" => %{"1" => %{"name" => "punctuation.definition.string.end.edict"}},
          "patterns" => [
            %{"include" => "#bidi"},
            %{"name" => "constant.character.escape.edict", "match" => "\\\\[nt\"\\\\{}]"},
            %{"name" => "invalid.illegal.escape.edict", "match" => "\\\\."},
            %{
              "name" => "meta.interpolation.edict",
              "begin" => "\\{",
              "end" => "(\\})|(?=[\"]|$)",
              "beginCaptures" => %{"0" => %{"name" => "punctuation.section.interpolation.begin.edict"}},
              "endCaptures" => %{"1" => %{"name" => "punctuation.section.interpolation.end.edict"}},
              "contentName" => "source.edict",
              "patterns" => [%{"include" => "#code"}]
            }
          ]
        },
        "code" => %{
          "patterns" => [
            %{"include" => "#bidi"},
            %{"include" => "#string"},
            %{
              "name" => "constant.numeric.duration.edict",
              "match" => "(?<![A-Za-z0-9_.])#{@num}[hms](?:#{@num}[hms])*(?![A-Za-z0-9_])"
            },
            %{"name" => "constant.numeric.percentage.edict", "match" => "(?<![A-Za-z0-9_.])#{@num}%"},
            %{"name" => "constant.numeric.decimal.edict", "match" => "(?<![A-Za-z0-9_.])#{@num}(?![A-Za-z0-9_%])"},
            %{
              "match" => "\\b(fn)\\s+(#{@ident})",
              "captures" => %{
                "1" => %{"name" => "storage.type.function.edict"},
                "2" => %{"name" => "entity.name.function.edict"}
              }
            },
            %{
              "match" => "\\b(var|let)\\s+(#{@ident})",
              "captures" => %{
                "1" => %{"name" => "storage.type.edict"},
                "2" => %{"name" => "variable.other.declaration.edict"}
              }
            },
            %{
              "match" => "\\b(on)\\s+(start|end)\\b",
              "captures" => %{
                "1" => %{"name" => "keyword.control.event.edict"},
                "2" => %{"name" => "support.constant.event.edict"}
              }
            },
            %{
              "match" => "\\b(as|for)\\s+(#{@ident})",
              "captures" => %{
                "1" => %{"name" => "keyword.control.edict"},
                "2" => %{"name" => "variable.other.declaration.edict"}
              }
            },
            %{"name" => "keyword.other.declaration.edict", "match" => "\\b(?:setup|score|tiebreak|draft)\\b"},
            %{"name" => "keyword.control.event.edict", "match" => "\\b(?:every|at|when|from|until)\\b"},
            %{
              "name" => "keyword.control.edict",
              "match" => "\\b(?:if|then|else|for|in|while|break|continue|return)\\b"
            },
            %{"name" => "keyword.operator.logical.edict", "match" => "\\b(?:and|or|not)\\b"},
            %{"name" => "constant.language.edict", "match" => "\\b(?:true|false|nil)\\b"},
            %{
              "name" => "support.function.action.edict",
              "match" => "\\b(?:#{words.(Catalog.action_names())})\\b(?=\\s*\\()"
            },
            %{
              "name" => "support.function.builtin.edict",
              "match" => "\\b(?:#{words.(Catalog.builtin_names())})\\b(?=\\s*\\()"
            },
            %{"name" => "entity.name.function.call.edict", "match" => "\\b#{@ident}(?=\\s*\\()"},
            %{
              "name" => "variable.language.world.edict",
              "match" => "\\b(?:#{words.(Catalog.world_roots())})\\b(?=\\s*\\.)"
            },
            %{
              "match" => "\\b(#{@ident})\\s*(:)",
              "captures" => %{
                "1" => %{"name" => "variable.parameter.edict"},
                "2" => %{"name" => "punctuation.separator.key-value.edict"}
              }
            },
            %{"name" => "variable.other.property.edict", "match" => "(?<=\\.)\\s*#{@ident}"},
            %{"name" => "storage.type.function.arrow.edict", "match" => "=>"},
            %{"name" => "keyword.operator.comparison.edict", "match" => "==|!=|<=|>=|<|>"},
            %{"name" => "keyword.operator.assignment.edict", "match" => "="},
            %{"name" => "keyword.operator.arithmetic.edict", "match" => "[-+*/]"},
            %{"name" => "keyword.operator.placeholder.edict", "match" => "\\?"},
            %{"name" => "punctuation.separator.comma.edict", "match" => ","},
            %{"name" => "punctuation.accessor.edict", "match" => "\\."},
            %{"name" => "punctuation.terminator.statement.edict", "match" => ";"},
            %{"name" => "variable.other.edict", "match" => "\\b#{@ident}\\b"}
          ]
        }
      }
    }
  end

  @doc "Brackets, comments and indentation for VS Code-style editors."
  def language_configuration do
    %{
      "comments" => %{"lineComment" => "#"},
      "brackets" => [["{", "}"], ["[", "]"], ["(", ")"]],
      "autoClosingPairs" => [
        %{"open" => "{", "close" => "}"},
        %{"open" => "[", "close" => "]"},
        %{"open" => "(", "close" => ")"},
        %{"open" => "\"", "close" => "\"", "notIn" => ["string", "comment"]}
      ],
      "surroundingPairs" => [["{", "}"], ["[", "]"], ["(", ")"], ["\"", "\""]],
      "indentationRules" => %{
        "increaseIndentPattern" => "^.*\\{[^}\"]*$",
        "decreaseIndentPattern" => "^\\s*\\}"
      },
      "wordPattern" => "\\d[\\d_]*(?:\\.\\d+)?(?:%|[hms](?:\\d[\\d_]*(?:\\.\\d+)?[hms])*)?|[A-Za-z_][A-Za-z0-9_]*"
    }
  end

  defp language_contribution do
    %{
      "languages" => [
        %{
          "id" => "edict",
          "aliases" => ["Edict", "edict"],
          "extensions" => [".edict"],
          "configuration" => "./language-configuration.json"
        }
      ],
      "grammars" => [
        %{"language" => "edict", "scopeName" => "source.edict", "path" => "./syntaxes/edict.tmLanguage.json"}
      ]
    }
  end

  @description "Write Tetrarchy Falls scenarios in Edict: highlighting, completion, hover docs and signature help from the game's own catalog."

  defp vscode_package do
    %{
      "name" => "edict",
      "displayName" => "Edict (Tetrarchy Falls scenarios)",
      "description" => @description,
      "version" => version(),
      "publisher" => @publisher,
      "license" => "PolyForm-Noncommercial-1.0.0",
      "engines" => %{"vscode" => "^1.75.0"},
      "categories" => ["Programming Languages", "Snippets"],
      "keywords" => ["edict", "tetrarchy falls", "scenario"],
      "main" => "./extension.js",
      "activationEvents" => ["onLanguage:edict"],
      "contributes" => language_contribution()
    }
  end

  # The same languages and grammar, without code: what a TextMate importer
  # (JetBrains' TextMate Bundles, for one) reads.
  defp textmate_package do
    %{
      "name" => "edict-textmate",
      "displayName" => "Edict",
      "description" => @description,
      "version" => version(),
      "publisher" => @publisher,
      "engines" => %{"vscode" => "^1.75.0"},
      "contributes" => language_contribution()
    }
  end

  # --- Notepad++ ---------------------------------------------------------------------------------

  # Colors per theme: {fg, fontStyle} (fontStyle 1 bold, 2 italic). nil
  # leaves the style to the editor's theme (colorStyle 0), so plain text and
  # operators read on light and dark backgrounds alike.
  @udl_colors %{
    light: %{
      "COMMENTS" => {"008000", 2},
      "LINE COMMENTS" => {"008000", 2},
      "NUMBERS" => {"098658", 0},
      # declarations and control words
      "KEYWORDS1" => {"0000FF", 1},
      # builtins
      "KEYWORDS2" => {"795E26", 0},
      # actions (they change the game)
      "KEYWORDS3" => {"AF00DB", 1},
      # world roots: time, player, rival, scenario
      "KEYWORDS4" => {"001080", 1},
      # true false nil and or not
      "KEYWORDS5" => {"0000FF", 0},
      "DELIMITERS1" => {"A31515", 0}
    },
    dark: %{
      "COMMENTS" => {"6A9955", 2},
      "LINE COMMENTS" => {"6A9955", 2},
      "NUMBERS" => {"B5CEA8", 0},
      "KEYWORDS1" => {"569CD6", 1},
      "KEYWORDS2" => {"DCDCAA", 0},
      "KEYWORDS3" => {"C586C0", 1},
      "KEYWORDS4" => {"9CDCFE", 1},
      "KEYWORDS5" => {"569CD6", 0},
      "DELIMITERS1" => {"CE9178", 0}
    }
  }

  @udl_styles ~w(DEFAULT COMMENTS) ++
                ["LINE COMMENTS", "NUMBERS"] ++
                Enum.map(1..8, &"KEYWORDS#{&1}") ++
                ["OPERATORS", "FOLDER IN CODE1", "FOLDER IN CODE2", "FOLDER IN COMMENT"] ++
                Enum.map(1..8, &"DELIMITERS#{&1}")

  @doc """
  A Notepad++ user-defined language (Language > User Defined Language >
  Import), for a light (`:light`) or dark (`:dark`) theme. Both are named
  "Edict", so the one auto-completion file serves either.
  """
  def notepadpp_udl(theme \\ :light) do
    colors = Map.fetch!(@udl_colors, theme)

    styles =
      Enum.map_join(@udl_styles, "\n", fn name ->
        case Map.get(colors, name) do
          # colorStyle 1: this foreground on the theme's own background
          {fg, font} ->
            ~s(            <WordsStyle name="#{name}" fgColor="#{fg}" bgColor="FFFFFF" colorStyle="1" fontName="" fontStyle="#{font}" nesting="0" />)

          nil ->
            ~s(            <WordsStyle name="#{name}" fgColor="000000" bgColor="FFFFFF" colorStyle="0" fontName="" fontStyle="0" nesting="0" />)
        end
      end)

    dark = if theme == :dark, do: ~s( darkModeTheme="yes"), else: ""

    keywords = fn list -> list |> Enum.sort() |> Enum.join(" ") |> xml() end

    lists = [
      {"Comments", "00# 01 02((EOL)) 03 04"},
      {"Numbers, prefix1", ""},
      {"Numbers, prefix2", ""},
      {"Numbers, extras1", "_"},
      {"Numbers, extras2", ""},
      {"Numbers, suffix1", "s m h %"},
      {"Numbers, suffix2", ""},
      {"Numbers, range", ""},
      {"Operators1", xml("+ - * / = < > ( ) [ ] , . : ?")},
      {"Operators2", xml("=> == != <= >=")},
      {"Folders in code1, open", "{"},
      {"Folders in code1, middle", ""},
      {"Folders in code1, close", "}"},
      {"Folders in code2, open", ""},
      {"Folders in code2, middle", ""},
      {"Folders in code2, close", ""},
      {"Folders in comment, open", ""},
      {"Folders in comment, middle", ""},
      {"Folders in comment, close", ""},
      {"Keywords1", keywords.(Lexer.keywords() -- ["true", "false", "nil", "and", "or", "not"])},
      {"Keywords2", keywords.(Catalog.builtin_names())},
      {"Keywords3", keywords.(Catalog.action_names())},
      {"Keywords4", keywords.(Catalog.world_roots())},
      {"Keywords5", keywords.(["true", "false", "nil", "and", "or", "not"])},
      {"Keywords6", ""},
      {"Keywords7", ""},
      {"Keywords8", ""},
      {"Delimiters", xml(~s(00" 01\\ 02" 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23))}
    ]

    list_xml =
      Enum.map_join(lists, "\n", fn {name, value} -> ~s(            <Keywords name="#{name}">#{value}</Keywords>) end)

    """
    <?xml version="1.0" encoding="UTF-8" ?>
    <!-- Edict (Tetrarchy Falls scenarios) #{version()}, generated by the game. -->
    <NotepadPlus>
        <UserLang name="Edict" ext="edict" udlVersion="2.1"#{dark}>
            <Settings>
                <Global caseIgnored="no" allowFoldOfComments="no" foldCompact="no" forcePureLC="0" decimalSeparator="0" />
                <Prefix Keywords1="no" Keywords2="no" Keywords3="no" Keywords4="no" Keywords5="no" Keywords6="no" Keywords7="no" Keywords8="no" />
            </Settings>
            <KeywordLists>
    #{list_xml}
            </KeywordLists>
            <Styles>
    #{styles}
            </Styles>
        </UserLang>
    </NotepadPlus>
    """
  end

  @doc """
  Notepad++ auto-completion with call tips. Notepad++ looks words up by
  binary search, so they are sorted by byte (`.` lets it complete world
  paths such as `player.income.credit` as one word).
  """
  def notepadpp_autocomplete do
    json = Catalog.to_json()

    funcs =
      Enum.map(json.builtins ++ json.actions, fn s ->
        params =
          Enum.map(s.params, fn p ->
            suffix = if(p.rest, do: "...", else: if(p.optional, do: "?", else: ""))
            "#{p.name}#{suffix}: #{type_name(p.type)}"
          end) ++ Enum.map(s.named, &"#{&1.name}: #{type_name(&1.type)}")

        ret = if s.kind == :action, do: "action", else: type_name(s.returns)
        {s.name, {ret, s.doc, params}}
      end)

    paths = world_paths() |> Enum.map(&{&1, nil})
    words = (Lexer.keywords() ++ Catalog.world_roots()) |> Enum.map(&{&1, nil})

    entries =
      (funcs ++ paths ++ words)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn
        {name, nil} ->
          ~s(        <KeyWord name="#{xml(name)}" />)

        {name, {ret, doc, params}} ->
          param_xml = Enum.map_join(params, "\n", &~s(                <Param name="#{xml(&1)}" />))

          """
                  <KeyWord name="#{xml(name)}" func="yes">
                      <Overload retVal="#{xml(ret)}" descr="#{xml(doc)}">
          #{param_xml}
                      </Overload>
                  </KeyWord>\
          """
      end)

    """
    <?xml version="1.0" encoding="UTF-8" ?>
    <!-- Edict (Tetrarchy Falls scenarios) #{version()}, generated by the game. -->
    <NotepadPlus>
        <AutoComplete language="Edict">
            <Environment ignoreCase="no" startFunc="(" stopFunc=")" paramSeparator="," terminal="" additionalWordChar="._" />
    #{entries}
        </AutoComplete>
    </NotepadPlus>
    """
  end

  # every readable path, e.g. player.income.credit (list items excluded)
  defp world_paths do
    walk = fn
      walk, {:record, fields}, path ->
        Enum.flat_map(fields, fn {k, t} -> [path <> "." <> k | walk.(walk, t, path <> "." <> k)] end)

      _walk, _type, _path ->
        []
    end

    Enum.flat_map(Catalog.world(), fn {root, type} -> walk.(walk, type, root) end)
  end

  defp type_name(t) when is_binary(t), do: t
  defp type_name(%{list: t}), do: "list of " <> type_name(t)
  defp type_name(%{record: _}), do: "record"
  defp type_name(%{enum: values}), do: Enum.map_join(values, " | ", &~s("#{&1}"))
  defp type_name(_), do: "any"

  defp xml(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("\n", "&#x0A;")
  end

  # --- packages ------------------------------------------------------------------------------------

  defp source(name), do: File.read!(Path.join(Application.app_dir(:rc, "priv/edict/editors"), name))

  defp json(term), do: Jason.encode!(term, pretty: true, escape: :unicode_safe) <> "\n"

  defp shared_files do
    [
      {"core.js", source("core.js")},
      {"catalog.json", json(catalog())},
      {"language-configuration.json", json(language_configuration())},
      {"syntaxes/edict.tmLanguage.json", json(grammar())}
    ]
  end

  @doc "The VS Code extension's files, as they sit in `extension/`."
  def vscode_files do
    [
      {"package.json", json(vscode_package())},
      {"extension.js", source("extension.js")},
      {"README.md", readme("README.vscode.md")}
      | shared_files()
    ]
  end

  @doc "The editor kit, unpacked: `[{path, contents}]`."
  def kit_files do
    lsp =
      Enum.map(
        [{"edict-lsp.js", source("edict-lsp.js")}, {"core.js", source("core.js")}, {"catalog.json", json(catalog())}],
        fn {p, c} -> {"lsp/" <> p, c} end
      )

    textmate =
      Enum.map(
        [
          {"package.json", json(textmate_package())},
          {"language-configuration.json", json(language_configuration())},
          {"syntaxes/edict.tmLanguage.json", json(grammar())}
        ],
        fn {p, c} -> {"textmate/" <> p, c} end
      )

    [{"README.md", readme("README.md")}, {"edict-#{version()}.vsix", vsix()}] ++
      textmate ++ lsp ++ notepadpp_files()
  end

  @doc "The Notepad++ files: the language and its auto-completion."
  def notepadpp_files do
    [
      {"notepad++/Edict.xml", notepadpp_udl(:light)},
      {"notepad++/dark/Edict.xml", notepadpp_udl(:dark)},
      {"notepad++/autoCompletion/Edict.xml", notepadpp_autocomplete()}
    ]
  end

  defp readme(name), do: name |> source() |> String.replace("{{version}}", version())

  @doc """
  The `.vsix`: a zip in the Open Packaging layout VS Code installs from
  (Extensions > … > Install from VSIX).
  """
  def vsix do
    files = Enum.map(vscode_files(), fn {p, c} -> {"extension/" <> p, c} end)

    manifest = """
    <?xml version="1.0" encoding="utf-8"?>
    <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
      <Metadata>
        <Identity Language="en-US" Id="edict" Version="#{version()}" Publisher="#{@publisher}" />
        <DisplayName>Edict (Tetrarchy Falls scenarios)</DisplayName>
        <Description xml:space="preserve">#{xml(@description)}</Description>
        <Tags>edict,tetrarchy falls,scenario,__ext_edict</Tags>
        <Categories>Programming Languages,Snippets</Categories>
        <GalleryFlags>Public</GalleryFlags>
        <Properties>
          <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.75.0" />
          <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value="" />
          <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value="" />
          <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace" />
          <Property Id="Microsoft.VisualStudio.Code.LocalizedLanguages" Value="" />
          <Property Id="Microsoft.VisualStudio.Services.GitHubFlavoredMarkdown" Value="true" />
        </Properties>
      </Metadata>
      <Installation>
        <InstallationTarget Id="Microsoft.VisualStudio.Code" />
      </Installation>
      <Dependencies />
      <Assets>
        <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
        <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true" />
      </Assets>
    </PackageManifest>
    """

    types = """
    <?xml version="1.0" encoding="utf-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension=".json" ContentType="application/json" />
      <Default Extension=".js" ContentType="application/javascript" />
      <Default Extension=".md" ContentType="text/markdown" />
      <Default Extension=".vsixmanifest" ContentType="text/xml" />
    </Types>
    """

    zip([{"extension.vsixmanifest", manifest}, {"[Content_Types].xml", types} | files])
  end

  @doc "Write the kit, unpacked, under `dir` (for `mix edict.editors`)."
  def write(dir) do
    Enum.each(kit_files(), fn {path, contents} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end)
  end

  defp zip(files) do
    entries = Enum.map(files, fn {path, contents} -> {String.to_charlist(path), contents} end)
    {:ok, {_name, bin}} = :zip.create(~c"edict.zip", entries, [:memory])
    bin
  end
end
