defmodule Data.Data do
  @moduledoc """
  Per-instance game data access, with a switchable content-memory model.

  The per-instance **metadata** (speed/mode/seed/mutators) is small, varies per
  instance, and must survive Horde handoff — it always lives in the
  Horde.Registry meta keyed by `{instance_id, :game_data}`.

  The **content map** built by `Data.Querier.fetch_all/1` (~130KB: every
  building/ship/patent/doctrine/… for a speed+mode) is read on *every*
  `Data.Querier` lookup. How it is served is selected per-instance by a mode:

    * `:legacy` — the content map is stored in the per-instance registry meta,
      so each lookup copies the whole ~130KB term onto the caller's heap
      (`Horde.Registry.meta` returns a process-local copy). This is the
      original behaviour and the default — deploying this branch is a no-op
      until a mode flip.

    * `:shared` — only metadata goes in the registry; content is served from
      `:persistent_term` keyed by (speed, mode), where reads are zero-copy and
      the term is shared across every process on the node. There are only six
      speed/mode combos, each built once; we never overwrite a live entry (a
      `:persistent_term.put` triggers a global GC), so the hot path is pure
      shared reads. This eliminates the per-lookup heap copy that drove
      per-system-process heap bloat (see the memory-pressure investigation).

  The mode is chosen at `insert/2` time (new game / snapshot restore) from the
  node-global default `Application.get_env(:rc, :data_memory_mode)` (or passed
  explicitly to `insert/3`), and recorded in the instance's meta so `get/2` and
  `export/1` use the matching path. `set_memory_mode/1` flips the global at
  runtime; `switch_memory_mode/2` flips a *running* instance — processes pick up
  the new path on their next `Data.Querier` lookup, since every lookup reads the
  mode fresh from the meta.

  Cluster note: do not run mixed old/new code against a `:shared` instance — old
  `Data.Data` code expects a `:data` key in the meta that `:shared` omits. The
  `:legacy` default keeps a rolling deploy safe until you deliberately flip.

  The `:sim` accessors below are a separate concern: a process-shared, cached
  dataset for the headless battle simulator (Sim.Arena), served from its own
  persistent_term keys (not the per-(speed,mode) content cache above).
  """

  @default_mode :legacy

  # persistent_term key holding the cached :sim dataset (see get(:sim, _)).
  @sim_pt_key {__MODULE__, :sim_game_data}
  # cached UNPATCHED base dataset, so stat-override sweeps (Sim.AutoBalance)
  # can re-patch the ships without rebuilding the whole dataset each candidate.
  @sim_base_key {__MODULE__, :sim_base_data}

  # ---- content-memory mode (per-instance: :legacy | :shared) ----------------

  @doc "The node-global default content-memory mode for new inserts."
  def memory_mode, do: Application.get_env(:rc, :data_memory_mode, @default_mode)

  @doc "Set the node-global default mode (affects subsequently-created/restored instances)."
  def set_memory_mode(mode) when mode in [:legacy, :shared] do
    Application.put_env(:rc, :data_memory_mode, mode)
  end

  def insert(instance_id, metadata), do: insert(instance_id, metadata, memory_mode())

  def insert(instance_id, metadata, :shared) do
    # Warm the node-local content cache eagerly so the creating node doesn't
    # pay a rebuild on its first lookup. content/1 builds-and-caches if absent.
    _ = content(metadata)
    Horde.Registry.put_meta(Game.Registry, name_tuple(instance_id), metadata: metadata, mode: :shared)
  end

  def insert(instance_id, metadata, :legacy) do
    Horde.Registry.put_meta(
      Game.Registry,
      name_tuple(instance_id),
      metadata: metadata,
      mode: :legacy,
      data: Data.Querier.fetch_all(metadata)
    )
  end

  @doc """
  Switch a running instance's content-memory model. Re-stamps the meta with the
  new mode (dropping the heavy `:data` copy on `:legacy -> :shared`, which frees
  the registry copy; populating it on `:shared -> :legacy`). Live processes pick
  up the new path on their next lookup. Returns `:ok`.
  """
  def switch_memory_mode(instance_id, mode) when mode in [:legacy, :shared] do
    metadata = get(instance_id, :metadata)
    insert(instance_id, metadata, mode)
    :ok
  end

  # ---- reads ----------------------------------------------------------------

  # Uncached path (:fast_prod) — intentionally rebuilt each call; never touches
  # the registry or persistent_term.
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

  def get(instance_id, :data) when is_integer(instance_id) do
    meta = read_meta(instance_id)

    case Keyword.get(meta, :mode, :legacy) do
      :shared -> content(Keyword.fetch!(meta, :metadata))
      :legacy -> Keyword.fetch!(meta, :data)
    end
  end

  def get(instance_id, key) when is_integer(instance_id) do
    Keyword.fetch!(read_meta(instance_id), key)
  end

  def clear(instance_id) do
    Horde.Registry.unregister(Game.Registry, name_tuple(instance_id))
  end

  # Snapshot export keeps its `[metadata:, data:]` shape regardless of mode
  # (restore only reads `:metadata` back and rebuilds content via insert/2, so
  # the shape is preserved purely for backward compatibility with old snapshots).
  def export(instance_id) do
    meta = read_meta(instance_id)
    metadata = Keyword.fetch!(meta, :metadata)

    data =
      case Keyword.get(meta, :mode, :legacy) do
        :shared -> content(metadata)
        :legacy -> Keyword.fetch!(meta, :data)
      end

    [metadata: metadata, data: data]
  end

  # ---- :sim dataset (headless battle simulator) -----------------------------

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

  # ---- helpers --------------------------------------------------------------

  defp read_meta(instance_id) do
    {:ok, meta} = Horde.Registry.meta(Game.Registry, name_tuple(instance_id))
    meta
  end

  defp get_without_cache(key, metadata) do
    [metadata: metadata, data: Data.Querier.fetch_all(metadata)]
    |> Keyword.fetch!(key)
  end

  # ---- shared content cache (per-(speed,mode), :shared mode) ----------------

  # Node-local content for :shared mode, self-healing. The game content map is
  # a PURE function of (speed, mode), so any node can rebuild it from the
  # replicated per-instance metadata. This is what keeps :shared cluster-safe:
  # `:persistent_term` is node-local (unlike the :legacy content copy, which
  # rode the cluster-replicated Horde registry meta and was therefore present
  # on any node after a Horde handoff). `Data.Data.insert` only runs at
  # create/restore — NOT on `Instance.Supervisor.continue` (the failover path)
  # — so a node that inherits a :shared instance via handoff has the meta but
  # not the content; rebuilding-on-absence here closes that gap. Cost: one
  # `fetch_all` (a few ms) the first time a given (speed, mode) is seen on a
  # node, vs. CRDT-replicating a ~130KB blob per instance cluster-wide.
  defp content(metadata) do
    key = content_key(metadata)

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        built = Data.Querier.fetch_all(metadata)
        :persistent_term.put(key, built)
        built

      data ->
        data
    end
  end

  # Content depends only on speed+mode; normalise the key to (speed, mode) to
  # maximise sharing across instances.
  defp content_key(metadata) do
    {__MODULE__, :content, Keyword.get(metadata, :speed), Keyword.get(metadata, :mode)}
  end

  defp name_tuple(instance_id), do: {instance_id, :game_data}
end
