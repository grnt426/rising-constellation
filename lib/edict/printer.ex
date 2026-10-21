defmodule Edict.Printer do
  @moduledoc """
  Turns an Edict tree back into text, in the one canonical layout (two-space
  indents, one statement per line, parentheses only where precedence needs
  them).

  The printer is the visual editor's way into the text view, so its output
  must parse back to the same tree (`Edict.Parser.parse/1`, ids aside). The
  round-trip tests in test/edict/printer_test.exs hold it to that.
  """

  @indent "  "

  @doc "Print a whole program."
  def print(%{k: :program, decls: decls}) do
    decls
    |> Enum.map(&decl/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @doc "Print a list of statements at the top level (a code-node fragment)."
  def print_block(stmts), do: print_stmts(stmts, 0)

  @doc "Print one expression."
  def print_expr(e), do: expr(e, 0)

  # --- declarations ----------------------------------------------------------

  defp decl(%{k: :note} = n), do: note_lines(n.text, 0)

  defp decl(node), do: with_note(node, 0, decl_body(node))

  defp decl_body(%{k: :setup, body: body}), do: "setup " <> block(body, 0)
  defp decl_body(%{k: :score, expr: e}), do: "score " <> expr(e, 0)
  defp decl_body(%{k: :tiebreak, expr: e}), do: "tiebreak " <> expr(e, 0)
  defp decl_body(%{k: :var, name: name, expr: e}), do: "var #{name} = " <> expr(e, 0)

  defp decl_body(%{k: :fn, name: name, params: params, body: body}),
    do: "fn #{name}(#{Enum.join(params, ", ")}) " <> block(body, 0)

  defp decl_body(%{k: :on, event: event, body: body}), do: "on #{event} " <> block(body, 0)

  defp decl_body(%{k: :every} = n) do
    "every " <>
      expr(n.interval, 0) <>
      opt(" from ", n.from) <>
      opt(" until ", n.until) <>
      if(n.as, do: " as #{n.as}", else: "") <>
      " " <> block(n.body, 0)
  end

  defp decl_body(%{k: :at, time: t, body: body}), do: "at " <> expr(t, 0) <> " " <> block(body, 0)
  defp decl_body(%{k: :when, cond: c, body: body}), do: "when " <> expr(c, 0) <> " " <> block(body, 0)
  defp decl_body(%{k: :draft, body: body}), do: "draft " <> block(body, 0)

  defp opt(_prefix, nil), do: ""
  defp opt(prefix, e), do: prefix <> expr(e, 0)

  # --- blocks and statements -----------------------------------------------------

  defp block([], _level), do: "{\n}"

  defp block(stmts, level) do
    "{\n" <> print_stmts(stmts, level + 1) <> "\n" <> pad(level) <> "}"
  end

  # A standalone note keeps a blank line after it, or it would read back as
  # the next statement's own note.
  defp print_stmts(stmts, level) do
    last = length(stmts) - 1

    stmts
    |> Enum.with_index()
    |> Enum.map(fn {s, i} ->
      text = stmt(s, level)
      if s.k == :note and i < last, do: text <> "\n", else: text
    end)
    |> Enum.join("\n")
  end

  defp stmt(%{k: :note, text: text}, level), do: note_lines(text, level)

  defp stmt(node, level), do: with_note(node, level, pad(level) <> stmt_body(node, level))

  defp stmt_body(%{k: :let, name: name, expr: e}, _level), do: "let #{name} = " <> expr(e, 0)
  defp stmt_body(%{k: :assign, target: t, expr: e}, _level), do: expr(t, 0) <> " = " <> expr(e, 0)
  defp stmt_body(%{k: :if} = n, level), do: if_text(n, level)

  defp stmt_body(%{k: :for, var: var, iter: iter, body: body}, level),
    do: "for #{var} in " <> expr(iter, 0) <> " " <> block(body, level)

  defp stmt_body(%{k: :while, cond: c, body: body}, level), do: "while " <> expr(c, 0) <> " " <> block(body, level)
  defp stmt_body(%{k: :return, expr: nil}, _level), do: "return"
  defp stmt_body(%{k: :return, expr: e}, _level), do: "return " <> expr(e, 0)
  defp stmt_body(%{k: :break}, _level), do: "break"
  defp stmt_body(%{k: :continue}, _level), do: "continue"
  defp stmt_body(%{k: :expr, expr: e}, _level), do: expr(e, 0)

  defp if_text(%{cond: c, then: then_body, else: else_body}, level) do
    head = "if " <> expr(c, 0) <> " " <> block(then_body, level)

    case else_body do
      nil -> head
      # an else holding exactly one if (with no note) prints as `else if`
      [%{k: :if} = nested] when not is_map_key(nested, :note) -> head <> " else " <> if_text(nested, level)
      body -> head <> " else " <> block(body, level)
    end
  end

  defp with_note(node, level, text) do
    case Map.get(node, :note) do
      nil -> text
      note -> note_lines(note, level) <> "\n" <> text
    end
  end

  defp note_lines(text, level) do
    text
    |> String.split("\n")
    |> Enum.map(fn line -> pad(level) <> String.trim_trailing("# " <> line) end)
    |> Enum.join("\n")
  end

  defp pad(level), do: String.duplicate(@indent, level)

  # --- expressions -------------------------------------------------------------

  # Binding strength: higher binds tighter.
  @prec %{
    "or" => 1,
    "and" => 2,
    "==" => 4,
    "!=" => 4,
    "<" => 4,
    "<=" => 4,
    ">" => 4,
    ">=" => 4,
    "in" => 4,
    "+" => 5,
    "-" => 5,
    "*" => 6,
    "/" => 6
  }

  defp prec(%{k: :bin, op: op}), do: Map.fetch!(@prec, op)
  defp prec(%{k: :un, op: "not"}), do: 3
  defp prec(%{k: :un, op: "-"}), do: 7
  defp prec(%{k: :num, v: v}) when v < 0, do: 7
  defp prec(%{k: kind}) when kind in [:cond, :lambda], do: 0
  defp prec(_), do: 9

  # Print `e`, parenthesized when it binds looser than `min`.
  defp expr(e, min) do
    text = raw(e)
    if prec(e) < min, do: "(" <> text <> ")", else: text
  end

  defp raw(%{k: :num} = n), do: number(n)
  defp raw(%{k: :str, v: v}), do: "\"" <> escape(v) <> "\""
  defp raw(%{k: :tmpl, parts: parts}), do: template(parts)
  defp raw(%{k: :bool, v: true}), do: "true"
  defp raw(%{k: :bool, v: false}), do: "false"
  defp raw(%{k: :nil_lit}), do: "nil"
  defp raw(%{k: :hole}), do: "?"
  defp raw(%{k: :ident, name: name}), do: name
  defp raw(%{k: :field, obj: obj, name: name}), do: expr(obj, 8) <> "." <> name
  defp raw(%{k: :index, obj: obj, index: i}), do: expr(obj, 8) <> "[" <> expr(i, 0) <> "]"

  defp raw(%{k: :call, fn: f, args: args, named: named}) do
    positional = Enum.map(args, &expr(&1, 0))
    named = Enum.map(named, fn %{name: name, expr: e} -> "#{name}: " <> expr(e, 0) end)
    expr(f, 8) <> "(" <> Enum.join(positional ++ named, ", ") <> ")"
  end

  defp raw(%{k: :bin, op: op, l: l, r: r}) do
    p = Map.fetch!(@prec, op)

    {left_min, right_min} =
      cond do
        # comparisons don't chain: both sides must bind tighter
        p == 4 -> {5, 5}
        # left-associative: the right side must bind strictly tighter
        true -> {p, p + 1}
      end

    expr(l, left_min) <> " #{op} " <> expr(r, right_min)
  end

  defp raw(%{k: :un, op: "not", e: e}), do: "not " <> expr(e, 3)
  # `- -3` must not print as `--3`; a negative literal operand gets parentheses
  defp raw(%{k: :un, op: "-", e: %{k: :num, v: v} = e}) when v < 0, do: "-(" <> raw(e) <> ")"
  defp raw(%{k: :un, op: "-", e: e}), do: "-" <> expr(e, 7)

  defp raw(%{k: :list, items: items}), do: "[" <> Enum.map_join(items, ", ", &expr(&1, 0)) <> "]"
  defp raw(%{k: :map, entries: []}), do: "{}"

  defp raw(%{k: :map, entries: entries}) do
    "{" <> Enum.map_join(entries, ", ", fn %{key: k, value: v} -> map_key(k) <> ": " <> expr(v, 0) end) <> "}"
  end

  defp raw(%{k: :lambda, params: [p], body: body}), do: p <> " => " <> expr(body, 0)
  defp raw(%{k: :lambda, params: params, body: body}), do: "(" <> Enum.join(params, ", ") <> ") => " <> expr(body, 0)

  defp raw(%{k: :cond, cond: c, then: a, else: b}),
    do: "if " <> expr(c, 1) <> " then " <> expr(a, 0) <> " else " <> expr(b, 0)

  defp map_key(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key), do: key, else: "\"" <> escape(key) <> "\""
  end

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
  end

  # A template prints with {…} holes when every hole is simple enough to sit
  # inside text (no quotes, braces or line breaks); otherwise it falls back to
  # joining with `+`, which means the same.
  defp template(parts) do
    holes = Enum.filter(parts, &is_map/1) |> Enum.map(&expr(&1, 0))

    if Enum.all?(holes, &(not String.contains?(&1, ["\"", "{", "}", "\n"]))) do
      "\"" <>
        Enum.map_join(parts, fn
          text when is_binary(text) -> escape(text)
          e -> "{" <> expr(e, 0) <> "}"
        end) <> "\""
    else
      parts
      |> Enum.map(fn
        text when is_binary(text) -> "\"" <> escape(text) <> "\""
        e -> "str(" <> expr(e, 0) <> ")"
      end)
      |> Enum.join(" + ")
    end
  end

  # --- numbers ---------------------------------------------------------------

  defp number(%{v: v, unit: "duration"}) when v < 0, do: "-" <> duration(-v)
  defp number(%{v: v, unit: "duration"}), do: duration(v)
  defp number(%{v: v, unit: "percent"}), do: plain(Float.round(v * 100, 9)) <> "%"
  defp number(%{v: v}), do: plain(v)

  defp duration(seconds) do
    whole? = seconds == Float.round(seconds)

    if whole? and seconds > 0 do
      s = trunc(seconds)
      h = div(s, 3600)
      m = div(rem(s, 3600), 60)
      sec = rem(s, 60)

      [{h, "h"}, {m, "m"}, {sec, "s"}]
      |> Enum.reject(fn {n, _} -> n == 0 end)
      |> Enum.map_join(fn {n, unit} -> "#{n}#{unit}" end)
    else
      plain(seconds) <> "s"
    end
  end

  @doc false
  def plain(v) when is_float(v) do
    rounded = Float.round(v)

    if v == rounded and abs(v) <= 1.0e15 do
      n = trunc(v)
      if abs(n) >= 10_000, do: group(n), else: Integer.to_string(n)
    else
      # the lexer reads no exponents, so never print one
      short = :erlang.float_to_binary(v, [:short])

      if String.contains?(short, "e") do
        v |> :erlang.float_to_binary(decimals: 12) |> String.trim_trailing("0") |> String.trim_trailing(".")
      else
        short
      end
    end
  end

  def plain(v) when is_integer(v), do: plain(v / 1)

  # 100000000 -> 100_000_000
  defp group(n) when n < 0, do: "-" <> group(-n)

  defp group(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join("_")
    |> String.reverse()
  end
end
