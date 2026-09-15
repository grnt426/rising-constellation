defmodule Wave.Geometry do
  @moduledoc """
  One read of the galaxy, turned into everything the Warlord's targeting needs
  for a pass: lane adjacency, which sectors the Rebellion owns and can expand
  into, how each sector is classified, how far each sector is from changing
  hands, and the candidate systems for colonization and dominion capture.

  Built once per Warlord pass and shared by every agent decision in that pass,
  so targeting never rebuilds the lane graph or rescans the galaxy per agent.
  Pure: a function of the galaxy struct and a faction key.

  ## Sector ownership

  Mirrors `Instance.Galaxy.Sector.update_owner/2`. Inhabited systems vote for
  their faction, and unowned inhabited systems (neutrals) vote as `nil`. A
  challenger takes a sector only with strictly more votes than the current
  owner. On a faction start sector that has never changed hands (`starter?`),
  neutral votes are ignored.
  """

  alias Wave.Nav

  defstruct [
    :faction,
    :adjacency,
    :systems,
    :owned,
    :takeable,
    :classes,
    :deficits
  ]

  @type t :: %__MODULE__{}

  @doc "Build the per-pass geometry for `faction`."
  def build(galaxy, faction) do
    sectors = galaxy.sectors
    by_sector = Enum.group_by(galaxy.stellar_systems, & &1.sector_id)

    owned = sectors |> Enum.filter(&(&1.owner == faction)) |> MapSet.new(& &1.id)

    takeable =
      sectors
      |> Enum.filter(fn s -> MapSet.member?(owned, s.id) or Enum.any?(s.adjacent, &MapSet.member?(owned, &1)) end)
      |> MapSet.new(& &1.id)

    classes =
      Map.new(sectors, fn s ->
        class =
          cond do
            MapSet.member?(owned, s.id) and Enum.all?(s.adjacent, &MapSet.member?(owned, &1)) -> :internal
            MapSet.member?(owned, s.id) -> :border
            MapSet.member?(takeable, s.id) -> :frontier
            true -> :unreachable
          end

        {s.id, class}
      end)

    deficits = Map.new(sectors, fn s -> {s.id, deficit(s, Map.get(by_sector, s.id, []), faction)} end)

    %__MODULE__{
      faction: faction,
      adjacency: Nav.adjacency(galaxy),
      systems: galaxy.stellar_systems,
      owned: owned,
      takeable: takeable,
      classes: classes,
      deficits: deficits
    }
  end

  @doc """
  Inhabited systems `faction` still needs in a sector before it changes hands
  (0 when it already owns the sector).
  """
  def deficit(sector, systems, faction) do
    if sector.owner == faction do
      0
    else
      votes =
        systems
        |> Enum.filter(&(Map.get(&1, :class) != nil))
        |> Enum.frequencies_by(& &1.faction)

      ours = Map.get(votes, faction, 0)

      others =
        votes
        |> Map.delete(faction)
        |> then(fn v -> if Map.get(sector, :starter?, false), do: Map.delete(v, nil), else: v end)
        |> Map.values()
        |> Enum.max(fn -> 0 end)

      max(others - ours + 1, 0)
    end
  end

  @doc "Uninhabited systems in sectors the faction can colonize — the unclaimed neighbourhood."
  def colonisation_candidates(%__MODULE__{} = geo) do
    Enum.filter(geo.systems, &(&1.status == :uninhabited and MapSet.member?(geo.takeable, &1.sector_id)))
  end

  @doc """
  Systems a Siderian may try to turn into a Rebellion dominion: neutral systems
  and other factions' dominions, in sectors the Rebellion can reach.
  """
  def capture_candidates(%__MODULE__{} = geo) do
    Enum.filter(geo.systems, fn s ->
      s.status in [:inhabited_neutral, :inhabited_dominion] and s.faction != geo.faction and
        MapSet.member?(geo.takeable, s.sector_id)
    end)
  end

  @doc "Sector class of a system's sector: :frontier, :border, :internal or :unreachable."
  def class_of(%__MODULE__{} = geo, system), do: Map.get(geo.classes, system.sector_id, :unreachable)

  @doc """
  Pick a capture target. `roll` is a uniform float in [0, 1) that chooses the
  sector class by `weights` (frontier / border / internal, renormalized over the
  classes that actually have candidates). Within frontier sectors the sector
  closest to changing hands wins, then the nearest system; within border and
  internal sectors the nearest system wins. `distances` maps system id to hop
  count from the Siderian. Returns the system or nil.
  """
  def pick_capture(%__MODULE__{} = geo, candidates, distances, roll, weights \\ %{frontier: 80, border: 15, internal: 5}) do
    reachable = Enum.filter(candidates, &Map.has_key?(distances, &1.id))
    by_class = Enum.group_by(reachable, &class_of(geo, &1))

    buckets =
      [:frontier, :border, :internal]
      |> Enum.filter(&(Map.get(by_class, &1, []) != [] and Map.get(weights, &1, 0) > 0))

    case buckets do
      [] ->
        nil

      _ ->
        class = weighted_pick(buckets, weights, roll)

        by_class
        |> Map.fetch!(class)
        |> Enum.min_by(fn s ->
          hops = Map.fetch!(distances, s.id)
          if class == :frontier, do: {Map.get(geo.deficits, s.sector_id, 0), hops, s.id}, else: {hops, s.id}
        end)
    end
  end

  @doc "The nearest reachable candidate by hops, ties by id, or nil."
  def nearest(candidates, distances) do
    candidates
    |> Enum.filter(&Map.has_key?(distances, &1.id))
    |> Enum.min_by(&{Map.fetch!(distances, &1.id), &1.id}, fn -> nil end)
  end

  defp weighted_pick(buckets, weights, roll) do
    total = buckets |> Enum.map(&Map.fetch!(weights, &1)) |> Enum.sum()
    target = roll * total

    Enum.reduce_while(buckets, 0, fn bucket, acc ->
      acc = acc + Map.fetch!(weights, bucket)
      if target < acc, do: {:halt, bucket}, else: {:cont, acc}
    end)
    |> case do
      bucket when is_atom(bucket) -> bucket
      _ -> List.last(buckets)
    end
  end
end
