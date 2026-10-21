defmodule Edict.SourceMap do
  @moduledoc """
  Where each node of a tree sits in its canonical text, and the text of
  single nodes: the two things the editor needs to show a graph and its code
  side by side (select a node, see its line; click a line, select its node),
  and to draw a node as an editable line of code.

  The printer's output parses back to the same tree (the round-trip
  property), so walking the program and the re-parsed text in step pairs
  every node with its position.
  """

  alias Edict.{AST, Parser, Printer}

  @doc "`%{node_id => [line, col]}` in `Printer.print(program)`."
  def positions(program, printed \\ nil) do
    printed = printed || Printer.print(program)

    case Parser.parse(printed) do
      {:ok, parsed} -> pair(program, parsed, %{})
      {:error, _} -> %{}
    end
  end

  defp pair(%{k: k} = a, %{k: k} = b, acc) do
    acc = if Map.has_key?(a, :id) and Map.has_key?(b, :at), do: Map.put(acc, a.id, b.at), else: acc

    a
    |> AST.children()
    |> Enum.zip(AST.children(b))
    |> Enum.reduce(acc, fn {x, y}, acc -> pair(x, y, acc) end)
  end

  defp pair(_a, _b, acc), do: acc

  @doc """
  The canonical text of the nodes named in `ids` (expressions print as one
  line, statements as their lines). At most 300 nodes.
  """
  def snippets(program, ids) when is_list(ids) do
    wanted = ids |> Enum.filter(&is_binary/1) |> Enum.take(300) |> MapSet.new()

    program
    |> AST.nodes()
    |> Enum.filter(&MapSet.member?(wanted, &1.id))
    |> Map.new(fn node ->
      text =
        if AST.kind_category(node.k) == :expr,
          do: Printer.print_expr(node),
          else: Printer.print_block([node])

      {node.id, text}
    end)
  end

  def snippets(_program, _ids), do: %{}
end
