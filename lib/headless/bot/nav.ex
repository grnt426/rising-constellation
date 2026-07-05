defmodule Headless.Bot.Nav do
  @moduledoc """
  Shared navigation over the galaxy's star-lane graph. Jumps are only legal
  along edges (`Galaxy.check_jump` → `:invalid_jump` otherwise, and invalid
  queued actions are silently swallowed), so any multi-system move is a
  chain of per-edge hops.
  """

  @doc """
  Shortest lane path (BFS by hop count) from `from` to `to` over
  `galaxy.edges`. Returns `[{from, to}, ...]` hop pairs, `[]` when already
  there, `nil` when disconnected.
  """
  def path_hops(galaxy, from, to) do
    adjacency =
      Enum.reduce(galaxy.edges, %{}, fn e, acc ->
        a = e.s1.id
        b = e.s2.id

        acc
        |> Map.update(a, [b], &[b | &1])
        |> Map.update(b, [a], &[a | &1])
      end)

    case bfs_path(adjacency, from, to) do
      nil -> nil
      path -> Enum.zip(path, tl(path))
    end
  end

  defp bfs_path(_adjacency, from, from), do: [from]

  defp bfs_path(adjacency, from, to) do
    do_bfs(adjacency, :queue.from_list([from]), %{from => nil}, to)
  end

  defp do_bfs(adjacency, queue, parents, to) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, node}, rest} ->
        neighbors = Map.get(adjacency, node, [])

        case Enum.find(neighbors, &(&1 == to)) do
          nil ->
            {queue, parents} =
              Enum.reduce(neighbors, {rest, parents}, fn n, {q, p} ->
                if Map.has_key?(p, n), do: {q, p}, else: {:queue.in(n, q), Map.put(p, n, node)}
              end)

            do_bfs(adjacency, queue, parents, to)

          _found ->
            unwind(Map.put(parents, to, node), to, [])
        end
    end
  end

  defp unwind(_parents, nil, acc), do: acc
  defp unwind(parents, node, acc), do: unwind(parents, Map.get(parents, node), [node | acc])
end
