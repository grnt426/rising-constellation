defmodule Instance.Galaxy.SpatialGraph do
  alias Spatial.Position

  require Logger

  @max_dist 12
  @max_dist_squared @max_dist * @max_dist

  defp distance(system_1, system_2) do
    Position.distance(system_1.position, system_2.position)
  end

  defp dist_squared(system_1, system_2) do
    Position.dist_squared(system_1.position, system_2.position)
  end

  def generate_edges(systems, blackholes) do
    travel_graph = Graph.new(type: :undirected)
    systems_by_id = Enum.reduce(systems, %{}, fn sys, acc -> Map.put(acc, sys.id, sys) end)
    travel_graph = Enum.reduce(systems, travel_graph, fn system, acc -> Graph.add_vertex(acc, system.id) end)

    # Spatial hash with cell size @max_dist: any two systems closer than
    # @max_dist are in the same or adjacent cells, so the neighbor scan only
    # examines the 3×3 neighborhood instead of all N systems. Same distance
    # predicate and weights as the naive all-pairs scan — the edge set is
    # identical (guarded by SpatialGraphRegressionTest) — but O(N·k) instead
    # of O(N²): 21s → sub-second at 6.6k systems.
    grid = build_grid(systems)

    travel_graph =
      Util.PhaseTimer.timed("edges/radius_graph", fn ->
        Enum.reduce(systems, travel_graph, fn system, acc ->
          # since sqrt(x) < sqrt(y) <=> x < y we can avoid an expensive sqrt(x) in multiple loop

          # get blackholes that could interfer with current systems edges
          near_blackholes =
            Enum.filter(blackholes, fn b ->
              Position.dist_squared(b.position, system.position) < :math.pow(@max_dist + b.radius, 2)
            end)

          # Sort candidates back into `systems` order (their original index)
          # so edges are added in exactly the order the all-pairs scan used —
          # keeps the output list byte-identical, not just set-identical.
          neighbors =
            grid
            |> grid_candidates(system)
            |> Enum.filter(fn {_idx, s} -> dist_squared(system, s) < @max_dist_squared and s.id != system.id end)
            |> Enum.sort_by(fn {idx, _s} -> idx end)
            |> Enum.map(fn {_idx, s} -> s end)
            |> Enum.filter(fn s -> not edge_traverse_a_blackhole?(s, system, near_blackholes) end)

          Enum.reduce(neighbors, acc, fn n, acc2 ->
            Graph.add_edge(acc2, system.id, n.id, weight: distance(system, n))
          end)
        end)
      end)

    travel_graph =
      Util.PhaseTimer.timed("edges/assemble_components", fn ->
        assemble_graph_components(travel_graph, systems, systems_by_id, blackholes)
      end)

    Util.PhaseTimer.timed("edges/dump_edge_list", fn ->
      Graph.edges(travel_graph)
      |> Enum.map(fn edge ->
        %{
          s1: systems_by_id[edge.v1],
          s2: systems_by_id[edge.v2],
          weight: edge.weight
        }
      end)
    end)
  end

  defp build_grid(systems) do
    systems
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {system, idx}, acc ->
      Map.update(acc, cell_of(system.position), [{idx, system}], fn entries -> [{idx, system} | entries] end)
    end)
  end

  defp cell_of(%{x: x, y: y}) do
    {floor(x / @max_dist), floor(y / @max_dist)}
  end

  defp grid_candidates(grid, system) do
    {cx, cy} = cell_of(system.position)

    for dx <- -1..1,
        dy <- -1..1,
        entry <- Map.get(grid, {cx + dx, cy + dy}, []),
        do: entry
  end

  # Joins disconnected components of the radius graph by repeatedly adding,
  # for each component, the shortest non-blackhole-crossing edge to a system
  # outside it, until one component remains.
  #
  # Deliberately the same algorithm as the original (same couples, same sort,
  # same blackhole fallback — output is byte-identical); the wins are pure
  # mechanics: Graph.components is computed once per pass instead of twice,
  # and component membership is a MapSet instead of an `Enum.member?` walk of
  # a list — that list walk inside a min_by over all systems was ~80% of a
  # 6.6k-system boot's edge cost (72s for a 2-component galaxy; now <1s).
  defp assemble_graph_components(graph, systems, systems_by_id, blackholes) do
    components = Graph.components(graph)
    component_count = length(components)
    Logger.warning("[boot-timing] edges/components_remaining: #{component_count}")

    if component_count == 1 do
      graph
    else
      graph =
        Enum.reduce(components, graph, fn component, acc1 ->
          component_set = MapSet.new(component)

          # Chunked fan-out: one task per member would copy the closure
          # (all systems + the component MapSet, ~2MB at 6.6k systems) into
          # every spawned process — ~13GB of term-copying for a big
          # component. Chunks keep the copies to one per task while
          # preserving member order (chunks are ordered, results are
          # flattened in order), so the output stays byte-identical.
          nearest_couples =
            component
            |> Enum.chunk_every(500)
            |> Task.async_stream(
              fn chunk ->
                Enum.map(chunk, fn system_id ->
                  system = systems_by_id[system_id]

                  nearest_neighbor =
                    Enum.min_by(systems, fn s ->
                      if s.id == system.id or MapSet.member?(component_set, s.id),
                        do: :infinity,
                        else: distance(system, s)
                    end)

                  distance = distance(system, nearest_neighbor)

                  {system, nearest_neighbor, distance}
                end)
              end,
              timeout: :infinity
            )
            |> Stream.flat_map(fn {:ok, results} -> results end)
            |> Enum.to_list()

          nearest_couples_sorted = Enum.sort(nearest_couples, fn {_, _, d1}, {_, _, d2} -> d1 <= d2 end)

          nearest_couple =
            Enum.reduce(nearest_couples_sorted, nil, fn {origin, target, distance}, acc ->
              if is_nil(acc) and not edge_traverse_a_blackhole?(origin, target, blackholes) do
                {origin, target, distance}
              else
                acc
              end
            end)

          {origin, target, distance} =
            case nearest_couple do
              nil -> hd(nearest_couples_sorted)
              nearest_couple -> nearest_couple
            end

          Graph.add_edge(acc1, origin.id, target.id, weight: distance)
        end)

      assemble_graph_components(graph, systems, systems_by_id, blackholes)
    end
  end

  # Find out if the edge between sys1 and sys2 traverse the given disk (blackhole)
  # adapted from there : https://stackoverflow.com/a/1084899
  # probably not the best solution
  # maybe dig from there http://paulbourke.net/geometry/pointlineplane/
  defp edge_traverse_a_blackhole?(sys1, sys2, blackholes) do
    p1 = sys1.position
    p2 = sys2.position
    p1p2 = Position.substr(p2, p1)
    norm = Position.dot(p1p2, p1p2)

    Enum.any?(blackholes, fn b ->
      p3 = b.position
      p1p3 = Position.substr(p1, p3)
      d1 = 2 * Position.dot(p1p3, p1p2)
      d2 = Position.dot(p1p3, p1p3) - b.radius * b.radius
      discriminant = d1 * d1 - 4 * norm * d2

      if discriminant < 0 do
        false
      else
        discriminant = :math.sqrt(discriminant)
        t1 = (-d1 - discriminant) / (2 * norm)
        t2 = (-d1 + discriminant) / (2 * norm)

        cond do
          t1 >= 0 && t1 <= 1 -> true
          t2 >= 0 && t2 <= 1 -> true
          true -> false
        end
      end
    end)
  end
end
