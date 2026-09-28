defmodule Wave.Nav do
  @moduledoc """
  Navigation over the galaxy's star-lane graph.

  A jump is only legal along an existing lane (`Instance.Galaxy.Galaxy.check_jump/3`
  answers `:invalid_jump` otherwise, and an invalid queued action is silently
  dropped by `Instance.Character.ActionImpl.pre_validate_action/2`). Any move
  further than one lane is therefore a CHAIN of per-lane hops, which is what
  `path_hops/3` returns.

  The engine has no server-side pathfinder — the client builds its own graph
  from `galaxy.edges`, and so do we. Build the adjacency once per decision pass
  with `adjacency/1` and reuse it; `galaxy.edges` is a flat list and rebuilding
  it per agent would be wasteful on a large map.
  """

  @doc "Undirected adjacency map `%{system_id => [system_id]}` from galaxy edges."
  def adjacency(%{edges: edges}) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      a = edge.s1.id
      b = edge.s2.id

      acc
      |> Map.update(a, [b], &[b | &1])
      |> Map.update(b, [a], &[a | &1])
    end)
  end

  def adjacency(_), do: %{}

  @doc """
  Shortest lane path by hop count, as `[{from, to}, ...]` pairs ready to be
  turned into jump actions. `[]` when already there, `nil` when unreachable.

  Accepts either a galaxy struct or a prebuilt adjacency map.
  """
  def path_hops(galaxy_or_adjacency, from, to)

  def path_hops(_graph, from, to) when from == to, do: []

  def path_hops(%{edges: _} = galaxy, from, to), do: path_hops(adjacency(galaxy), from, to)

  def path_hops(adjacency, from, to) when is_map(adjacency) do
    case bfs(adjacency, from, to) do
      nil -> nil
      path -> Enum.zip(path, tl(path))
    end
  end

  @doc """
  Hop distance from `from` to every reachable system, as `%{system_id => hops}`.
  One BFS instead of one per candidate — use this to rank many targets.
  """
  def hop_distances(adjacency, from) when is_map(adjacency) do
    do_distances(adjacency, :queue.from_list([from]), %{from => 0})
  end

  # --- internals ------------------------------------------------------------

  defp bfs(adjacency, from, to) do
    walk(adjacency, :queue.from_list([from]), %{from => nil}, to)
  end

  defp walk(adjacency, queue, parents, to) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, node}, rest} ->
        neighbours = Map.get(adjacency, node, [])

        if to in neighbours do
          unwind(Map.put(parents, to, node), to, [])
        else
          {queue, parents} =
            Enum.reduce(neighbours, {rest, parents}, fn n, {q, p} ->
              if Map.has_key?(p, n),
                do: {q, p},
                else: {:queue.in(n, q), Map.put(p, n, node)}
            end)

          walk(adjacency, queue, parents, to)
        end
    end
  end

  defp unwind(_parents, nil, acc), do: acc
  defp unwind(parents, node, acc), do: unwind(parents, Map.get(parents, node), [node | acc])

  defp do_distances(adjacency, queue, seen) do
    case :queue.out(queue) do
      {:empty, _} ->
        seen

      {{:value, node}, rest} ->
        depth = Map.fetch!(seen, node)

        {queue, seen} =
          adjacency
          |> Map.get(node, [])
          |> Enum.reduce({rest, seen}, fn n, {q, s} ->
            if Map.has_key?(s, n),
              do: {q, s},
              else: {:queue.in(n, q), Map.put(s, n, depth + 1)}
          end)

        do_distances(adjacency, queue, seen)
    end
  end
end
