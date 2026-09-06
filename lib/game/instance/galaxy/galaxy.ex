defmodule Instance.Galaxy.Galaxy do
  use TypedStruct

  alias Instance.Galaxy
  alias Instance.Galaxy.SpatialGraph

  @next_sectors_update_unit_days 20

  def jason(), do: [except: [:behavior_tree, :next_sectors_update]]

  typedstruct enforce: true do
    field(:size, integer())
    field(:stellar_systems, [])
    field(:edges, [])
    field(:sectors, [])
    field(:blackholes, [])
    field(:players, %{})
    field(:tutorial_id, integer() | nil)
    field(:behavior_tree, BehaviorTree.Node.t())
    field(:next_sectors_update, %Core.DynamicValue{})
  end

  def new(game_data, players, stellar_systems, tutorial_id) do
    # TODO - revert position (?) to make the map looks like the one on the editor

    # convert map stellar system into galaxy stellar system
    systems =
      Util.PhaseTimer.timed("galaxy_new/convert_systems", fn ->
        Enum.map(stellar_systems, fn %Instance.StellarSystem.StellarSystem{} = system ->
          Galaxy.StellarSystem.convert(system)
        end)
      end)

    # convert map sectors into galaxy blackholes
    blackholes = Enum.map(game_data["blackholes"], fn blackhole -> Galaxy.Blackhole.new(blackhole) end)

    # use systems to generate connecting edges
    edges =
      Util.PhaseTimer.timed("galaxy_new/generate_edges", fn ->
        SpatialGraph.generate_edges(systems, blackholes)
      end)

    # convert map sectors into galaxy sectors
    sectors =
      Util.PhaseTimer.timed("galaxy_new/sectors", fn ->
        Enum.map(game_data["sectors"], fn sector -> Galaxy.Sector.new(sector, systems) end)
        |> put_adjacent_sectors()
      end)

    next_update = Core.DynamicValue.new(0, :misc, Core.ValuePart.new(:default, 1))

    galaxy = %Galaxy.Galaxy{
      size: game_data["size"],
      stellar_systems: systems,
      edges: edges,
      sectors: sectors,
      blackholes: blackholes,
      players: %{},
      tutorial_id: tutorial_id,
      behavior_tree: load_behavior_tree(),
      next_sectors_update: next_update
    }

    # add players
    Enum.reduce(players, galaxy, fn p, acc -> add_player(acc, p) end)
  end

  def compute_next_tick_interval(_state) do
    9
  end

  # Action handling

  @doc """
  Returns the two systems in the right order and the distance
  %{
    # from
    s1: %Instance.Galaxy.StellarSystem{},
    # to
    s2: %Instance.Galaxy.StellarSystem{},
    # distance
    weight: 9.248702611718022
  }
  `StellarSystem`s have a position: %Position{}
  """
  def check_jump(state, from_system_id, to_system_id) do
    edge =
      Enum.find(state.edges, fn e ->
        (e.s1.id == from_system_id and e.s2.id == to_system_id) or
          (e.s2.id == from_system_id and e.s1.id == to_system_id)
      end)

    if edge != nil do
      if edge.s1.id == from_system_id do
        edge
      else
        %{s1: edge.s2, s2: edge.s1, weight: edge.weight}
      end
    else
      :invalid_jump
    end
  end

  def check_system_takeability(state, system_id, faction_key) do
    system = Enum.find(state.stellar_systems, fn system -> system.id == system_id end)

    if system do
      sector = Enum.find(state.sectors, fn s -> s.id == system.sector_id end)
      adjacent_own_sectors = Enum.filter(state.sectors, fn s -> s.id in sector.adjacent and s.owner == faction_key end)

      cond do
        sector.owner == faction_key -> {:ok, :takeable}
        length(adjacent_own_sectors) > 0 -> {:ok, :takeable}
        true -> {:ok, :untakeable}
      end
    else
      {:error, :system_not_found}
    end
  end

  def get_closest_system(state, system_id) when is_integer(system_id) do
    edge =
      state.edges
      |> Enum.filter(fn e -> e.s1.id == system_id or e.s2.id == system_id end)
      |> Enum.min_by(fn e -> e.weight end)

    if edge.s1.id == system_id,
      do: edge.s2.id,
      else: edge.s1.id
  end

  def get_initial_system(state, faction_key, instance_id) do
    sectors =
      state.sectors
      |> Enum.filter(fn sector -> sector.owner == faction_key end)
      |> Enum.map(fn sector -> sector.id end)

    systems =
      state.stellar_systems
      |> Enum.filter(fn system -> system.status == :uninhabited and system.sector_id in sectors end)

    systems =
      unless Enum.any?(systems) do
        Enum.filter(state.stellar_systems, fn system ->
          system.status == :inhabited_neutral and system.sector_id in sectors
        end)
      else
        systems
      end

    Game.call(instance_id, :rand, :master, {:random, systems})
  end

  def get_system(state, system_id) do
    system = Enum.find(state.stellar_systems, fn system -> system.id == system_id end)

    if system == nil,
      do: {:error, :system_already_claimed},
      else: {:ok, system}
  end

  def add_player(state, player) do
    players =
      Map.put(state.players, player.id, %{
        id: player.id,
        faction: player.faction,
        name: player.name,
        avatar: player.avatar,
        is_active: player.is_active
      })

    %{state | players: players}
  end

  def update_stellar_system(state, new_system) do
    stellar_systems =
      Enum.map(state.stellar_systems, fn system ->
        if new_system.id == system.id,
          do: new_system,
          else: system
      end)

    {status, sector, old_sector} =
      state.sectors
      |> Enum.find(fn s -> s.id == new_system.sector_id end)
      |> Galaxy.Sector.update_owner(stellar_systems)

    sectors = Enum.map(state.sectors, fn s -> if s.id == sector.id, do: sector, else: s end)
    {%{state | stellar_systems: stellar_systems, sectors: sectors}, {status, sector, old_sector}}
  end

  def is_tutorial(state) do
    not is_nil(state.tutorial_id)
  end

  def get_system_id_with_position(systems, position) do
    system = Enum.find(systems, fn s -> s.position == position end)
    system.id
  end

  defp load_behavior_tree do
    path = Path.join(:code.priv_dir(:rc), Keyword.get(Application.get_env(:rc, RC.SystemAI), :path))
    name = Application.get_env(:rc, RC.SystemAI) |> Keyword.get(:name)

    Instance.SystemAI.Parser.parse!(path, name)
  end

  # Sector adjacency — the input to `check_system_takeability/3`.
  #
  # Two sectors are adjacent when their boundary polygons touch: they share
  # a vertex, a vertex of one lies on an edge of the other (T-junctions,
  # collinear edges subdivided differently) or their edges cross (sloppy
  # hand-drawn overlaps). Coordinates are compared with a tolerance so the
  # integer and float renderings of the same map point agree.
  #
  # This replaced the `collision` package's Separating Axis test in 2026-09.
  # SAT is only valid for convex polygons and hand-drawn sectors are mostly
  # concave: a vertex of one sector sitting inside a neighbour's convex-hull
  # notch was reported as a collision although the shapes never touch. On
  # prod instance 121 the unowned central sector gained three phantom
  # neighbours that way, one of them faction-owned, which made the whole
  # centre colonizable from two sectors away.
  @adjacency_epsilon 1.0e-6

  @doc false
  def put_adjacent_sectors(sectors) do
    rings = Map.new(sectors, fn %Galaxy.Sector{id: id, points: points} -> {id, ring(points)} end)

    Enum.map(sectors, fn %Galaxy.Sector{id: id} = sector ->
      own = Map.fetch!(rings, id)
      adjacent = for {other_id, other} <- rings, other_id != id, polygons_touch?(own, other), do: other_id

      %{sector | adjacent: Enum.sort(adjacent)}
    end)
  end

  # Map polygons arrive as closed rings ([p1, ..., pn, p1]); collapse to the
  # distinct vertex list and pair consecutive vertices (plus the closing
  # pair) into edges.
  defp ring(points) do
    vertices =
      points
      |> Enum.map(fn [x, y] -> {x / 1, y / 1} end)
      |> Enum.uniq()

    edges =
      case vertices do
        [_, _ | _] -> Enum.zip(vertices, tl(vertices) ++ [hd(vertices)])
        _ -> []
      end

    %{vertices: vertices, edges: edges}
  end

  defp polygons_touch?(a, b) do
    Enum.any?(a.vertices, &on_boundary?(&1, b.edges)) or
      Enum.any?(b.vertices, &on_boundary?(&1, a.edges)) or
      Enum.any?(a.edges, fn edge_a -> Enum.any?(b.edges, &segments_cross?(edge_a, &1)) end)
  end

  defp on_boundary?(point, edges), do: Enum.any?(edges, &point_on_segment?(point, &1))

  # Point within @adjacency_epsilon of the segment [a, b], endpoints included.
  defp point_on_segment?({px, py}, {{ax, ay}, {bx, by}}) do
    dx = bx - ax
    dy = by - ay
    len_sq = dx * dx + dy * dy

    {cx, cy} =
      if len_sq == 0.0 do
        {ax, ay}
      else
        t = ((px - ax) * dx + (py - ay) * dy) / len_sq
        t = min(max(t, 0.0), 1.0)
        {ax + t * dx, ay + t * dy}
      end

    (px - cx) * (px - cx) + (py - cy) * (py - cy) <= @adjacency_epsilon * @adjacency_epsilon
  end

  # Proper crossing (interiors intersect). Touching configurations are
  # already caught by point_on_segment?/2, so strict inequalities suffice.
  defp segments_cross?({p1, p2}, {q1, q2}) do
    d1 = cross(q1, q2, p1)
    d2 = cross(q1, q2, p2)
    d3 = cross(p1, p2, q1)
    d4 = cross(p1, p2, q2)

    ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
  end

  defp cross({ox, oy}, {ax, ay}, {bx, by}), do: (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)

  # Tick handling

  def next_tick(state, elapsed_time) do
    {MapSet.new(), state}
    |> update_next_sectors_update(elapsed_time)
  end

  # Core functions

  defp update_next_sectors_update({change, state}, elapsed_time) do
    next_update = Core.DynamicValue.next_tick(state.next_sectors_update, elapsed_time)

    {next_update, change} =
      if next_update.value >= @next_sectors_update_unit_days do
        next_update = Core.DynamicValue.change_value(next_update, 0.0)
        change = MapSet.put(change, :sectors_update)
        {next_update, change}
      else
        {next_update, change}
      end

    {change, %{state | next_sectors_update: next_update}}
  end

  # Helper functions

  # ...
end
