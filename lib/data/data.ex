defmodule Data.Data do
  # persistent_term key holding the cached :sim dataset (see get(:sim, _)).
  @sim_pt_key {__MODULE__, :sim_game_data}
  # cached UNPATCHED base dataset, so stat-override sweeps (Sim.AutoBalance)
  # can re-patch the ships without rebuilding the whole dataset each candidate.
  @sim_base_key {__MODULE__, :sim_base_data}

  def insert(instance_id, metadata) do
    game_data = [metadata: metadata, data: Data.Querier.fetch_all(metadata)]
    Horde.Registry.put_meta(Game.Registry, name_tuple(instance_id), game_data)
  end

  def get(instance_id, key) when is_integer(instance_id) do
    {:ok, data} = Horde.Registry.meta(Game.Registry, name_tuple(instance_id))
    data |> Keyword.fetch!(key)
  end

  def get(:fast_prod, key), do: get_without_cache(key, speed: :fast, mode: :prod)

  # Sim instance: a cached, process-shared snapshot for the headless battle
  # simulator (Sim.Arena). Unlike :fast_prod — which rebuilds the entire
  # dataset on every Data.Querier call (fine for one controller request,
  # ruinous for the millions of lookups an optimization run does) — this is
  # built once by install_sim/1 and served from :persistent_term.
  def get(:sim, key) do
    case :persistent_term.get(@sim_pt_key, nil) do
      nil ->
        raise "sim game-data not installed; call Data.Data.install_sim/0 (or Sim.Setup.install/0) first"

      data ->
        Keyword.fetch!(data, key)
    end
  end

  @doc """
  Build the :sim dataset once and cache it in :persistent_term. Idempotent
  (call again to switch game speed). Combat stats are identical across
  speeds; only costs differ.

  `overrides` is a sim-only `%{base_ship_key => %{field => value}}` map for
  what-if balance testing WITHOUT touching the game's content files. Each
  override applies to a base ship and all its stack variants (e.g.
  `%{corvette_1: %{unit_raid_coef: 0.0}}` patches corvette_1/v2/v3).
  """
  def install_sim(metadata \\ [speed: :fast, mode: :prod], overrides \\ %{}) do
    data = Data.Querier.fetch_all(metadata)

    data =
      if map_size(overrides) > 0,
        do: Map.update!(data, Data.Game.Ship, fn ships -> patch_ships(ships, overrides) end),
        else: data

    :persistent_term.put(@sim_pt_key, metadata: metadata, data: data)
    :ok
  end

  defp patch_ships(ships, overrides) do
    Enum.map(ships, fn ship ->
      case override_changes(ship.key, overrides) do
        nil -> ship
        changes -> struct(ship, changes)
      end
    end)
  end

  defp override_changes(key, overrides) do
    ks = Atom.to_string(key)

    Enum.find_value(overrides, fn {base, changes} ->
      bs = Atom.to_string(base)
      if ks == bs or String.starts_with?(ks, bs <> "v"), do: changes, else: nil
    end)
  end

  def sim_installed?, do: :persistent_term.get(@sim_pt_key, nil) != nil

  @doc """
  Fast variant of install_sim/2 for stat-override sweeps: patches the ship list
  off a cached, unpatched base dataset (no full rebuild per call). Used by
  Sim.AutoBalance to evaluate hundreds of stat candidates quickly.
  """
  def install_sim_overrides(overrides, metadata \\ [speed: :fast, mode: :prod]) do
    base = sim_base(metadata)

    data =
      if map_size(overrides) > 0,
        do: Map.update!(base, Data.Game.Ship, fn ships -> patch_ships(ships, overrides) end),
        else: base

    :persistent_term.put(@sim_pt_key, metadata: metadata, data: data)
    :ok
  end

  defp sim_base(metadata) do
    key = {@sim_base_key, metadata}

    case :persistent_term.get(key, nil) do
      nil ->
        base = Data.Querier.fetch_all(metadata)
        :persistent_term.put(key, base)
        base

      base ->
        base
    end
  end

  defp get_without_cache(key, metadata) do
    [metadata: metadata, data: Data.Querier.fetch_all(metadata)]
    |> Keyword.fetch!(key)
  end

  def clear(instance_id) do
    Horde.Registry.unregister(Game.Registry, name_tuple(instance_id))
  end

  def export(instance_id) do
    {:ok, data} = Horde.Registry.meta(Game.Registry, name_tuple(instance_id))
    data
  end

  defp name_tuple(instance_id), do: {instance_id, :game_data}
end
