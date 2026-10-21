defmodule Edict.AST do
  @moduledoc """
  The canonical form of an Edict script.

  Text and the visual graph are both *views* of this tree: the parser builds
  it from text, the printer (`Edict.Printer`) turns it back into text, and the
  visual editor draws and edits it directly. Every node is a map with a kind
  (`:k`), an id, an optional source position (`:at`, `[line, col]`) and the
  fields its kind defines below.

  ## Trust boundary

  The editor sends trees as JSON, so a tree from the outside is untrusted
  input. `from_json/1` is the only way in: it rebuilds the tree from a fixed
  table of kinds and fields, rejects anything else, and never creates an atom
  from input (kinds and field names are matched against the table's strings).
  Names must be valid identifiers, text must be clean, numbers finite and in
  range, and the whole tree within the size and depth limits. A tree that
  passes is exactly a tree the parser could have produced.
  """

  alias Edict.Limits

  # kind => {category, fields}. Field types:
  #   :expr, {:opt, :expr}, :exprs, :block, {:opt, :block}, :name, {:opt, :name},
  #   :names, :text, :number, :bool, {:enum, [...]}, :named_args, :entries, :parts
  @kinds %{
    # declarations
    "setup" => {:setup, :decl, [body: :block]},
    "score" => {:score, :decl, [expr: :expr]},
    "tiebreak" => {:tiebreak, :decl, [expr: :expr]},
    "var" => {:var, :decl, [name: :name, expr: :expr]},
    "fn" => {:fn, :decl, [name: :name, params: :names, body: :block]},
    "on" => {:on, :decl, [event: {:enum, ["start", "end"]}, body: :block]},
    "every" =>
      {:every, :decl, [interval: :expr, from: {:opt, :expr}, until: {:opt, :expr}, as: {:opt, :name}, body: :block]},
    "at" => {:at, :decl, [time: :expr, body: :block]},
    "when" => {:when, :decl, [cond: :expr, body: :block]},
    "draft" => {:draft, :decl, [body: :block]},
    # statements (`note` is both: a standalone comment)
    "note" => {:note, :any_stmt, [text: :text]},
    "let" => {:let, :stmt, [name: :name, expr: :expr]},
    "assign" => {:assign, :stmt, [target: :expr, expr: :expr]},
    "if" => {:if, :stmt, [cond: :expr, then: :block, else: {:opt, :block}]},
    "for" => {:for, :stmt, [var: :name, iter: :expr, body: :block]},
    "while" => {:while, :stmt, [cond: :expr, body: :block]},
    "return" => {:return, :stmt, [expr: {:opt, :expr}]},
    "break" => {:break, :stmt, []},
    "continue" => {:continue, :stmt, []},
    "expr" => {:expr, :stmt, [expr: :expr]},
    # expressions
    "num" => {:num, :expr, [v: :number, unit: {:enum, [nil, "duration", "percent"]}]},
    "str" => {:str, :expr, [v: :text]},
    "tmpl" => {:tmpl, :expr, [parts: :parts]},
    "bool" => {:bool, :expr, [v: :bool]},
    "nil_lit" => {:nil_lit, :expr, []},
    "hole" => {:hole, :expr, []},
    "ident" => {:ident, :expr, [name: :name]},
    "field" => {:field, :expr, [obj: :expr, name: :name]},
    "index" => {:index, :expr, [obj: :expr, index: :expr]},
    "call" => {:call, :expr, [fn: :expr, args: :exprs, named: :named_args]},
    "bin" => {:bin, :expr, [op: {:enum, ~w(+ - * / == != < <= > >= in and or)}, l: :expr, r: :expr]},
    "un" => {:un, :expr, [op: {:enum, ["-", "not"]}, e: :expr]},
    "list" => {:list, :expr, [items: :exprs]},
    "map" => {:map, :expr, [entries: :entries]},
    "lambda" => {:lambda, :expr, [params: :names, body: :expr]},
    "cond" => {:cond, :expr, [cond: :expr, then: :expr, else: :expr]}
  }

  @kind_atoms Map.new(@kinds, fn {name, {atom, _, _}} -> {atom, name} end)

  @doc "Kind names and their categories, for the editor."
  def kinds,
    do:
      Map.new(@kinds, fn {name, {_, category, fields}} ->
        {name, %{category: category, fields: Keyword.keys(fields)}}
      end)

  @doc "The JSON name of a kind atom."
  def kind_name(atom), do: Map.fetch!(@kind_atoms, atom)

  @doc "A kind atom's category: :decl, :stmt, :any_stmt (note) or :expr."
  def kind_category(atom) do
    {_, category, _} = Map.fetch!(@kinds, Map.fetch!(@kind_atoms, atom))
    category
  end

  @id_pattern ~r/^[A-Za-z0-9_-]{1,32}$/
  @name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc "Whether `name` is a valid, non-reserved identifier."
  def valid_name?(name) when is_binary(name) do
    byte_size(name) <= Limits.max_identifier() and Regex.match?(@name_pattern, name) and
      name not in Edict.Lexer.keywords()
  end

  def valid_name?(_), do: false

  @doc """
  A script's text as a message may quote it: a key or a short word as
  written (`"capital_1"`), anything else as "this text". Messages reach the
  editor, the playtest and, once scripts are shared, other players; whatever
  renders them, none should carry markup a script put there.
  """
  def quoted(v) when is_binary(v) do
    if String.length(v) <= 40 and Regex.match?(~r/^[A-Za-z0-9_][A-Za-z0-9_ .:-]*$/, v),
      do: ~s("#{v}"),
      else: "this text"
  end

  def quoted(v) when is_number(v) or is_boolean(v) or is_nil(v), do: inspect(v)
  def quoted(_), do: "this value"

  # --- JSON in ---------------------------------------------------------------

  @doc """
  Rebuild a program from untrusted JSON (string keys, as decoded by Jason).
  Returns `{:ok, program}` or `{:error, message}`.
  """
  def from_json(%{"decls" => decls} = json) when is_list(decls) do
    version = Map.get(json, "version", 1)

    if version != 1 do
      {:error, "unknown script format version"}
    else
      {decls, _} =
        Enum.map_reduce(decls, %{seen: MapSet.new(), next: 1}, fn decl, ids ->
          decode(decl, [:decl, :any_stmt], 1, ids)
        end)

      program = %{k: :program, version: 1, decls: decls}

      with :ok <- check_limits(program) do
        {:ok, program}
      end
    end
  catch
    {:bad_tree, message} -> {:error, message}
  end

  def from_json(_), do: {:error, "a script needs a list of decls"}

  @doc "Decode a single statement list or expression (a code-node fragment)."
  def fragment_from_json(json, :expr) do
    {node, _} = decode(json, [:expr], 1, %{seen: MapSet.new(), next: 1})
    with :ok <- check_limits(node), do: {:ok, node}
  catch
    {:bad_tree, message} -> {:error, message}
  end

  defp bad(message), do: throw({:bad_tree, message})

  defp decode(%{"k" => kind} = json, categories, depth, ids) when is_binary(kind) do
    if depth > Limits.max_depth() * 2, do: bad("the script is nested too deeply")

    case Map.fetch(@kinds, kind) do
      {:ok, {atom, category, fields}} ->
        unless category in categories, do: bad("a #{kind} can't appear here")
        {id, ids} = decode_id(Map.get(json, "id"), ids)

        base =
          %{k: atom, id: id}
          |> put_at(Map.get(json, "at"))
          |> put_note(Map.get(json, "note"), category)

        Enum.reduce(fields, {base, ids}, fn {field, type}, {node, ids} ->
          {value, ids} = decode_field(type, Map.get(json, Atom.to_string(field)), depth, ids, kind, field)
          {Map.put(node, field, value), ids}
        end)

      :error ->
        bad("unknown part #{inspect(String.slice(kind, 0, 24))}")
    end
  end

  defp decode(_json, _categories, _depth, _ids), do: bad("malformed part (every part needs a kind)")

  # Ids are the editor's handle on a node. A missing, malformed or repeated
  # id is replaced rather than rejected: the tree is still sound without it.
  defp decode_id(id, ids) when is_binary(id) do
    if Regex.match?(@id_pattern, id) and not MapSet.member?(ids.seen, id) do
      {id, %{ids | seen: MapSet.put(ids.seen, id)}}
    else
      fresh_id(ids)
    end
  end

  defp decode_id(_, ids), do: fresh_id(ids)

  defp fresh_id(ids) do
    id = "j#{ids.next}"

    if MapSet.member?(ids.seen, id),
      do: fresh_id(%{ids | next: ids.next + 1}),
      else: {id, %{ids | seen: MapSet.put(ids.seen, id), next: ids.next + 1}}
  end

  defp put_at(node, [line, col]) when is_integer(line) and is_integer(col) and line > 0 and col > 0,
    do: Map.put(node, :at, [line, col])

  defp put_at(node, _), do: node

  defp put_note(node, note, category) when is_binary(note) and category != :expr,
    do: Map.put(node, :note, clean_text!(note, Limits.max_string()))

  defp put_note(node, _, _), do: node

  defp decode_field(:expr, value, depth, ids, _kind, _field), do: decode(value, [:expr], depth + 1, ids)

  defp decode_field({:opt, _}, nil, _depth, ids, _kind, _field), do: {nil, ids}

  defp decode_field({:opt, type}, value, depth, ids, kind, field),
    do: decode_field(type, value, depth, ids, kind, field)

  defp decode_field(:exprs, list, depth, ids, _kind, _field) when is_list(list),
    do: Enum.map_reduce(list, ids, &decode(&1, [:expr], depth + 1, &2))

  defp decode_field(:block, list, depth, ids, _kind, _field) when is_list(list),
    do: Enum.map_reduce(list, ids, &decode(&1, [:stmt, :any_stmt], depth + 1, &2))

  defp decode_field(:name, name, _depth, ids, kind, field) do
    if valid_name?(name), do: {name, ids}, else: bad("#{kind}.#{field} must be a valid name")
  end

  defp decode_field(:names, names, _depth, ids, kind, field) when is_list(names) do
    if length(names) > 16, do: bad("#{kind} has too many parameters (16 at most)")
    if length(Enum.uniq(names)) != length(names), do: bad("#{kind} repeats a parameter")
    Enum.each(names, &decode_field(:name, &1, 0, ids, kind, field))
    {names, ids}
  end

  defp decode_field(:text, text, _depth, ids, _kind, _field), do: {clean_text!(text, Limits.max_string()), ids}

  defp decode_field(:number, n, _depth, ids, kind, _field) when is_number(n) do
    if abs(n) > Limits.max_number(), do: bad("a number in #{kind} is out of range")
    {n / 1, ids}
  end

  defp decode_field(:bool, b, _depth, ids, _kind, _field) when is_boolean(b), do: {b, ids}

  defp decode_field({:enum, allowed}, value, _depth, ids, kind, field) do
    if value in allowed, do: {value, ids}, else: bad("#{kind}.#{field} has an unknown value")
  end

  defp decode_field(:named_args, list, depth, ids, kind, _field) when is_list(list) do
    {named, ids} =
      Enum.map_reduce(list, ids, fn
        %{"name" => name, "expr" => e}, ids ->
          {name, ids} = decode_field(:name, name, depth, ids, kind, :named)
          {e, ids} = decode(e, [:expr], depth + 1, ids)
          {%{name: name, expr: e}, ids}

        _, _ ->
          bad("malformed named value in #{kind}")
      end)

    if length(Enum.uniq_by(named, & &1.name)) != length(named), do: bad("#{kind} names a value twice")
    {named, ids}
  end

  defp decode_field(:entries, list, depth, ids, kind, _field) when is_list(list) do
    if length(list) > Limits.max_map(), do: bad("a record has too many keys")

    {entries, ids} =
      Enum.map_reduce(list, ids, fn
        %{"key" => key, "value" => v}, ids ->
          key = clean_text!(key, Limits.max_identifier() * 4)
          {v, ids} = decode(v, [:expr], depth + 1, ids)
          {%{key: key, value: v}, ids}

        _, _ ->
          bad("malformed record entry in #{kind}")
      end)

    if length(Enum.uniq_by(entries, & &1.key)) != length(entries), do: bad("a record repeats a key")
    {entries, ids}
  end

  defp decode_field(:parts, list, depth, ids, kind, _field) when is_list(list) do
    Enum.map_reduce(list, ids, fn
      text, ids when is_binary(text) -> {clean_text!(text, Limits.max_string()), ids}
      %{} = e, ids -> decode(e, [:expr], depth + 1, ids)
      _, _ -> bad("malformed text in #{kind}")
    end)
  end

  defp decode_field(type, _value, _depth, _ids, kind, field) do
    bad("#{kind}.#{field} is missing or has the wrong type (#{inspect(type)})")
  end

  @bidi [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F]

  @doc """
  Validate a piece of text from outside: UTF-8, within `max` bytes, free of
  control characters (other than tab and newline) and text-direction
  overrides. Throws `{:bad_tree, message}` on failure.
  """
  def clean_text!(text, max) when is_binary(text) do
    cond do
      not String.valid?(text) -> bad("text must be valid UTF-8")
      byte_size(text) > max -> bad("a text is too long")
      Enum.any?(String.to_charlist(text), &bad_char?/1) -> bad("a text contains a control character")
      true -> text
    end
  end

  def clean_text!(_, _), do: bad("expected text")

  defp bad_char?(cp), do: cp in @bidi or (cp < 0x20 and cp not in [?\t, ?\n]) or cp == 0x7F

  # --- limits ----------------------------------------------------------------

  @doc "Check a tree against the node-count and depth limits."
  def check_limits(tree) do
    {count, depth} = measure(tree, 1)

    cond do
      count > Limits.max_nodes() -> {:error, "the script is too large (#{Limits.max_nodes()} parts at most)"}
      depth > Limits.max_depth() * 2 -> {:error, "the script is nested too deeply"}
      true -> :ok
    end
  end

  # {node count, max depth}
  defp measure(%{k: _} = node, depth) do
    node
    |> children()
    |> Enum.reduce({1, depth}, fn child, {count, max_depth} ->
      {c, d} = measure(child, depth + 1)
      {count + c, max(max_depth, d)}
    end)
  end

  @doc "The child nodes of a node, in source order."
  def children(%{k: :program, decls: decls}), do: decls

  def children(%{k: kind} = node) do
    {_, _, fields} = Map.fetch!(@kinds, Map.fetch!(@kind_atoms, kind))

    Enum.flat_map(fields, fn {field, type} -> field_children(type, Map.get(node, field)) end)
  end

  defp field_children(_, nil), do: []
  defp field_children(:expr, e), do: [e]
  defp field_children({:opt, type}, v), do: field_children(type, v)
  defp field_children(:exprs, list), do: list
  defp field_children(:block, list), do: list
  defp field_children(:named_args, list), do: Enum.map(list, & &1.expr)
  defp field_children(:entries, list), do: Enum.map(list, & &1.value)
  defp field_children(:parts, list), do: Enum.filter(list, &is_map/1)
  defp field_children(_, _), do: []

  @doc "Every node of the tree, depth first (the program itself excluded)."
  def nodes(tree) do
    tree |> children() |> Enum.flat_map(fn child -> [child | nodes(child)] end)
  end
end
