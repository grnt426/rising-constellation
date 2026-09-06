defmodule Game.Instance.Galaxy.SectorAdjacencyTest do
  @moduledoc """
  Regression coverage for `Instance.Galaxy.Galaxy.put_adjacent_sectors/1`.

  Sector adjacency drives `check_system_takeability/3` — a faction may
  colonize / conquer / make dominion in a sector only when it owns that
  sector or an *adjacent* one. Until 2026-09 adjacency came from the
  `collision` package's Separating Axis test, which is only valid for
  convex polygons. Sectors are hand-drawn and mostly concave, so a vertex
  of one sector sitting inside a neighbour's convex-hull "notch" was
  reported as a collision even though the two polygons never touch.

  Live case: prod instance 121 ("Citadel"). Zinavitzan, the unowned
  central sector, was listed adjacent to Zoggan, Dor-Valon and Ougar —
  none of which border it. Dor-Valon was Tetrarchy-owned, which made the
  whole centre colonizable for Tetrarchy from a sector two hops away.

  Pure-function test — no DB, no instance tree.
  """
  use ExUnit.Case, async: true

  alias Instance.Galaxy.Galaxy
  alias Instance.Galaxy.Sector

  # Scenario 145 ("Citadel") sector polygons, verbatim from prod
  # `scenarios.game_data->'sectors'` on 2026-09-06. Rings are closed
  # (first point repeated last) exactly as the map editor stores them.
  @citadel [
    {0, "Zinavitzan",
     [
       [100, 111],
       [106, 109],
       [111, 103],
       [110, 96],
       [103, 92],
       [93, 89],
       [84, 92],
       [86, 103],
       [87, 106],
       [94, 110],
       [100, 111]
     ]},
    {1, "Persiennes", [[109, 82], [96, 83], [89, 82], [87, 81], [84, 92], [93, 89], [103, 92], [109, 82]]},
    {2, "Nooka",
     [[106, 109], [113, 108], [113, 103], [116, 93], [109, 82], [103, 92], [110, 96], [111, 103], [106, 109]]},
    {3, "Khamawad",
     [[84, 116], [92, 114], [101, 113], [110, 118], [113, 108], [106, 109], [100, 111], [94, 110], [87, 106], [84, 116]]},
    {4, "Qaryan",
     [[84, 92], [87, 81], [80, 80], [78, 92], [73, 103], [73, 107], [84, 116], [87, 106], [86, 103], [84, 92]]},
    {5, "Zoggan",
     [
       [110, 118],
       [101, 113],
       [92, 114],
       [98, 124],
       [105, 125],
       [113, 126],
       [117, 118],
       [122, 115],
       [123, 108],
       [127, 97],
       [113, 103],
       [113, 108],
       [110, 118]
     ]},
    {6, "Dor-Valon",
     [
       [116, 93],
       [113, 103],
       [127, 97],
       [124, 90],
       [121, 84],
       [116, 84],
       [112, 77],
       [105, 74],
       [103, 76],
       [96, 83],
       [109, 82],
       [116, 93]
     ]},
    {7, "Doriennes",
     [
       [80, 80],
       [87, 81],
       [89, 82],
       [96, 83],
       [103, 76],
       [89, 78],
       [86, 68],
       [78, 65],
       [72, 71],
       [73, 77],
       [72, 82],
       [71, 88],
       [70, 96],
       [78, 92],
       [80, 80]
     ]},
    {8, "Ougar",
     [
       [84, 116],
       [73, 107],
       [73, 103],
       [78, 92],
       [70, 96],
       [63, 100],
       [69, 108],
       [73, 114],
       [72, 121],
       [85, 122],
       [95, 126],
       [98, 124],
       [92, 114],
       [84, 116]
     ]},
    {9, "Urk",
     [
       [101, 48],
       [98, 53],
       [95, 57],
       [91, 67],
       [86, 68],
       [89, 78],
       [103, 76],
       [103, 66],
       [104, 61],
       [106, 59],
       [101, 48]
     ]},
    {10, "Algeziroi",
     [[125, 50], [122, 42], [118, 40], [107, 46], [101, 48], [106, 59], [110, 51], [117, 55], [125, 50]]},
    {11, "Sogdiennes",
     [[136, 47], [131, 39], [124, 40], [122, 42], [125, 50], [133, 55], [145, 60], [138, 48], [136, 47]]},
    {12, "Vishapir", [[161, 78], [165, 68], [155, 60], [151, 52], [138, 48], [145, 60], [154, 68], [161, 78]]},
    {13, "Ketzura",
     [
       [170, 94],
       [178, 94],
       [187, 86],
       [194, 78],
       [191, 66],
       [187, 63],
       [180, 60],
       [171, 61],
       [165, 68],
       [161, 78],
       [160, 83],
       [170, 94]
     ]},
    {14, "Urnuzi",
     [
       [103, 150],
       [110, 147],
       [114, 145],
       [107, 135],
       [105, 125],
       [98, 124],
       [95, 126],
       [85, 122],
       [90, 131],
       [97, 139],
       [103, 150]
     ]},
    {15, "Bir-Harrana",
     [[106, 171], [112, 166], [119, 156], [114, 145], [110, 147], [103, 150], [108, 154], [103, 164], [106, 171]]},
    {16, "Sidnariennes",
     [[79, 165], [80, 166], [88, 172], [101, 169], [106, 171], [103, 164], [91, 162], [87, 157], [79, 165]]},
    {17, "Persiennes",
     [
       [63, 150],
       [53, 152],
       [48, 152],
       [46, 162],
       [52, 158],
       [57, 162],
       [65, 166],
       [79, 165],
       [87, 157],
       [79, 157],
       [68, 154],
       [63, 150]
     ]},
    {18, "Harara",
     [
       [16, 155],
       [27, 163],
       [33, 165],
       [42, 169],
       [46, 162],
       [48, 152],
       [47, 137],
       [42, 135],
       [35, 132],
       [26, 128],
       [17, 132],
       [20, 144],
       [18, 150],
       [16, 155]
     ]}
  ]

  defp sector(id, name, points) do
    %Sector{
      id: id,
      name: name,
      centroid: [0.0, 0.0],
      area: 0.0,
      points: points,
      adjacent: [],
      owner: nil,
      starter?: false,
      victory_points: 1,
      division: []
    }
  end

  defp adjacency(specs) do
    specs
    |> Enum.map(fn {id, name, points} -> sector(id, name, points) end)
    |> Galaxy.put_adjacent_sectors()
    |> Map.new(fn %Sector{id: id, adjacent: adjacent} -> {id, Enum.sort(adjacent)} end)
  end

  describe "Citadel (prod instance 121) regression" do
    test "Zinavitzan borders exactly the four sectors it shares a boundary with" do
      adj = adjacency(@citadel)

      # Persiennes(1), Nooka(2), Khamawad(3), Qaryan(4) — never Zoggan(5),
      # Dor-Valon(6) or Ougar(8), the phantom neighbours SAT produced.
      assert adj[0] == [1, 2, 3, 4]
    end

    test "the phantom pairs are gone in both directions" do
      adj = adjacency(@citadel)

      for phantom <- [5, 6, 8] do
        refute phantom in adj[0], "Zinavitzan still lists #{phantom}"
        refute 0 in adj[phantom], "sector #{phantom} still lists Zinavitzan"
      end
    end

    test "every real border neighbour is kept" do
      adj = adjacency(@citadel)

      # Spot checks against the drawn map: Dor-Valon touches Persiennes,
      # Nooka, Zoggan, Doriennes and Urk; Ketzura only Vishapir.
      assert adj[6] == [1, 2, 5, 7, 9]
      assert adj[13] == [12]
      # the chain of southern sectors
      assert adj[14] == [5, 8, 15]
      assert adj[18] == [17]
    end

    test "adjacency is symmetric and never self-referential" do
      adj = adjacency(@citadel)

      for {id, neighbours} <- adj, other <- neighbours do
        refute other == id
        assert id in adj[other], "#{id} lists #{other} but not the reverse"
      end
    end
  end

  describe "geometry" do
    # A concave "C" whose notch encloses a detached square. Every vertex of
    # the square lies inside the C's convex hull, which is precisely the
    # configuration SAT mis-reports as a collision.
    @c_shape [[0, 0], [10, 0], [10, 3], [3, 3], [3, 7], [10, 7], [10, 10], [0, 10], [0, 0]]
    @square_in_notch [[5, 4], [8, 4], [8, 6], [5, 6], [5, 4]]
    @square_touching_notch [[3, 4], [8, 4], [8, 6], [3, 6], [3, 4]]

    test "a polygon floating inside a concave neighbour's hull is not adjacent" do
      adj = adjacency([{1, "c", @c_shape}, {2, "island", @square_in_notch}])
      assert adj == %{1 => [], 2 => []}
    end

    test "sharing a boundary segment is adjacent, even with intermediate vertices" do
      adj = adjacency([{1, "c", @c_shape}, {2, "plug", @square_touching_notch}])
      # the plug's left edge runs along the C's inner wall between (3,4)
      # and (3,6) — no vertex of the C is on it, so this relies on the
      # edge-overlap check, not on vertex equality.
      assert adj == %{1 => [2], 2 => [1]}
    end

    test "touching at a single corner counts as adjacent (pre-2026-09 behaviour preserved)" do
      adj = adjacency([{1, "a", [[0, 0], [2, 0], [2, 2], [0, 2]]}, {2, "b", [[2, 2], [4, 2], [4, 4], [2, 4]]}])
      assert adj == %{1 => [2], 2 => [1]}
    end

    test "separated polygons are not adjacent" do
      adj = adjacency([{1, "a", [[0, 0], [2, 0], [2, 2], [0, 2]]}, {2, "b", [[3, 3], [5, 3], [5, 5], [3, 5]]}])
      assert adj == %{1 => [], 2 => []}
    end

    test "integer and float coordinates for the same point are equal" do
      adj =
        adjacency([
          {1, "a", [[0, 0], [2, 0], [2, 2], [0, 2]]},
          {2, "b", [[2.0, 0.0], [4.0, 0.0], [4.0, 2.0], [2.0, 2.0]]}
        ])

      assert adj == %{1 => [2], 2 => [1]}
    end

    test "coordinates within float noise of each other are equal" do
      adj =
        adjacency([
          {1, "a", [[0, 0], [2, 0], [2, 2], [0, 2]]},
          {2, "b", [[2.0000000001, 0], [4, 0], [4, 2], [2.0000000001, 2]]}
        ])

      assert adj == %{1 => [2], 2 => [1]}
    end

    test "an open ring and a closed ring describe the same polygon" do
      open = [[0, 0], [2, 0], [2, 2], [0, 2]]
      closed = open ++ [[0, 0]]
      other = [[2, 0], [4, 0], [4, 2], [2, 2]]

      assert adjacency([{1, "a", open}, {2, "b", other}]) == adjacency([{1, "a", closed}, {2, "b", other}])
    end
  end
end
