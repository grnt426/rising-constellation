defmodule Util.Storage do
  require Logger

  alias ExAws.S3

  @default_directory "./priv/_storage/"
  @bucket "instance-snapshots"

  # Backend selection:
  #   - Configured via :rc, :snapshot_backend (set in config/runtime.exs from
  #     RC_SNAPSHOT_BACKEND, default :local).
  #   - If unset, fall back to historical behavior: prod = :s3, else = :local.
  # This keeps existing deployments that haven't opted in working, while
  # letting single-node deploys without S3 creds use the local-disk path.
  defp backend do
    case Application.get_env(:rc, :snapshot_backend) do
      nil ->
        if Application.get_env(:rc, :environment) == :prod, do: :s3, else: :local

      configured ->
        configured
    end
  end

  defp directory do
    Application.get_env(:rc, :snapshot_dir, @default_directory)
  end

  def store(data, filename) do
    case backend() do
      :s3 -> store_s3(data, filename)
      :local -> store_local(data, filename)
    end
  end

  def load(filename) do
    case backend() do
      :s3 -> load_s3(filename)
      :local -> load_local(filename)
    end
  end

  def delete(filename) do
    case backend() do
      :s3 -> delete_s3(filename)
      :local -> delete_local(filename)
    end
  end

  defp store_local(data, filename) do
    dir = directory()
    path = Path.join([dir, filename])
    binary = :erlang.term_to_binary(data)

    File.mkdir_p!(dir)

    case File.write(path, binary) do
      :ok ->
        stat = File.stat!(path)
        {:ok, stat.size}

      error ->
        error
    end
  end

  defp store_s3(data, filename) do
    path = Path.join(["snapshots", filename])
    binary = :erlang.term_to_binary(data)

    case S3.put_object(@bucket, path, binary) |> ExAws.request() do
      {:ok, _} ->
        {:ok, :erlang.byte_size(binary)}

      error ->
        Logger.error(inspect(error))
        error
    end
  end

  defp load_local(filename) do
    path = Path.join([directory(), filename])

    case File.read(path) do
      {:ok, binary} -> safe_decode(binary)
      error -> error
    end
  end

  defp load_s3(filename) do
    path = Path.join(["snapshots", filename])

    case S3.get_object(@bucket, path) |> ExAws.request() do
      {:ok, %{body: binary}} ->
        safe_decode(binary)

      error ->
        Logger.error(inspect(error))
        error
    end
  end

  # Stage 6 Cluster E (M7) fix.
  #
  # Pass `:safe` to `binary_to_term/2` so the decoder rejects new atoms
  # (atom-table exhaustion DoS), funs, refs, and PIDs. The trade-off is
  # that snapshots must round-trip through atoms that already exist in
  # the runtime — which legitimate game agent snapshots do, since they
  # only contain Instance.* / Spatial.* module names already loaded.
  #
  # Threat boundary closed: an attacker with write access to the
  # snapshot storage (local dir in dev, S3 bucket in prod) can no
  # longer use a crafted blob to fill the atom table or smuggle in
  # term forms that the BEAM would otherwise interpret at decode time.
  # The downstream `Manager.init_from_snapshot` then enforces a module
  # allow-list for the Erlang term it received.
  @doc """
  Safe-decode a snapshot binary. Public seam so the fresh-BEAM
  regression test (test/game/util/storage_snapshot_test.exs) can
  exercise exactly the decode path `load/1` uses.
  """
  def decode_binary(binary), do: safe_decode(binary)

  defp safe_decode(binary) do
    ensure_atom_universe()
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError ->
      Logger.error("rejected snapshot: unsafe binary_to_term term; unknown atoms: #{inspect(unknown_atoms(binary))}")
      {:error, :unsafe_snapshot}
  end

  @doc """
  Names of atoms encoded in `binary` that this VM has never created — why a
  safe decode refuses a snapshot (usually a name built at runtime, e.g.
  `:"prefix_\#{key}"`, stored in agent state). Scans the external term
  format's atom tags without decoding, so it creates no atom. Best effort:
  a byte that merely looks like an atom tag may add a junk name.
  """
  def unknown_atoms(binary, limit \\ 20) do
    binary
    |> atom_names([])
    |> Enum.uniq()
    |> Enum.filter(&(String.valid?(&1) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.?!@-]{2,}$/, &1)))
    |> Enum.reject(&existing_atom?/1)
    |> Enum.take(limit)
  end

  # SMALL_ATOM_UTF8_EXT (119), ATOM_UTF8_EXT (118), ATOM_EXT (100), SMALL_ATOM_EXT (115)
  defp atom_names(<<119, len, name::binary-size(len), rest::binary>>, acc), do: atom_names(rest, [name | acc])

  defp atom_names(<<t, len::16, name::binary-size(len), rest::binary>>, acc) when t in [118, 100] and len < 256,
    do: atom_names(rest, [name | acc])

  defp atom_names(<<115, len, name::binary-size(len), rest::binary>>, acc), do: atom_names(rest, [name | acc])
  defp atom_names(<<_, rest::binary>>, acc), do: atom_names(rest, acc)
  defp atom_names(<<>>, acc), do: acc

  defp existing_atom?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  # `:safe` only accepts atoms that already exist in the runtime. Prod
  # releases preload every module (embedded mode) so every struct/field
  # atom exists before the deploy-boot restore runs. Dev loads modules
  # lazily, so a snapshot restored right after boot can reference atoms
  # from modules nothing has touched yet — concretely: Faction.Government
  # (a new :rc struct) and BehaviorTree.Node (a DEPENDENCY struct in the
  # neutral-system AI state, whose repeat_count/repeat_total field atoms
  # appear in no :rc module literal) both made whole snapshots decode as
  # "unsafe". Interning the modules of :rc plus its full dependency
  # closure admits exactly the atoms our code defines — no widening of
  # the threat boundary — and is self-sufficient: it loads the app specs
  # itself, so it works at deploy boot, in dev, and in a bare test peer.
  # One pass per VM; every later call is a persistent_term read.
  defp ensure_atom_universe do
    unless :persistent_term.get({__MODULE__, :atom_universe}, false) do
      intern_app_closure(:rc, MapSet.new())
      :persistent_term.put({__MODULE__, :atom_universe}, true)
    end

    :ok
  end

  defp intern_app_closure(app, visited) do
    if MapSet.member?(visited, app) do
      visited
    else
      visited = MapSet.put(visited, app)
      _ = :application.load(app)

      case :application.get_key(app, :modules) do
        {:ok, modules} -> Enum.each(modules, &Code.ensure_loaded/1)
        _ -> :ok
      end

      deps =
        case :application.get_key(app, :applications) do
          {:ok, deps} -> deps
          _ -> []
        end

      included =
        case :application.get_key(app, :included_applications) do
          {:ok, included} -> included
          _ -> []
        end

      Enum.reduce(deps ++ included, visited, &intern_app_closure/2)
    end
  end

  defp delete_local(filename) do
    path = Path.join([directory(), filename])

    case File.rm(path) do
      :ok ->
        :ok

      error ->
        error
    end
  end

  defp delete_s3(filename) do
    path = Path.join(["snapshots", filename])

    case S3.delete_object(@bucket, path) |> ExAws.request() do
      {:ok, _} ->
        :ok

      error ->
        Logger.error(inspect(error))
        error
    end
  end
end
