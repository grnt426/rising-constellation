defmodule Edict.Lexer do
  @moduledoc """
  Turns Edict source text into tokens.

  A token is `{type, value, {line, col}}`. Every `type` is one of a fixed set
  of atoms written into this module; nothing the author writes ever becomes an
  atom (identifiers, keywords and operators stay binaries until they are
  matched against the fixed tables below). That keeps the BEAM's atom table,
  which is never garbage-collected, out of reach of any script.

  The lexer also enforces the source-level limits in `Edict.Limits`: total
  size, token count, identifier and string length, and characters that may
  not appear at all (raw control characters and the bidirectional overrides
  that can make code read differently from how it runs).
  """

  alias Edict.Limits

  @keywords %{
    "setup" => :kw_setup,
    "score" => :kw_score,
    "tiebreak" => :kw_tiebreak,
    "var" => :kw_var,
    "let" => :kw_let,
    "fn" => :kw_fn,
    "return" => :kw_return,
    "if" => :kw_if,
    "then" => :kw_then,
    "else" => :kw_else,
    "for" => :kw_for,
    "in" => :kw_in,
    "while" => :kw_while,
    "break" => :kw_break,
    "continue" => :kw_continue,
    "on" => :kw_on,
    "every" => :kw_every,
    "at" => :kw_at,
    "when" => :kw_when,
    "as" => :kw_as,
    "from" => :kw_from,
    "until" => :kw_until,
    "draft" => :kw_draft,
    "and" => :kw_and,
    "or" => :kw_or,
    "not" => :kw_not,
    "true" => :kw_true,
    "false" => :kw_false,
    "nil" => :kw_nil
  }

  @doc "The reserved words, for the editor's highlighter and the checker."
  def keywords, do: Map.keys(@keywords)

  # Two-character operators first, so `<=` never lexes as `<` then `=`.
  @ops2 %{"==" => :eq, "!=" => :neq, "<=" => :lte, ">=" => :gte, "=>" => :arrow}
  @ops1 %{
    "<" => :lt,
    ">" => :gt,
    "=" => :assign,
    "+" => :plus,
    "-" => :minus,
    "*" => :star,
    "/" => :slash,
    "(" => :lparen,
    ")" => :rparen,
    "{" => :lbrace,
    "}" => :rbrace,
    "[" => :lbracket,
    "]" => :rbracket,
    "," => :comma,
    "." => :dot,
    ":" => :colon,
    "?" => :question
  }

  # Seconds per duration unit. `%` is a unit too: `25%` is 0.25.
  @units %{"h" => 3600.0, "m" => 60.0, "s" => 1.0}

  # Unicode bidirectional controls (the "Trojan Source" characters): they can
  # make a shared script display differently from how it parses.
  @bidi [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F]

  @type pos :: {pos_integer(), pos_integer()}
  @type token :: {atom(), term(), pos}

  @doc "Tokenize `source`. Returns `{:ok, tokens}` or `{:error, %{message, line, col}}`."
  @spec tokenize(binary()) :: {:ok, [token]} | {:error, map()}
  def tokenize(source) when is_binary(source) do
    cond do
      byte_size(source) > Limits.max_source_bytes() ->
        error("the script is too long (#{Limits.max_source_bytes()} bytes at most)", {1, 1})

      not String.valid?(source) ->
        error("the script is not valid UTF-8 text", {1, 1})

      true ->
        try do
          {:ok, source |> lex({1, 1}, [], 0) |> Enum.reverse()}
        catch
          {:lex_error, message, pos} -> error(message, pos)
        end
    end
  end

  def tokenize(_), do: error("the script must be text", {1, 1})

  defp error(message, {line, col}), do: {:error, %{message: message, line: line, col: col}}

  defp fail(message, pos), do: throw({:lex_error, message, pos})

  defp push(acc, token, count) do
    if count >= Limits.max_tokens(), do: fail("the script has too many tokens", elem(token, 2))
    [token | acc]
  end

  # --- main loop -------------------------------------------------------------

  defp lex(<<>>, pos, acc, count), do: push(acc, {:eof, nil, pos}, count)

  defp lex(<<c, rest::binary>>, {line, col}, acc, count) when c in [?\s, ?\t, ?\r],
    do: lex(rest, {line, col + 1}, acc, count)

  defp lex(<<?\n, rest::binary>>, {line, col}, acc, count) do
    # a second line break in a row marks a blank line (it detaches a
    # comment block from what follows it)
    acc =
      case acc do
        [{:nl, _, at} | rest] -> [{:nl, :blank, at} | rest]
        _ -> push(acc, {:nl, nil, {line, col}}, count + 1)
      end

    lex(rest, {line + 1, 1}, acc, count + 1)
  end

  defp lex(<<?;, rest::binary>>, {line, col}, acc, count),
    do: lex(rest, {line, col + 1}, push(acc, {:nl, nil, {line, col}}, count), count + 1)

  defp lex(<<?#, rest::binary>>, {line, col}, acc, count) do
    {text, rest_after} = take_line(rest)
    check_text(text, {line, col})
    note = String.trim(text)
    lex(rest_after, {line, col + String.length(text) + 1}, push(acc, {:comment, note, {line, col}}, count), count + 1)
  end

  defp lex(<<?", rest::binary>>, pos, acc, count) do
    {parts, rest_after, end_pos} = string(rest, next_col(pos, 1), [], [], {pos, 0})
    lex(rest_after, end_pos, push(acc, {:string, parts, pos}, count), count + 1)
  end

  defp lex(<<c, _::binary>> = src, pos, acc, count) when c in ?0..?9 do
    {token, rest, end_pos} = number(src, pos)
    lex(rest, end_pos, push(acc, token, count), count + 1)
  end

  defp lex(<<c, _::binary>> = src, pos, acc, count) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, rest} = take_word(src, "")

    if byte_size(word) > Limits.max_identifier() do
      fail("a name can be at most #{Limits.max_identifier()} characters long", pos)
    end

    token =
      case Map.fetch(@keywords, word) do
        {:ok, kw} -> {kw, word, pos}
        :error -> {:ident, word, pos}
      end

    lex(rest, next_col(pos, byte_size(word)), push(acc, token, count), count + 1)
  end

  for {op, type} <- @ops2 do
    defp lex(<<unquote(op), rest::binary>>, pos, acc, count) do
      lex(rest, next_col(pos, 2), push(acc, {unquote(type), unquote(op), pos}, count), count + 1)
    end
  end

  for {op, type} <- @ops1 do
    defp lex(<<unquote(op), rest::binary>>, pos, acc, count) do
      lex(rest, next_col(pos, 1), push(acc, {unquote(type), unquote(op), pos}, count), count + 1)
    end
  end

  defp lex(src, pos, _acc, _count) do
    {char, _} = String.next_grapheme(src)
    fail("unexpected character #{inspect(char)}", pos)
  end

  defp next_col({line, col}, n), do: {line, col + n}

  defp take_line(src) do
    case :binary.match(src, "\n") do
      {at, _} -> {binary_part(src, 0, at), binary_part(src, at, byte_size(src) - at)}
      :nomatch -> {src, ""}
    end
  end

  defp take_word(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: take_word(rest, <<acc::binary, c>>)

  defp take_word(rest, acc), do: {acc, rest}

  # Comments and strings may hold any printable text, but no raw control
  # characters and no bidirectional overrides.
  defp check_text(text, pos) do
    text
    |> String.to_charlist()
    |> Enum.each(fn cp ->
      cond do
        cp in @bidi -> fail("the script contains a hidden text-direction character", pos)
        cp < 0x20 and cp != ?\t -> fail("the script contains a control character", pos)
        cp == 0x7F -> fail("the script contains a control character", pos)
        true -> :ok
      end
    end)
  end

  # --- numbers ---------------------------------------------------------------

  # 1_000, 2.5, 15s, 1m30s, 25%. Every number is a float: there is no integer
  # type, so no bignum arithmetic for a script to blow up.
  defp number(src, pos) do
    {digits, rest} = take_number_text(src, "")

    if byte_size(digits) > 32, do: fail("this number is too long", pos)

    value = parse_float(digits, pos)

    case rest do
      <<?%, after_pct::binary>> ->
        ensure_number_end(after_pct, pos)
        {{:number, {value / 100, "%"}, pos}, after_pct, next_col(pos, byte_size(digits) + 1)}

      <<u, after_unit::binary>> when u in [?h, ?m, ?s] ->
        {seconds, rest_after, width} =
          duration(value * Map.fetch!(@units, <<u>>), after_unit, byte_size(digits) + 1, pos)

        ensure_number_end(rest_after, pos)
        {{:number, {seconds, :duration}, pos}, rest_after, next_col(pos, width)}

      _ ->
        ensure_number_end(rest, pos)
        {{:number, {value, nil}, pos}, rest, next_col(pos, byte_size(digits))}
    end
  end

  # The rest of a compound duration such as 1m30s, after its first unit.
  defp duration(total, <<c, _::binary>> = src, width, pos) when c in ?0..?9 do
    {digits, rest} = take_number_text(src, "")
    value = parse_float(digits, pos)

    case rest do
      <<u, after_unit::binary>> when u in [?h, ?m, ?s] ->
        duration(total + value * Map.fetch!(@units, <<u>>), after_unit, width + byte_size(digits) + 1, pos)

      _ ->
        fail("a duration such as 1m30s needs a unit after every number", pos)
    end
  end

  defp duration(total, rest, width, _pos), do: {total, rest, width}

  defp take_number_text(<<c, rest::binary>>, acc) when c in ?0..?9 or c == ?_,
    do: take_number_text(rest, <<acc::binary, c>>)

  defp take_number_text(<<?., c, rest::binary>>, acc) when c in ?0..?9 do
    if String.contains?(acc, "."),
      do: {acc, <<?., c, rest::binary>>},
      else: take_number_text(rest, <<acc::binary, ?., c>>)
  end

  defp take_number_text(rest, acc), do: {acc, rest}

  defp parse_float(digits, pos) do
    clean = String.replace(digits, "_", "")

    if clean == "" or String.ends_with?(digits, "_") or String.contains?(digits, "__") do
      fail("malformed number #{inspect(digits)}", pos)
    end

    {value, ""} = Float.parse(clean)
    value
  end

  defp ensure_number_end(<<c, _::binary>>, pos)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    fail("a number can only end in s, m, h (a duration) or % (a percentage)", pos)
  end

  defp ensure_number_end(_, _), do: :ok

  # --- strings ---------------------------------------------------------------

  # A string is a list of parts: literal binaries and {:interp, tokens, pos}
  # for each `{expr}` hole. The hole's tokens are lexed here and parsed by
  # the parser as a single expression.
  defp string(<<?", rest::binary>>, pos, buf, parts, _start), do: {finish_parts(buf, parts), rest, next_col(pos, 1)}

  defp string(<<>>, _pos, _buf, _parts, {start, _}), do: fail("this text is missing its closing quote", start)

  defp string(<<?\n, _::binary>>, _pos, _buf, _parts, {start, _}),
    do: fail("this text is missing its closing quote", start)

  defp string(<<?\\, c, rest::binary>>, pos, buf, parts, start) do
    char =
      case c do
        ?n -> "\n"
        ?t -> "\t"
        ?" -> "\""
        ?\\ -> "\\"
        ?{ -> "{"
        ?} -> "}"
        _ -> fail("unknown escape \\#{<<c>>} (use \\n, \\t, \\\", \\\\, \\{ or \\})", pos)
      end

    string(rest, next_col(pos, 2), [char | buf], parts, grow(start, 1))
  end

  defp string(<<?{, rest::binary>>, pos, buf, parts, start) do
    case :binary.match(rest, "}") do
      {at, _} ->
        inner = binary_part(rest, 0, at)

        if String.contains?(inner, ["\"", "\n", "{"]) do
          fail("a {…} inside text can hold a simple expression only (no quotes or braces)", pos)
        end

        tokens =
          case tokenize(inner) do
            {:ok, toks} -> toks |> Enum.reject(&match?({:nl, _, _}, &1))
            {:error, %{message: message}} -> fail(message, pos)
          end

        after_hole = binary_part(rest, at + 1, byte_size(rest) - at - 1)
        parts = [{:interp, tokens, pos} | flush(buf, parts)]
        string(after_hole, next_col(pos, String.length(inner) + 2), [], parts, grow(start, byte_size(inner)))

      :nomatch ->
        fail("a { inside text needs its closing } (write \\{ for a literal brace)", pos)
    end
  end

  defp string(src, pos, buf, parts, start) do
    {grapheme, rest} = String.next_grapheme(src)
    check_text(grapheme, pos)
    string(rest, next_col(pos, 1), [grapheme | buf], parts, grow(start, byte_size(grapheme)))
  end

  # Track the text's length as it grows, failing past the limit.
  defp grow({start, length}, n) do
    if length + n > Limits.max_string() do
      fail("this text is too long (#{Limits.max_string()} characters at most)", start)
    end

    {start, length + n}
  end

  defp flush([], parts), do: parts
  defp flush(buf, parts), do: [buf |> Enum.reverse() |> IO.iodata_to_binary() | parts]

  defp finish_parts(buf, parts), do: buf |> flush(parts) |> Enum.reverse()
end
