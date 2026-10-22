defmodule Edict.Slots do
  @moduledoc """
  Concurrency limits for the Scenario Workshop's heavier endpoints.

  The per-account rate limits (`Portal.Plug.AccountRateLimit`) bound how
  many requests an account sends in a window, not how many it sends at
  once: 200 simulations fired together would all run together. A slot is
  held while a request works and given back when it finishes or when its
  process dies, whichever comes first (every holder is monitored), so a
  crashed or killed request can't leak one.

  `run/3` waits briefly for a slot, since an author's own requests overlap
  for a moment when they close and reopen things quickly, and returns
  `{:error, :busy}` if none frees up in time.
  """
  use GenServer

  @poll_ms 25

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Run `fun` holding one slot of every limit in `limits` (`[{key, max}]`).
  Returns `{:ok, fun's result}` or `{:error, :busy}`.
  """
  def run(limits, fun, wait_ms \\ default_wait()) when is_function(fun, 0) do
    case acquire(limits, wait_ms) do
      {:ok, ref} ->
        try do
          {:ok, fun.()}
        after
          GenServer.cast(__MODULE__, {:release, ref})
        end

      :busy ->
        {:error, :busy}
    end
  end

  @doc "How many slots of `key` are held right now."
  def held(key), do: GenServer.call(__MODULE__, {:held, key})

  defp default_wait, do: Application.get_env(:rc, __MODULE__, []) |> Keyword.get(:wait_ms, 3_000)

  defp acquire(limits, wait_ms) do
    case GenServer.call(__MODULE__, {:acquire, self(), limits}) do
      {:ok, ref} ->
        {:ok, ref}

      :busy when wait_ms > 0 ->
        Process.sleep(@poll_ms)
        acquire(limits, wait_ms - @poll_ms)

      :busy ->
        :busy
    end
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{counts: %{}, holders: %{}}}

  @impl true
  def handle_call({:acquire, pid, limits}, _from, state) do
    if Enum.all?(limits, fn {key, max} -> Map.get(state.counts, key, 0) < max end) do
      ref = Process.monitor(pid)
      keys = Enum.map(limits, &elem(&1, 0))
      counts = Enum.reduce(keys, state.counts, fn key, acc -> Map.update(acc, key, 1, &(&1 + 1)) end)
      {:reply, {:ok, ref}, %{state | counts: counts, holders: Map.put(state.holders, ref, keys)}}
    else
      {:reply, :busy, state}
    end
  end

  def handle_call({:held, key}, _from, state), do: {:reply, Map.get(state.counts, key, 0), state}

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, release(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: {:noreply, release(state, ref)}

  defp release(state, ref) do
    case Map.pop(state.holders, ref) do
      {nil, _} ->
        state

      {keys, holders} ->
        counts =
          Enum.reduce(keys, state.counts, fn key, acc ->
            case Map.get(acc, key, 0) do
              n when n <= 1 -> Map.delete(acc, key)
              n -> Map.put(acc, key, n - 1)
            end
          end)

        %{state | counts: counts, holders: holders}
    end
  end
end
