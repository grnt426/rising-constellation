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
  """

  @default_mode :legacy

  @doc "The node-global default content-memory mode for new inserts."
  def memory_mode, do: Application.get_env(:rc, :data_memory_mode, @default_mode)

  @doc "Set the node-global default mode (affects subsequently-created/restored instances)."
  def set_memory_mode(mode) when mode in [:legacy, :shared] do
    Application.put_env(:rc, :data_memory_mode, mode)
  end

  def insert(instance_id, metadata), do: insert(instance_id, metadata, memory_mode())

  def insert(instance_id, metadata, :shared) do
    ensure_content(metadata)
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

  # Uncached path (battle-sim / :fast_prod) — intentionally rebuilt each call;
  # never touches the registry or persistent_term.
  def get(:fast_prod, key), do: get_without_cache(key, speed: :fast, mode: :prod)

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

  defp read_meta(instance_id) do
    {:ok, meta} = Horde.Registry.meta(Game.Registry, name_tuple(instance_id))
    meta
  end

  defp get_without_cache(key, metadata) do
    [metadata: metadata, data: Data.Querier.fetch_all(metadata)]
    |> Keyword.fetch!(key)
  end

  # ---- shared content cache -------------------------------------------------

  defp ensure_content(metadata) do
    key = content_key(metadata)

    case :persistent_term.get(key, :undefined) do
      :undefined -> :persistent_term.put(key, Data.Querier.fetch_all(metadata))
      _ -> :ok
    end
  end

  defp content(metadata), do: :persistent_term.get(content_key(metadata))

  # Content depends only on speed+mode; normalise the key to (speed, mode) to
  # maximise sharing across instances.
  defp content_key(metadata) do
    {__MODULE__, :content, Keyword.get(metadata, :speed), Keyword.get(metadata, :mode)}
  end

  defp name_tuple(instance_id), do: {instance_id, :game_data}
end
