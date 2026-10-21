defmodule Edict.Parser do
  @moduledoc """
  Parses Edict source into the canonical AST (`Edict.AST`).

  The grammar, informally (`NL` is a line break or `;`):

      program  := { decl NL }
      decl     := 'setup' block | 'score' expr | 'tiebreak' expr
                | 'var' NAME '=' expr | 'fn' NAME '(' params ')' block
                | 'on' ('start' | 'end') block
                | 'every' expr ['from' expr] ['until' expr] ['as' NAME] block
                | 'at' expr block | 'when' expr block | 'draft' block
      block    := '{' { stmt NL } '}'
      stmt     := 'let' NAME '=' expr | target '=' expr
                | 'if' expr block ['else' (stmt_if | block)]
                | 'for' NAME 'in' expr block | 'while' expr block
                | 'return' [expr] | 'break' | 'continue' | expr
      expr     := 'if' expr 'then' expr 'else' expr | or
      or       := and {'or' and}          and := not {'and' not}
      not      := 'not' not | cmp         cmp := add [cmpop add]
      add      := mul {('+'|'-') mul}     mul := unary {('*'|'/') unary}
      unary    := '-' unary | postfix
      postfix  := primary {'.' NAME | '[' expr ']' | '(' args ')'}
      primary  := NUMBER | TEXT | 'true' | 'false' | 'nil' | NAME
                | NAME '=>' expr | '(' params ')' '=>' expr | '(' expr ')'
                | '[' items ']' | '{' entries '}' | '?'

  Comments (`# ...`) are kept: the comment lines right above a declaration or
  statement become its `note`, a comment at the end of a line joins the note
  of that line's statement, and comments with nothing after them in a block
  become standalone `note` statements. So formatting a parsed script loses
  nothing a player wrote.

  Every node gets a fresh id (`"n1"`, `"n2"`, ...). The visual editor keys
  node positions on ids and carries them across re-parses itself.
  """

  alias Edict.{Lexer, Limits}

  defmodule State do
    @moduledoc false
    defstruct toks: [], next_id: 1, depth: 0, notes: [], detached: []
  end

  @doc "Parse a whole script. Returns `{:ok, program}` or `{:error, %{message, line, col}}`."
  def parse(source) do
    with {:ok, tokens} <- Lexer.tokenize(source),
         {:ok, program} <- run(tokens, &program/1) do
      sized(program)
    end
  end

  # The parser bounds nesting as it goes, but a long chain such as
  # 1 + 1 + 1 + ... nests without recursing; the size check catches it.
  defp sized(tree) do
    case Edict.AST.check_limits(tree) do
      :ok -> {:ok, tree}
      {:error, message} -> {:error, %{message: message, line: 1, col: 1}}
    end
  end

  @doc """
  Parse a fragment: `:expr` (one expression) or `:block` (statements, as
  inside braces). The editor uses this for code written into a single node.
  """
  def parse_fragment(source, kind) when kind in [:expr, :block] do
    with {:ok, tokens} <- Lexer.tokenize(source) do
      run(tokens, fn st ->
        case kind do
          :expr ->
            st = skip_nl(st, :drop)
            {e, st} = expr(st)
            st = skip_nl(st, :drop)
            expect_eof(st)
            {e, st}

          :block ->
            {stmts, st} = statements(st, :eof)
            {stmts, st}
        end
      end)
      |> case do
        {:ok, %{k: _} = e} -> sized(e)
        {:ok, stmts} when is_list(stmts) -> with {:ok, _} <- sized(%{k: :draft, body: stmts}), do: {:ok, stmts}
        error -> error
      end
    end
  end

  defp run(tokens, fun) do
    {result, _st} = fun.(%State{toks: tokens})
    {:ok, result}
  catch
    {:parse_error, message, {line, col}} -> {:error, %{message: message, line: line, col: col}}
  end

  defp fail(message, pos), do: throw({:parse_error, message, pos})

  # --- token helpers ---------------------------------------------------------

  defp peek(%State{toks: [tok | _]}), do: tok
  defp peek_type(st), do: elem(peek(st), 0)
  defp pos(st), do: elem(peek(st), 2)

  defp peek2_type(%State{toks: [_, {type, _, _} | _]}), do: type
  defp peek2_type(_), do: :eof

  defp advance(%State{toks: [tok | rest]} = st), do: {tok, %{st | toks: rest}}

  defp expect(st, type, what) do
    case peek(st) do
      {^type, _, _} -> st |> advance() |> elem(1)
      {_, value, pos} -> fail("expected #{what} but found #{describe(value)}", pos)
    end
  end

  defp expect_ident(st, what) do
    case peek(st) do
      {:ident, name, _} -> {name, st |> advance() |> elem(1)}
      {_, value, pos} -> fail("expected #{what} but found #{describe(value)}", pos)
    end
  end

  defp expect_eof(st) do
    case peek(st) do
      {:eof, _, _} -> :ok
      {_, value, pos} -> fail("unexpected #{describe(value)}", pos)
    end
  end

  defp describe(nil), do: "the end of the script"
  defp describe(parts) when is_list(parts), do: "text"
  defp describe({n, _}) when is_number(n), do: "a number"
  defp describe(value) when is_binary(value), do: inspect(value)
  defp describe(_), do: "something else"

  # Skip line breaks. In statement position (`:collect`) comment lines are
  # gathered as notes for the next statement; inside expressions they are
  # dropped.
  defp skip_nl(st, mode) do
    case peek(st) do
      # a blank line after a comment block detaches it: it stands alone
      {:nl, :blank, _} when mode == :collect and st.notes != [] ->
        {_, st} = advance(st)
        skip_nl(%{st | detached: st.detached ++ [Enum.join(st.notes, "\n")], notes: []}, mode)

      {:nl, _, _} ->
        st |> advance() |> elem(1) |> skip_nl(mode)

      {:comment, text, _} when mode == :collect ->
        {_, st} = advance(st)
        skip_nl(%{st | notes: st.notes ++ [text]}, mode)

      {:comment, _, _} ->
        st |> advance() |> elem(1) |> skip_nl(mode)

      _ ->
        st
    end
  end

  # Standalone comment blocks become note nodes of their own.
  defp take_detached(%State{detached: []} = st, acc), do: {acc, st}

  defp take_detached(%State{detached: [text | rest]} = st, acc) do
    {n, st} = node(%{st | detached: rest}, :note, %{text: text}, pos(st))
    take_detached(st, [n | acc])
  end

  defp take_notes(%State{notes: []} = st), do: {nil, st}
  defp take_notes(%State{notes: notes} = st), do: {Enum.join(notes, "\n"), %{st | notes: []}}

  defp node(st, kind, fields, pos) do
    if st.next_id > Limits.max_nodes() do
      fail("the script is too large (#{Limits.max_nodes()} parts at most)", pos)
    end

    {line, col} = pos
    node = Map.merge(%{k: kind, id: "n#{st.next_id}", at: [line, col]}, fields)
    {node, %{st | next_id: st.next_id + 1}}
  end

  defp deeper(st, pos) do
    if st.depth >= Limits.max_depth() do
      fail("this is nested too deeply (#{Limits.max_depth()} levels at most)", pos)
    end

    %{st | depth: st.depth + 1}
  end

  defp shallower(st), do: %{st | depth: st.depth - 1}

  # A statement or declaration ends at a line break, a closing brace or the
  # end of the script. A comment on the same line joins its note.
  defp end_statement(st, node) do
    case peek(st) do
      {:comment, text, _} ->
        {_, st} = advance(st)
        end_statement(st, add_note(node, text))

      {type, _, _} when type in [:nl, :rbrace, :eof] ->
        {node, st}

      {_, value, pos} ->
        fail("expected a new line before #{describe(value)}", pos)
    end
  end

  defp add_note(node, text) do
    case Map.get(node, :note) do
      nil -> Map.put(node, :note, text)
      note -> Map.put(node, :note, note <> "\n" <> text)
    end
  end

  defp with_note(node, nil), do: node
  defp with_note(node, note), do: Map.put(node, :note, note)

  # --- program and declarations ----------------------------------------------

  defp program(st) do
    {decls, st} = decls(st, [])
    {%{k: :program, version: 1, decls: decls}, st}
  end

  defp decls(st, acc) do
    st = skip_nl(st, :collect)
    {acc, st} = take_detached(st, acc)

    case peek_type(st) do
      :eof ->
        {note, st} = take_notes(st)

        {acc, st} =
          if note do
            {n, st} = node(st, :note, %{text: note}, pos(st))
            {[n | acc], st}
          else
            {acc, st}
          end

        {Enum.reverse(acc), st}

      _ ->
        {note, st} = take_notes(st)
        {decl, st} = decl(st)
        {decl, st} = end_statement(st, with_note(decl, note))
        decls(st, [decl | acc])
    end
  end

  defp decl(st) do
    {tok, after_kw} = advance(st)
    {type, value, at} = tok

    case type do
      :kw_setup ->
        {body, st} = block(after_kw)
        node(st, :setup, %{body: body}, at)

      :kw_score ->
        {e, st} = expr(after_kw)
        node(st, :score, %{expr: e}, at)

      :kw_tiebreak ->
        {e, st} = expr(after_kw)
        node(st, :tiebreak, %{expr: e}, at)

      :kw_var ->
        {name, st} = expect_ident(after_kw, "a name for the variable")
        st = expect(st, :assign, "=")
        {e, st} = expr(st)
        node(st, :var, %{name: name, expr: e}, at)

      :kw_fn ->
        {name, st} = expect_ident(after_kw, "a name for the function")
        st = expect(st, :lparen, "(")
        {params, st} = params(st, :rparen)
        {body, st} = block(st)
        node(st, :fn, %{name: name, params: params, body: body}, at)

      :kw_on ->
        case peek(after_kw) do
          {:ident, event, _} when event in ["start", "end"] ->
            {_, st} = advance(after_kw)
            {body, st} = block(st)
            node(st, :on, %{event: event, body: body}, at)

          {_, v, p} ->
            fail("`on` is followed by start or end, not #{describe(v)}", p)
        end

      :kw_every ->
        {interval, st} = expr(after_kw)
        {from, st} = optional_clause(st, :kw_from)
        {until, st} = optional_clause(st, :kw_until)

        {as, st} =
          case peek_type(st) do
            :kw_as ->
              {_, st} = advance(st)
              expect_ident(st, "a name for the count after `as`")

            _ ->
              {nil, st}
          end

        {body, st} = block(st)
        node(st, :every, %{interval: interval, from: from, until: until, as: as, body: body}, at)

      :kw_at ->
        {time, st} = expr(after_kw)
        {body, st} = block(st)
        node(st, :at, %{time: time, body: body}, at)

      :kw_when ->
        {cond_e, st} = expr(after_kw)
        {body, st} = block(st)
        node(st, :when, %{cond: cond_e, body: body}, at)

      :kw_draft ->
        {body, st} = block(after_kw)
        node(st, :draft, %{body: body}, at)

      _ ->
        fail(
          "a script is made of setup, score, tiebreak, var, fn, on, every, at, when and draft parts; found #{describe(value)}",
          at
        )
    end
  end

  defp optional_clause(st, kw) do
    case peek_type(st) do
      ^kw ->
        {_, st} = advance(st)
        expr(st)

      _ ->
        {nil, st}
    end
  end

  defp params(st, close) do
    st = skip_nl(st, :drop)

    case peek_type(st) do
      ^close ->
        {[], st |> advance() |> elem(1)}

      _ ->
        param_list(st, close, [])
    end
  end

  defp param_list(st, close, acc) do
    {name, st} = expect_ident(st, "a parameter name")

    if name in acc, do: fail("the parameter #{name} is listed twice", pos(st))

    st = skip_nl(st, :drop)

    case peek_type(st) do
      :comma ->
        st = st |> advance() |> elem(1) |> skip_nl(:drop)

        if peek_type(st) == close,
          do: {Enum.reverse([name | acc]), st |> advance() |> elem(1)},
          else: param_list(st, close, [name | acc])

      ^close ->
        {Enum.reverse([name | acc]), st |> advance() |> elem(1)}

      _ ->
        fail("expected , or ) after a parameter", pos(st))
    end
  end

  # --- blocks and statements ---------------------------------------------------

  defp block(st) do
    at = pos(st)
    st = expect(st, :lbrace, "{")
    st = deeper(st, at)
    {stmts, st} = statements(st, :rbrace)
    {stmts, shallower(st)}
  end

  # Statements up to `close` (a closing brace, or the end of a fragment).
  defp statements(st, close) do
    statements(st, close, [])
  end

  defp statements(st, close, acc) do
    st = skip_nl(st, :collect)
    {acc, st} = take_detached(st, acc)

    case peek_type(st) do
      ^close ->
        {note, st} = take_notes(st)

        {acc, st} =
          if note do
            {n, st} = node(st, :note, %{text: note}, pos(st))
            {[n | acc], st}
          else
            {acc, st}
          end

        st = if close == :rbrace, do: st |> advance() |> elem(1), else: st
        {Enum.reverse(acc), st}

      :eof ->
        fail("this block is missing its closing }", pos(st))

      _ ->
        {note, st} = take_notes(st)
        {stmt, st} = stmt(st)
        {stmt, st} = end_statement(st, with_note(stmt, note))
        statements(st, close, [stmt | acc])
    end
  end

  defp stmt(st) do
    {type, _value, at} = peek(st)

    case type do
      :kw_let ->
        {_, st} = advance(st)
        {name, st} = expect_ident(st, "a name after let")
        st = expect(st, :assign, "=")
        {e, st} = expr(st)
        node(st, :let, %{name: name, expr: e}, at)

      :kw_if ->
        if_stmt(st)

      :kw_for ->
        {_, st} = advance(st)
        {name, st} = expect_ident(st, "a name for each item")
        st = expect(st, :kw_in, "in")
        {iter, st} = expr(st)
        {body, st} = block(st)
        node(st, :for, %{var: name, iter: iter, body: body}, at)

      :kw_while ->
        {_, st} = advance(st)
        {c, st} = expr(st)
        {body, st} = block(st)
        node(st, :while, %{cond: c, body: body}, at)

      :kw_return ->
        {_, st} = advance(st)

        case peek_type(st) do
          t when t in [:nl, :rbrace, :eof, :comment] ->
            node(st, :return, %{expr: nil}, at)

          _ ->
            {e, st} = expr(st)
            node(st, :return, %{expr: e}, at)
        end

      :kw_break ->
        {_, st} = advance(st)
        node(st, :break, %{}, at)

      :kw_continue ->
        {_, st} = advance(st)
        node(st, :continue, %{}, at)

      _ ->
        {e, st} = expr(st)

        case peek_type(st) do
          :assign ->
            check_target(e)
            {_, st} = advance(st)
            {value, st} = expr(st)
            node(st, :assign, %{target: e, expr: value}, at)

          _ ->
            node(st, :expr, %{expr: e}, at)
        end
    end
  end

  defp if_stmt(st) do
    {{_, _, at}, st} = advance(st)
    {c, st} = expr(st)
    {then_body, st} = block(st)

    # `else` may sit on the line after the closing brace
    lookahead = skip_nl(st, :drop)

    {else_body, st} =
      case peek_type(lookahead) do
        :kw_else ->
          {_, st} = advance(lookahead)

          case peek_type(st) do
            :kw_if ->
              {nested, st} = if_stmt(st)
              {[nested], st}

            _ ->
              block(st)
          end

        _ ->
          {nil, st}
      end

    node(st, :if, %{cond: c, then: then_body, else: else_body}, at)
  end

  # Only names, fields and indexes rooted in a name can be assigned to.
  defp check_target(%{k: :ident}), do: :ok
  defp check_target(%{k: :field, obj: obj}), do: check_target(obj)
  defp check_target(%{k: :index, obj: obj}), do: check_target(obj)
  defp check_target(%{at: [line, col]}), do: fail("only a variable (or a field of one) can be set with =", {line, col})

  # --- expressions -----------------------------------------------------------

  defp expr(st) do
    at = pos(st)
    st = deeper(st, at)

    {e, st} =
      case peek_type(st) do
        :kw_if -> cond_expr(st)
        _ -> or_expr(st)
      end

    {e, shallower(st)}
  end

  defp cond_expr(st) do
    {{_, _, at}, st} = advance(st)
    {c, st} = or_expr(st)
    st = st |> skip_nl(:drop) |> expect(:kw_then, "then")
    st = skip_nl(st, :drop)
    {a, st} = expr(st)
    st = st |> skip_nl(:drop) |> expect(:kw_else, "else")
    st = skip_nl(st, :drop)
    {b, st} = expr(st)
    node(st, :cond, %{cond: c, then: a, else: b}, at)
  end

  defp or_expr(st), do: binary_left(st, &and_expr/1, %{kw_or: "or"})
  defp and_expr(st), do: binary_left(st, &not_expr/1, %{kw_and: "and"})

  defp not_expr(st) do
    case peek(st) do
      {:kw_not, _, at} ->
        {_, st} = advance(st)
        st = deeper(st, at)
        {e, st} = not_expr(st)
        node(shallower(st), :un, %{op: "not", e: e}, at)

      _ ->
        cmp_expr(st)
    end
  end

  @cmp_ops %{eq: "==", neq: "!=", lt: "<", lte: "<=", gt: ">", gte: ">=", kw_in: "in"}

  defp cmp_expr(st) do
    {left, st} = add_expr(st)

    case peek(st) do
      {type, _, at} when is_map_key(@cmp_ops, type) ->
        {_, st} = advance(st)
        st = skip_nl(st, :drop)
        {right, st} = add_expr(st)

        case peek(st) do
          {t2, v2, p2} when is_map_key(@cmp_ops, t2) ->
            fail("comparisons can't be chained; join them with and (found #{describe(v2)})", p2)

          _ ->
            node(st, :bin, %{op: Map.fetch!(@cmp_ops, type), l: left, r: right}, at)
        end

      _ ->
        {left, st}
    end
  end

  defp add_expr(st), do: binary_left(st, &mul_expr/1, %{plus: "+", minus: "-"})
  defp mul_expr(st), do: binary_left(st, &unary_expr/1, %{star: "*", slash: "/"})

  defp binary_left(st, next, ops) do
    {left, st} = next.(st)
    binary_rest(st, left, next, ops)
  end

  defp binary_rest(st, left, next, ops) do
    case peek(st) do
      {type, _, at} when is_map_key(ops, type) ->
        {_, st} = advance(st)
        st = skip_nl(st, :drop)
        {right, st} = next.(st)
        {e, st} = node(st, :bin, %{op: Map.fetch!(ops, type), l: left, r: right}, at)
        binary_rest(st, e, next, ops)

      _ ->
        {left, st}
    end
  end

  defp unary_expr(st) do
    case peek(st) do
      {:minus, _, at} ->
        {_, st} = advance(st)
        st = deeper(st, at)
        {e, st} = unary_expr(st)
        st = shallower(st)

        # fold `-3` into a literal so it prints and edits as one number
        case e do
          %{k: :num, v: v} -> {%{e | v: -v, at: Tuple.to_list(at)}, st}
          _ -> node(st, :un, %{op: "-", e: e}, at)
        end

      _ ->
        postfix(st)
    end
  end

  defp postfix(st) do
    {e, st} = primary(st)
    postfix_rest(st, e)
  end

  defp postfix_rest(st, e) do
    case peek(st) do
      {:dot, _, at} ->
        {_, st} = advance(st)
        {name, st} = expect_ident(st, "a field name after .")
        {f, st} = node(st, :field, %{obj: e, name: name}, at)
        postfix_rest(st, f)

      {:lbracket, _, at} ->
        {_, st} = advance(st)
        st = skip_nl(st, :drop)
        {i, st} = expr(st)
        st = st |> skip_nl(:drop) |> expect(:rbracket, "]")
        {f, st} = node(st, :index, %{obj: e, index: i}, at)
        postfix_rest(st, f)

      {:lparen, _, at} ->
        {_, st} = advance(st)
        st = deeper(st, at)
        {args, named, st} = args(st)
        # a call sits where its name starts, so errors point at the name
        {c, st} = node(shallower(st), :call, %{fn: e, args: args, named: named}, call_pos(e, at))
        postfix_rest(st, c)

      _ ->
        {e, st}
    end
  end

  defp call_pos(%{at: [line, col]}, _paren), do: {line, col}
  defp call_pos(_callee, paren), do: paren

  defp args(st) do
    st = skip_nl(st, :drop)

    case peek_type(st) do
      :rparen -> {[], [], st |> advance() |> elem(1)}
      _ -> arg_list(st, [], [])
    end
  end

  defp arg_list(st, args, named) do
    {args, named, st} =
      case {peek(st), peek2_type(st)} do
        {{:ident, name, at}, :colon} ->
          if Enum.any?(named, &(&1.name == name)), do: fail("#{name}: is given twice", at)
          st = st |> advance() |> elem(1) |> advance() |> elem(1) |> skip_nl(:drop)
          {value, st} = expr(st)
          {args, [%{name: name, expr: value} | named], st}

        {{_, _, at}, _} ->
          if named != [], do: fail("unnamed values come before named ones (name: value)", at)
          {value, st} = expr(st)
          {[value | args], named, st}
      end

    st = skip_nl(st, :drop)

    case peek_type(st) do
      :comma ->
        st = st |> advance() |> elem(1) |> skip_nl(:drop)

        if peek_type(st) == :rparen,
          do: {Enum.reverse(args), Enum.reverse(named), st |> advance() |> elem(1)},
          else: arg_list(st, args, named)

      :rparen ->
        {Enum.reverse(args), Enum.reverse(named), st |> advance() |> elem(1)}

      _ ->
        fail("expected , or ) in the list of values", pos(st))
    end
  end

  defp primary(st) do
    {tok, after_tok} = advance(st)

    case tok do
      {:number, {value, unit}, at} ->
        node(after_tok, :num, %{v: value, unit: unit_name(unit)}, at)

      {:string, parts, at} ->
        string_node(after_tok, parts, at)

      {:kw_true, _, at} ->
        node(after_tok, :bool, %{v: true}, at)

      {:kw_false, _, at} ->
        node(after_tok, :bool, %{v: false}, at)

      {:kw_nil, _, at} ->
        node(after_tok, :nil_lit, %{}, at)

      {:question, _, at} ->
        node(after_tok, :hole, %{}, at)

      {:ident, name, at} ->
        case peek_type(after_tok) do
          :arrow ->
            {_, st} = advance(after_tok)
            lambda_body(st, [name], at)

          _ ->
            node(after_tok, :ident, %{name: name}, at)
        end

      {:lparen, _, at} ->
        if lambda_ahead?(after_tok.toks) do
          {params, st} = params(after_tok, :rparen)
          st = expect(st, :arrow, "=>")
          lambda_body(st, params, at)
        else
          st = skip_nl(after_tok, :drop)
          {e, st} = expr(st)
          st = st |> skip_nl(:drop) |> expect(:rparen, ")")
          {e, st}
        end

      {:lbracket, _, at} ->
        st = deeper(after_tok, at)
        {items, st} = list_items(skip_nl(st, :drop), [])
        node(shallower(st), :list, %{items: items}, at)

      {:lbrace, _, at} ->
        st = deeper(after_tok, at)
        {entries, st} = map_entries(skip_nl(st, :drop), [])
        node(shallower(st), :map, %{entries: entries}, at)

      {_, value, at} ->
        fail("expected a value but found #{describe(value)}", at)
    end
  end

  defp unit_name(nil), do: nil
  defp unit_name(:duration), do: "duration"
  defp unit_name("%"), do: "percent"

  defp lambda_body(st, params, at) do
    st = skip_nl(st, :drop)
    {body, st} = expr(st)
    node(st, :lambda, %{params: params, body: body}, at)
  end

  # `(a, b) =>` ahead? Names and commas up to `)`, then the arrow.
  defp lambda_ahead?([{:rparen, _, _}, {:arrow, _, _} | _]), do: true
  defp lambda_ahead?([{:ident, _, _}, {:comma, _, _} | rest]), do: lambda_ahead?(rest)
  defp lambda_ahead?([{:ident, _, _}, {:rparen, _, _}, {:arrow, _, _} | _]), do: true
  defp lambda_ahead?(_), do: false

  defp list_items(st, acc) do
    case peek_type(st) do
      :rbracket ->
        {Enum.reverse(acc), st |> advance() |> elem(1)}

      _ ->
        {item, st} = expr(st)
        st = skip_nl(st, :drop)

        case peek_type(st) do
          :comma -> list_items(st |> advance() |> elem(1) |> skip_nl(:drop), [item | acc])
          :rbracket -> {Enum.reverse([item | acc]), st |> advance() |> elem(1)}
          _ -> fail("expected , or ] in the list", pos(st))
        end
    end
  end

  defp map_entries(st, acc) do
    case peek(st) do
      {:rbrace, _, _} ->
        {Enum.reverse(acc), st |> advance() |> elem(1)}

      {type, key, at} when type in [:ident, :string] ->
        key = map_key(type, key, at)
        if Enum.any?(acc, &(&1.key == key)), do: fail("the key #{key} appears twice", at)
        {_, st} = advance(st)
        st = expect(st, :colon, ": after the key")
        st = skip_nl(st, :drop)
        {value, st} = expr(st)
        st = skip_nl(st, :drop)
        acc = [%{key: key, value: value} | acc]

        case peek_type(st) do
          :comma -> map_entries(st |> advance() |> elem(1) |> skip_nl(:drop), acc)
          :rbrace -> {Enum.reverse(acc), st |> advance() |> elem(1)}
          _ -> fail("expected , or } in the record", pos(st))
        end

      {type, word, at} when is_binary(word) ->
        # reserved words such as `at` or `from` are fine as record keys
        if String.starts_with?(Atom.to_string(type), "kw_") do
          map_entries(%{st | toks: [{:ident, word, at} | tl(st.toks)]}, acc)
        else
          fail("expected a key (a name or text) but found #{describe(word)}", at)
        end

      {_, value, at} ->
        fail("expected a key (a name or text) but found #{describe(value)}", at)
    end
  end

  defp map_key(:ident, key, _at), do: key

  defp map_key(:string, parts, at) do
    case parts do
      [] -> ""
      [text] when is_binary(text) -> text
      _ -> fail("a record key can't contain {…}", at)
    end
  end

  # A text literal: plain when it has no {…} holes, a template otherwise.
  defp string_node(st, parts, at) do
    if Enum.all?(parts, &is_binary/1) do
      node(st, :str, %{v: Enum.join(parts)}, at)
    else
      {parts, st} =
        Enum.reduce(parts, {[], st}, fn
          text, {acc, st} when is_binary(text) ->
            {[text | acc], st}

          {:interp, tokens, p}, {acc, st} ->
            {e, st} = sub_expr(st, tokens, p)
            {[e | acc], st}
        end)

      node(st, :tmpl, %{parts: Enum.reverse(parts)}, at)
    end
  end

  defp sub_expr(st, tokens, p) do
    if tokens == [] or match?([{:eof, _, _}], tokens), do: fail("an empty {} inside text", p)
    saved = st.toks
    {e, sub} = expr(%{st | toks: tokens})
    expect_eof(sub)
    {e, %{sub | toks: saved}}
  end
end
