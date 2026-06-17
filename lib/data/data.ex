defmodule Data.Data do
  # persistent_term key holding the cached :sim dataset (see get(:sim, _)).
  @sim_pt_key {__MODULE__, :sim_game_data}

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
  """
  def install_sim(metadata \\ [speed: :fast, mode: :prod]) do
    game_data = [metadata: metadata, data: Data.Querier.fetch_all(metadata)]
    :persistent_term.put(@sim_pt_key, game_data)
    :ok
  end

  def sim_installed?, do: :persistent_term.get(@sim_pt_key, nil) != nil

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
