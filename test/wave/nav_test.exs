defmodule Wave.NavTest do
  use ExUnit.Case, async: true

  alias Wave.Nav

  #   1 — 2 — 3 — 4
  #       |
  #       5          9 (no lanes)
  @galaxy %{
    edges: [
      %{s1: %{id: 1}, s2: %{id: 2}},
      %{s1: %{id: 2}, s2: %{id: 3}},
      %{s1: %{id: 3}, s2: %{id: 4}},
      %{s1: %{id: 2}, s2: %{id: 5}}
    ]
  }

  test "path_hops walks lane by lane" do
    assert Nav.path_hops(@galaxy, 1, 4) == [{1, 2}, {2, 3}, {3, 4}]
    assert Nav.path_hops(@galaxy, 4, 5) == [{4, 3}, {3, 2}, {2, 5}]
  end

  test "path_hops is empty when already there and nil when unreachable" do
    assert Nav.path_hops(@galaxy, 3, 3) == []
    assert Nav.path_hops(@galaxy, 1, 9) == nil
  end

  test "a prebuilt adjacency gives the same answer as the galaxy" do
    adjacency = Nav.adjacency(@galaxy)
    assert Nav.path_hops(adjacency, 1, 4) == Nav.path_hops(@galaxy, 1, 4)
  end

  test "hop_distances covers every reachable system once" do
    assert Nav.hop_distances(Nav.adjacency(@galaxy), 1) == %{1 => 0, 2 => 1, 3 => 2, 4 => 3, 5 => 2}
  end
end
