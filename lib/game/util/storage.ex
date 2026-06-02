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
  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError ->
      Logger.error("rejected snapshot: unsafe binary_to_term term")
      {:error, :unsafe_snapshot}
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
