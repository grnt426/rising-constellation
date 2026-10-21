defmodule Edict.Sandbox do
  @moduledoc """
  The process backstop around every evaluation.

  The interpreter already bounds a script by fuel, call depth and value
  sizes. The sandbox makes sure that a mistake in those bounds, or in the
  interpreter itself, still can't hurt the game: each evaluation runs in a
  fresh, unlinked, low-priority process with a capped heap (the BEAM kills it
  the moment it grows past `Edict.Limits.max_heap_words/0`) and a wall-clock
  deadline. The caller gets `{:ok, result}` or an error tuple, never an exit.
  Nothing a script does can reach the caller's mailbox, links or state: the
  function runs on copies, and only its return value comes back.
  """

  alias Edict.Limits

  @doc """
  Run `fun` in a sandboxed process. Returns `{:ok, value}`,
  `{:error, :timeout}`, `{:error, :memory}` or `{:error, {:crash, message}}`.
  Options: `:timeout` (ms), `:heap_words`.
  """
  def run(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, Limits.timeout_ms())
    heap = Keyword.get(opts, :heap_words, Limits.max_heap_words())
    caller = self()
    ref = make_ref()

    # the limits are set as the process is born, before it runs a single step
    # include_shared_binaries: text over 64 bytes lives outside the heap
    # and would otherwise not count
    spawn_opts = [
      :monitor,
      {:priority, :low},
      {:max_heap_size, %{size: heap, kill: true, error_logger: false, include_shared_binaries: true}}
    ]

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              {:ok, fun.()}
            rescue
              e -> {:error, {:crash, Exception.message(e)}}
            catch
              kind, value -> {:error, {:crash, "#{kind}: #{inspect(value, limit: 5, printable_limit: 200)}"}}
            end

          send(caller, {ref, result})
        end,
        spawn_opts
      )

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, :memory}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:crash, inspect(reason, limit: 5)}}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

        # a result may have raced the kill
        receive do
          {^ref, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  @doc "A sandbox error, as a message an author can act on."
  def describe(:timeout), do: "the script took too long and was stopped"
  def describe(:memory), do: "the script used too much memory and was stopped"
  def describe({:crash, message}), do: "the script stopped unexpectedly: #{message}"
end
