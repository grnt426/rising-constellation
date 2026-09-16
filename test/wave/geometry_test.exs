defmodule Wave.GeometryTest do
  use ExUnit.Case, async: true

  alias Wave.{Geometry, Nav}

  # Sectors (adjacency in brackets):
  #   1 rebellion [2]      the rebel start, touching an unowned sector
  #   2 unowned   [1, 3]   frontier: 3 neutrals, 2 open — colonizing can't take it
  #   3 unowned   [2]      unreachable until 2 falls
  #   4 rebellion [5]      internal: every neighbour is rebel-owned
  #   5 rebellion [4]
  #
  # Lanes: 10—11—20—21—22—23—24—30 and 40—50
  defp galaxy do
    %{
      sectors: [
        %{id: 1, owner: :rebellion, adjacent: [2], starter?: true},
        %{id: 2, owner: nil, adjacent: [1, 3], starter?: false},
        %{id: 3, owner: nil, adjacent: [2], starter?: false},
        %{id: 4, owner: :rebellion, adjacent: [5], starter?: false},
        %{id: 5, owner: :rebellion, adjacent: [4], starter?: false}
      ],
      stellar_systems: [
        sys(10, 1, :inhabited_player, :rebellion),
        sys(11, 1, :inhabited_neutral, nil),
        sys(20, 2, :inhabited_neutral, nil),
        sys(21, 2, :inhabited_neutral, nil),
        sys(22, 2, :inhabited_neutral, nil),
        sys(23, 2, :uninhabited, nil),
        sys(24, 2, :uninhabited, nil),
        sys(30, 3, :uninhabited, nil),
        sys(40, 4, :inhabited_neutral, nil),
        sys(50, 5, :inhabited_player, :rebellion)
      ],
      edges:
        Enum.map([{10, 11}, {11, 20}, {20, 21}, {21, 22}, {22, 23}, {23, 24}, {24, 30}, {40, 50}], fn {a, b} ->
          %{s1: %{id: a}, s2: %{id: b}}
        end)
    }
  end

  defp sys(id, sector, status, faction) do
    class = if status == :uninhabited, do: nil, else: :minor
    %{id: id, sector_id: sector, status: status, faction: faction, class: class}
  end

  setup do
    {:ok, geo: Geometry.build(galaxy(), :rebellion)}
  end

  test "classifies sectors from the Rebellion's point of view", %{geo: geo} do
    assert geo.classes == %{1 => :border, 2 => :frontier, 3 => :unreachable, 4 => :internal, 5 => :internal}
    assert geo.takeable == MapSet.new([1, 2, 4, 5])
  end

  test "deficits follow the engine's ownership vote", %{geo: geo} do
    # 3 neutral votes against 0: four more systems needed
    assert geo.deficits[2] == 4
    assert geo.deficits[1] == 0
    # nobody inhabits sector 3
    assert geo.deficits[3] == 1
  end

  test "a starter sector ignores neutral votes" do
    sector = %{id: 9, owner: :tetrarchy, starter?: true}

    systems = [
      sys(1, 9, :inhabited_player, :tetrarchy),
      sys(2, 9, :inhabited_neutral, nil),
      sys(3, 9, :inhabited_neutral, nil)
    ]

    assert Geometry.deficit(sector, systems, :rebellion) == 2
  end

  test "leads use the same vote, neutrals ignored on an untouched start sector", %{geo: geo} do
    assert geo.leads[1] == 1
    assert geo.leads[2] == -3
    assert geo.leads[4] == -1
    assert geo.leads[5] == 1
  end

  test "workable sectors: frontier only while open, owned only below the hold margin", %{geo: geo} do
    assert Geometry.workable_sectors(geo, 2, true) == MapSet.new([1, 2, 4, 5])
    assert Geometry.workable_sectors(geo, 2, false) == MapSet.new([1, 4, 5])
    assert Geometry.workable_sectors(geo, 1, true) == MapSet.new([2, 4])
  end

  test "candidates can be limited to the workable sectors", %{geo: geo} do
    workable = Geometry.workable_sectors(geo, 1, false)

    assert Geometry.colonisation_candidates(geo, workable) == []
    assert geo |> Geometry.capture_candidates(workable) |> Enum.map(& &1.id) == [40]
  end

  test "a sector needs systems until the faction leads it by the hold margin", %{geo: geo} do
    # frontier sector 2: 0 against 3 neutrals, so 5 more to lead by 2
    assert Geometry.sector_need(geo, 2, 2) == 5
    assert Geometry.sector_need(geo, 1, 2) == 1
    assert Geometry.sector_need(geo, 5, 1) == 0
  end

  test "work already on its way uses up a sector's need", %{geo: geo} do
    assert Geometry.workable_sectors(geo, 2, true, %{2 => 4}) == MapSet.new([1, 2, 4, 5])
    assert Geometry.workable_sectors(geo, 2, true, %{2 => 5, 4 => 3}) == MapSet.new([1, 5])
  end

  test "colonisation candidates are the open systems in reachable sectors", %{geo: geo} do
    assert geo |> Geometry.colonisation_candidates() |> Enum.map(& &1.id) |> Enum.sort() == [23, 24]
  end

  test "capture candidates are neutrals and foreign dominions in reachable sectors", %{geo: geo} do
    assert geo |> Geometry.capture_candidates() |> Enum.map(& &1.id) |> Enum.sort() == [11, 20, 21, 22, 40]
  end

  describe "pick_capture/5" do
    setup %{geo: geo} do
      distances = Nav.hop_distances(geo.adjacency, 10)
      {:ok, candidates: Geometry.capture_candidates(geo), distances: distances}
    end

    test "a low roll lands in the frontier, on its nearest system", %{geo: geo, candidates: c, distances: d} do
      assert %{id: 20} = Geometry.pick_capture(geo, c, d, 0.1)
    end

    test "the middle band lands in a border sector", %{geo: geo, candidates: c, distances: d} do
      assert %{id: 11} = Geometry.pick_capture(geo, c, d, 0.85)
    end

    test "an internal target the Siderian can't reach is skipped", %{geo: geo, candidates: c, distances: d} do
      # system 40 sits on a disconnected lane component, so the top of the
      # roll renormalizes onto the border bucket instead
      assert %{id: 11} = Geometry.pick_capture(geo, c, d, 0.99)
    end

    test "nothing to capture gives nil", %{geo: geo, distances: d} do
      assert Geometry.pick_capture(geo, [], d, 0.5) == nil
    end
  end
end
