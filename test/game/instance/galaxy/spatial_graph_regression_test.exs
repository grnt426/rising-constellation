defmodule Game.Instance.Galaxy.SpatialGraphRegressionTest do
  @moduledoc """
  Proves the optimized `Instance.Galaxy.SpatialGraph.generate_edges/2`
  (spatial-grid neighbor scan + MapSet component assembly) produces output
  **byte-identical** to the original all-pairs implementation, which is
  embedded below as the reference. Layouts are seeded and cover the paths
  that differ mechanically between the two implementations:

    * connected radius graph (assemble is a no-op)
    * fragmented graph (multi-pass component assembly)
    * blackhole inside the cloud (radius-phase edge filtering)
    * blackhole between clusters (assemble couple filtering + fallback)

  Pure-function test — no DB, no instance tree.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Instance.Galaxy.SpatialGraph
  alias Spatial.Position

  # The pre-optimization implementation, verbatim (minus timing wraps).
  # If `SpatialGraph` is ever intentionally changed to produce different
  # edges, this reference must be updated in the same commit — the point of
  # this module is to catch *unintentional* divergence from refactors.
  defmodule Reference do
    alias Spatial.Position

    @max_dist 12
    @max_dist_squared @max_dist * @max_dist

    defp distance(system_1, system_2), do: Position.distance(system_1.position, system_2.position)
    defp dist_squared(system_1, system_2), do: Position.dist_squared(system_1.position, system_2.position)

    def generate_edges(systems, blackholes) do
      travel_graph = Graph.new(type: :undirected)
      systems_by_id = Enum.reduce(systems, %{}, fn sys, acc -> Map.put(acc, sys.id, sys) end)
      travel_graph = Enum.reduce(systems, travel_graph, fn system, acc -> Graph.add_vertex(acc, system.id) end)

      travel_graph =
        Enum.reduce(systems, travel_graph, fn system, acc ->
          near_blackholes =
            Enum.filter(blackholes, fn b ->
              Position.dist_squared(b.position, system.position) < :math.pow(@max_dist + b.radius, 2)
            end)

          neighbors =
            systems
            |> Enum.filter(fn s -> dist_squared(system, s) < @max_dist_squared and s.id != system.id end)
            |> Enum.filter(fn s -> not edge_traverse_a_blackhole?(s, system, near_blackholes) end)

          Enum.reduce(neighbors, acc, fn n, acc2 ->
            Graph.add_edge(acc2, system.id, n.id, weight: distance(system, n))
          end)
        end)

      travel_graph = assemble_graph_components(travel_graph, systems, systems_by_id, blackholes)

      Graph.edges(travel_graph)
      |> Enum.map(fn edge ->
        %{
          s1: systems_by_id[edge.v1],
          s2: systems_by_id[edge.v2],
          weight: edge.weight
        }
      end)
    end

    defp assemble_graph_components(graph, systems, systems_by_id, blackholes) do
      if length(Graph.components(graph)) == 1 do
        graph
      else
        graph =
          Enum.reduce(Graph.components(graph), graph, fn component, acc1 ->
            nearest_couples =
              Task.async_stream(component, fn system_id ->
                system = systems_by_id[system_id]

                nearest_neighbor =
                  Enum.min_by(systems, fn s ->
                    if s.id == system.id or Enum.member?(component, s.id),
                      do: :infinity,
                      else: distance(system, s)
                  end)

                distance = distance(system, nearest_neighbor)

                {system, nearest_neighbor, distance}
              end)
              |> Stream.map(fn {:ok, result} -> result end)
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

  # ---- layout builders (seeded, deterministic) -------------------------------

  defp cloud(seed, n, {x0, y0}, {w, h}, id_start) do
    :rand.seed(:exsss, seed)

    Enum.map(0..(n - 1), fn i ->
      %{
        id: id_start + i,
        position: %Position{x: x0 + :rand.uniform() * w, y: y0 + :rand.uniform() * h}
      }
    end)
  end

  defp blackhole(x, y, radius) do
    %{position: %Position{x: x, y: y}, radius: radius}
  end

  defp assert_identical(systems, blackholes) do
    new_edges = SpatialGraph.generate_edges(systems, blackholes)
    old_edges = Reference.generate_edges(systems, blackholes)

    assert new_edges == old_edges
    new_edges
  end

  defp connected?(systems, edges) do
    graph =
      Enum.reduce(systems, Graph.new(type: :undirected), fn s, g -> Graph.add_vertex(g, s.id) end)

    graph = Enum.reduce(edges, graph, fn e, g -> Graph.add_edge(g, e.s1.id, e.s2.id) end)
    length(Graph.components(graph)) == 1
  end

  # ---- cases -----------------------------------------------------------------

  test "dense connected cloud — radius phase only" do
    systems = cloud({1, 2, 3}, 250, {0, 0}, {60, 60}, 1)

    edges = assert_identical(systems, [])
    assert edges != []
    assert connected?(systems, edges)
  end

  test "fragmented clusters and singletons — multi-pass component assembly" do
    systems =
      cloud({4, 5, 6}, 80, {0, 0}, {30, 30}, 1) ++
        cloud({7, 8, 9}, 80, {60, 0}, {30, 30}, 1_000) ++
        cloud({10, 11, 12}, 80, {0, 60}, {30, 30}, 2_000) ++
        [%{id: 9_001, position: %Position{x: 120.0, y: 120.0}}] ++
        [%{id: 9_002, position: %Position{x: -40.0, y: -40.0}}]

    edges = assert_identical(systems, [])
    assert connected?(systems, edges)
  end

  test "blackhole inside a cloud — radius-phase edge filtering" do
    systems = cloud({13, 14, 15}, 200, {0, 0}, {50, 50}, 1)
    blackholes = [blackhole(25.0, 25.0, 8)]

    edges = assert_identical(systems, blackholes)
    assert edges != []
  end

  test "blackhole between clusters — assemble couple filtering and fallback" do
    # Two clusters separated by more than @max_dist with a blackhole sitting
    # on the corridor between them, so the nearest joining couples cross it
    # and the assemble pass has to walk down its sorted list (or fall back).
    systems =
      cloud({16, 17, 18}, 60, {0, 0}, {25, 25}, 1) ++
        cloud({19, 20, 21}, 60, {45, 0}, {25, 25}, 500)

    blackholes = [blackhole(35.0, 12.5, 6)]

    edges = assert_identical(systems, blackholes)
    assert connected?(systems, edges)
  end

  test "grid cells behave at negative coordinates and cell boundaries" do
    # Positions straddling 0 and exact multiples of the 12-unit cell size —
    # catches off-by-one cell assignment (floor vs div) on the grid path.
    systems = [
      %{id: 1, position: %Position{x: -0.5, y: -0.5}},
      %{id: 2, position: %Position{x: 0.5, y: 0.5}},
      %{id: 3, position: %Position{x: 12.0, y: 0.0}},
      %{id: 4, position: %Position{x: 23.9, y: 0.1}},
      %{id: 5, position: %Position{x: 24.1, y: -0.1}},
      %{id: 6, position: %Position{x: 36.5, y: 0.0}},
      %{id: 7, position: %Position{x: -12.1, y: -11.9}}
    ]

    edges = assert_identical(systems, [])
    assert connected?(systems, edges)
  end
end
