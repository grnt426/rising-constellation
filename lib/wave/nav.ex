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

  @doc "Lane lengths as `%{{a, b} => weight}`, both directions, from galaxy edges."
  def lane_weights(%{edges: edges}) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      acc
      |> Map.put({edge.s1.id, edge.s2.id}, edge.weight)
      |> Map.put({edge.s2.id, edge.s1.id}, edge.weight)
    end)
  end

  def lane_weights(_), do: %{}

  @doc """
  Game time to walk `hops` (from `path_hops/3`): each lane's length times the
  engine's `character_movement_factor`, which is how a jump is timed
  (`Instance.Character.Actions.Jump.pre_validate/2`). nil when a lane is unknown.
  """
  def travel_ut(hops, weights, movement_factor) when is_list(hops) and is_number(movement_factor) do
    Enum.reduce_while(hops, 0.0, fn lane, acc ->
      case Map.get(weights, lane) do
        weight when is_number(weight) -> {:cont, acc + weight * movement_factor}
        _ -> {:halt, nil}
      end
    end)
  end

  def travel_ut(_hops, _weights, _movement_factor), do: nil

  @doc """
  Walking time from `from` to every system reachable within `max_ut`, as
  `%{system_id => ut}`: shortest by lane length, not by hop count, each lane
  timed like a jump (length × `movement_factor`). One Dijkstra instead of a
  path per candidate.
  """
  def travel_times(adjacency, weights, from, movement_factor, max_ut)
      when is_map(adjacency) and is_number(movement_factor) and is_number(max_ut) do
    do_travel_times(adjacency, weights, movement_factor, max_ut, :gb_sets.singleton({0.0, from}), %{from => 0.0})
  end

  defp do_travel_times(adjacency, weights, factor, max_ut, frontier, best) do
    if :gb_sets.is_empty(frontier) do
      best
    else
      {{ut, node}, frontier} = :gb_sets.take_smallest(frontier)

      if ut > Map.get(best, node, :infinity) do
        do_travel_times(adjacency, weights, factor, max_ut, frontier, best)
      else
        {frontier, best} =
          adjacency
          |> Map.get(node, [])
          |> Enum.reduce({frontier, best}, fn next, {f, b} ->
            case Map.get(weights, {node, next}) do
              weight when is_number(weight) ->
                arrival = ut + weight * factor

                if arrival <= max_ut and arrival < Map.get(b, next, :infinity),
                  do: {:gb_sets.add({arrival, next}, f), Map.put(b, next, arrival)},
                  else: {f, b}

              _ ->
                {f, b}
            end
          end)

        do_travel_times(adjacency, weights, factor, max_ut, frontier, best)
      end
    end
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
