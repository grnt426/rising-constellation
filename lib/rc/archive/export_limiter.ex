defmodule RC.Archive.ExportLimiter do
  @moduledoc """
  Per-account limit on archive exports: at most one per minute and ten per
  rolling hour.

  A sliding log of export times per account rather than Hammer's fixed
  windows: fixed buckets would allow two exports a second apart across a
  minute boundary, or twenty around the top of the hour — the stated limit
  should be the real one. Exports are rare, so a single process holding the
  log is plenty; like Hammer's ETS backend the state is per node and resets
  on restart.
  """
  use GenServer

  @minute_ms 60_000
  @hour_ms 3_600_000
  @hourly_limit 10
  @sweep_ms 600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records an export for `account_id` if it is allowed.

  Returns `:ok`, or `{:error, retry_after_seconds}` without recording.
  `now_ms` is injectable for tests (monotonic milliseconds).
  """
  def check(account_id, now_ms \\ System.monotonic_time(:millisecond), server \\ __MODULE__) do
    GenServer.call(server, {:check, account_id, now_ms})
  end

  def limits, do: %{per_minute: 1, per_hour: @hourly_limit}

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check, account_id, now}, _from, log) do
    # Newest first, only the last hour is relevant.
    recent = log |> Map.get(account_id, []) |> Enum.filter(&(now - &1 < @hour_ms))

    reply =
      cond do
        recent != [] and now - hd(recent) < @minute_ms ->
          {:error, seconds(hd(recent) + @minute_ms - now)}

        length(recent) >= @hourly_limit ->
          {:error, seconds(List.last(recent) + @hour_ms - now)}

        true ->
          :ok
      end

    recent = if reply == :ok, do: [now | recent], else: recent
    {:reply, reply, Map.put(log, account_id, recent)}
  end

  @impl true
  def handle_info(:sweep, log) do
    now = System.monotonic_time(:millisecond)
    Process.send_after(self(), :sweep, @sweep_ms)

    {:noreply,
     log
     |> Enum.map(fn {id, times} -> {id, Enum.filter(times, &(now - &1 < @hour_ms))} end)
     |> Enum.reject(fn {_, times} -> times == [] end)
     |> Map.new()}
  end

  defp seconds(ms), do: max(1, ceil(ms / 1000))
end
