defmodule Wave.Blueprints do
  @moduledoc """
  The fleets the Rebellion copies: designs players fielded in Legacy matches,
  each tagged with what the fleet was seen doing.

  `priv/data/wave/blueprints.json` holds the pool. A design is a tile layout of
  hulls (`fighter_4`, `frigate_2`, ...) without stack sizes: players build the
  largest stack their merge patents allow, and so does the Rebellion, so one
  design serves every stage of a match that has unlocked its hulls
  (`resolve/3`).

  The evidence under each design counts sightings by what the fleet did:

    * `defense`  — fought as the defender in its own faction's system, or stood
      in one for days;
    * `raid`     — pillaged a player's system or a dominion;
    * `siege`    — bombarded one;
    * `conquest` — invaded one;
    * `screen`   — fought at a system a teammate was bombarding or invading;
    * `hunt`     — attacked a fleet somewhere else.

  The Rebellion builds five roles from those (`roles/0`); screens also draw on
  the hunters at half weight, because both exist to kill fleets.

  Everything here is pure except `pool/0`, which reads the file once per BEAM.
  """

  @path "data/wave/blueprints.json"

  @roles [:defense, :raid, :siege, :conquest, :screen]

  # Which sightings speak for a role, and how loudly.
  @evidence %{
    defense: %{"defense" => 1.0},
    raid: %{"raid" => 1.0},
    siege: %{"siege" => 1.0},
    conquest: %{"conquest" => 1.0},
    screen: %{"screen" => 1.0, "hunt" => 0.5}
  }

  @stances [:flee, :fight_back, :defend, :attack_enemies, :attack_everyone]

  @doc "The roles a fleet is built for."
  def roles, do: @roles

  @doc "The pool, parsed once per BEAM and served from `:persistent_term`."
  def pool do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        pool = load()
        :persistent_term.put(__MODULE__, pool)
        pool

      pool ->
        pool
    end
  end

  defp load do
    path = Path.join(:code.priv_dir(:rc), @path)

    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      parse(json)
    else
      _ -> []
    end
  end

  @doc """
  The decoded file as a list of designs:
  `%{id:, slots: [{tile, hull}], evidence: %{kind => count}, players:, stance:}`.
  A design naming a hull the code does not know is dropped.
  """
  def parse(%{"blueprints" => blueprints}) when is_list(blueprints) do
    blueprints
    |> Enum.map(&design/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(_json), do: []

  defp design(%{"id" => id, "slots" => slots} = raw) when is_list(slots) do
    parsed =
      Enum.map(slots, fn
        [tile, hull] when is_integer(tile) and is_binary(hull) -> {tile, hull_atom(hull)}
        _ -> {nil, nil}
      end)

    if parsed == [] or Enum.any?(parsed, fn {tile, hull} -> is_nil(tile) or is_nil(hull) end) do
      nil
    else
      %{
        id: id,
        slots: Enum.sort(parsed),
        evidence: Map.get(raw, "evidence", %{}),
        players: Map.get(raw, "players", 1),
        stance: stance(Map.get(raw, "stance"))
      }
    end
  end

  defp design(_raw), do: nil

  # The file is ours, but the names still become atoms: only catalog-shaped
  # hull names pass.
  defp hull_atom(name) do
    if Regex.match?(~r/^(fighter|corvette|frigate|capital|transport)_\d$/, name), do: String.to_atom(name), else: nil
  end

  defp stance(name), do: Enum.find(@stances, :defend, &(Atom.to_string(&1) == name))

  @doc """
  How strongly the sightings recommend `design` for `role`: its sightings in
  that role, weighted, plus one for every distinct player who fielded it. Zero
  means nobody was seen using it that way.
  """
  def weight(design, role) do
    seen =
      @evidence
      |> Map.get(role, %{})
      |> Enum.reduce(0.0, fn {kind, factor}, acc -> acc + factor * Map.get(design.evidence, kind, 0) end)

    if seen > 0, do: seen + Map.get(design, :players, 1), else: 0.0
  end

  @doc """
  The ship a hull is built as: the largest stack whose merge patents are all
  held, or `nil` when the hull's own patent is missing. `ships` is the catalog
  as `%{key => %Data.Game.Ship{}}`.
  """
  def stack(hull, patents, ships) do
    case Map.get(ships, hull) do
      nil -> nil
      ship -> if held?(ship, patents), do: climb(ship, patents, ships), else: nil
    end
  end

  defp climb(ship, patents, ships) do
    case ship.merge_to && Map.get(ships, ship.merge_to) do
      nil -> ship.key
      next -> if held?(next, patents), do: climb(next, patents, ships), else: ship.key
    end
  end

  defp held?(%{patent: nil}, _patents), do: true
  defp held?(%{patent: patent}, patents), do: patent in patents

  @doc """
  The hulls the patents unlock: every base hull (no stack) whose own patent is
  held, sorted.
  """
  def hulls(ships, patents) do
    stacked = for {_key, ship} <- ships, ship.merge_to != nil, into: MapSet.new(), do: ship.merge_to

    for({key, ship} <- ships, not MapSet.member?(stacked, key), held?(ship, patents), do: key)
    |> Enum.sort()
  end

  @doc """
  A design as the ships to build today: `{:ok, [{tile, ship_key}]}`, or
  `:locked` while a hull's patent is missing.
  """
  def resolve(design, patents, ships) do
    built = Enum.map(design.slots, fn {tile, hull} -> {tile, stack(hull, patents, ships)} end)

    if Enum.any?(built, fn {_tile, key} -> is_nil(key) end), do: :locked, else: {:ok, built}
  end

  @doc "Production the resolved ships cost a player, summed."
  def production(slots, ships) do
    slots |> Enum.map(fn {_tile, key} -> Map.fetch!(ships, key).production end) |> Enum.sum()
  end

  @doc """
  The designs seen in `role` that the patents allow, each resolved to today's
  ships: `[%{design:, slots:, weight:, production:}]`, costliest first.
  `allow` filters on the resolved slots (the Warlord passes "some yard can
  build this"). `shape` reworks a design's hull layout before it is resolved
  (the Warlord passes its cap on capital ships), so cost and `allow` are read
  off what would really be built.
  """
  def eligible(pool, role, patents, ships, allow \\ fn _slots -> true end, shape \\ fn layout -> layout end) do
    for design <- pool,
        weight = weight(design, role),
        weight > 0,
        {:ok, slots} <- [resolve(%{slots: shape.(design.slots)}, patents, ships)],
        slots != [],
        allow.(slots) do
      %{design: design, slots: slots, weight: weight, production: production(slots, ships)}
    end
    |> Enum.sort_by(&{-&1.production, &1.design.id})
  end

  @doc """
  The designs a pick is drawn from: the costliest `:share` of the eligible
  ones (at least three). Options as in `pick/6`.
  """
  def draw_pool(pool, role, patents, ships, opts \\ []) do
    share = Keyword.get(opts, :share, 0.5)
    allow = Keyword.get(opts, :allow, fn _slots -> true end)
    shape = Keyword.get(opts, :shape, fn layout -> layout end)

    candidates = eligible(pool, role, patents, ships, allow, shape)
    Enum.take(candidates, max(ceil(length(candidates) * share), 3))
  end

  @doc "What the cheapest design still in the draw costs to build, or nil with nothing eligible."
  def draw_floor(pool, role, patents, ships, opts \\ []) do
    case draw_pool(pool, role, patents, ships, opts) do
      [] -> nil
      candidates -> candidates |> Enum.map(& &1.production) |> Enum.min()
    end
  end

  @doc """
  Pick a design for `role`. The eligible designs are ranked by what they cost
  to build today and only the costliest `share` of them (at least three) stay
  in the draw, so a Rebellion with frigates stops laying down scout swarms;
  among those, `roll` (0..1) draws by weight. `:none` when nothing is eligible.

  Options: `:share`, `:allow` and `:shape` (see `eligible/6`), and `:exclude`,
  design ids to leave out of the draw while it has others.
  """
  def pick(pool, role, patents, ships, roll, opts \\ []) when is_number(roll) do
    exclude = Keyword.get(opts, :exclude, [])

    case draw_pool(pool, role, patents, ships, opts) do
      [] ->
        :none

      candidates ->
        fresh = Enum.reject(candidates, &(&1.design.id in exclude))
        {:ok, draw(if(fresh == [], do: candidates, else: fresh), roll)}
    end
  end

  defp draw(candidates, roll) do
    total = candidates |> Enum.map(& &1.weight) |> Enum.sum()
    mark = min(max(roll, 0.0), 0.999999) * total

    candidates
    |> Enum.reduce_while(0.0, fn candidate, acc ->
      acc = acc + candidate.weight
      if mark < acc, do: {:halt, candidate}, else: {:cont, acc}
    end)
    |> case do
      %{} = candidate -> candidate
      _ -> List.last(candidates)
    end
  end
end
