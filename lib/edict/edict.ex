defmodule Edict do
  @moduledoc """
  Edict: the scenario scripting language.

  A scenario script describes a single-player challenge in the daily's mold:
  the world it starts from (`setup`), how players are ranked (`score`,
  `tiebreak`) and what happens while they play (handlers: `on start`,
  `every`, `at`, `when`, `on end`). Players write it as text or as a node
  graph in the Scenario Workshop; both are views of one tree (`Edict.AST`).

  The design, the security model and the roadmap are in
  docs/scenario-scripting.md. The pieces:

    * `Edict.Lexer`, `Edict.Parser`, `Edict.Printer` — text in and out;
    * `Edict.AST` — the canonical tree and the gate for trees from outside;
    * `Edict.Checker` — mistakes found before running;
    * `Edict.Catalog` — every name a script can use;
    * `Edict.Interpreter` — the closed evaluator (fuel, caps, no ambient
      authority: actions are returned as data);
    * `Edict.Runtime` — schedules and fires handlers over a run;
    * `Edict.Sandbox` — the process backstop;
    * `Edict.Simulator` — the editor's dry run against a model player;
    * `Edict.World` — the live game's data, as a script sees it;
    * `Edict.Scenario` — setup validation.
  """

  alias Edict.{AST, Checker, Parser, Printer}

  @doc """
  Parse and check source text. Returns `%{program: tree | nil,
  diagnostics: [...]}`: a syntax error gives no tree and one diagnostic.
  """
  def analyze(source) when is_binary(source) do
    case Parser.parse(source) do
      {:ok, program} -> %{program: program, diagnostics: Checker.check(program)}
      {:error, error} -> %{program: nil, diagnostics: [syntax_diag(error)]}
    end
  end

  @doc "Check a tree that came from outside as JSON. Same result shape as `analyze/1`."
  def analyze_json(json) do
    case AST.from_json(json) do
      {:ok, program} -> %{program: program, diagnostics: Checker.check(program)}
      {:error, message} -> %{program: nil, diagnostics: [%{severity: "error", message: message, node_id: nil, at: nil}]}
    end
  end

  @doc "Format a tree as canonical text."
  def format(program), do: Printer.print(program)

  defp syntax_diag(%{message: message, line: line, col: col}) do
    %{severity: "error", message: message, node_id: nil, at: [line, col]}
  end

  # --- examples --------------------------------------------------------------

  # {file, level, port_of}: port_of names the Daily.Objective the example
  # reproduces (the parity tests hold it to that), nil for originals.
  @examples [
    {"first_steps", "start here", nil},
    {"coffers_of_the_realm", "port", :coffers_of_the_realm},
    {"golden_flow", "port", :golden_flow},
    {"the_triumvirate", "port", :the_triumvirate},
    {"the_bequest", "port", :the_bequest},
    {"charter_of_prosperity", "port", :charter_of_prosperity},
    {"destroyers_blueprint", "port", :destroyers_blueprint},
    {"fleet_in_being_raiders", "port", :fleet_in_being_raiders},
    {"land_rush", "port", :land_rush},
    {"hegemon", "port", :hegemon},
    {"headhunter_lite", "partial port", :headhunter},
    {"tithe_collector", "original", nil}
  ]

  @doc "The example scripts: `%{key, level, port_of, title, source}`."
  def examples do
    dir = Application.app_dir(:rc, "priv/edict/examples")

    Enum.map(@examples, fn {key, level, port_of} ->
      source = File.read!(Path.join(dir, key <> ".edict"))
      %{key: key, level: level, port_of: port_of, title: title(source, key), source: source}
    end)
  end

  # Functions every author starts with in the workshop's library.
  @library ~w(best escalate level_for_wave)

  @doc """
  The built-in function library: `%{name, doc, source}`, one `fn` per file
  in `priv/edict/library`, its doc the comment above it.
  """
  def library do
    dir = Application.app_dir(:rc, "priv/edict/library")

    Enum.map(@library, fn name ->
      source = File.read!(Path.join(dir, name <> ".edict"))

      doc =
        source
        |> String.split("\n")
        |> Enum.take_while(&String.starts_with?(&1, "#"))
        |> Enum.map_join(" ", &String.trim_leading(&1, "# "))

      %{name: name, doc: doc, source: source}
    end)
  end

  @doc "One example by key, or nil."
  def example(key), do: Enum.find(examples(), &(&1.key == key))

  defp title(source, key) do
    case Regex.run(~r/name = "([^"]+)"/, source) do
      [_, name] -> name
      _ -> key
    end
  end
end
