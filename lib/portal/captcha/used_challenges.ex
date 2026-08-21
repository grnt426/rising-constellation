defmodule Portal.Captcha.UsedChallenges do
  @moduledoc """
  One-time-use ledger for solved captcha challenges.

  A plain ETS set owned by this GenServer: `claim/2` is an atomic
  `insert_new`, so exactly one caller wins each challenge and replays are
  refused until the entry is swept. Hammer was considered but its
  fixed-window buckets can admit a replay right after a bucket rollover;
  an explicit ledger has none of that ambiguity. Single-node like the
  rest of our rate limiting (see the Hammer note in mix.exs).
  """

  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Atomically claim `key`. true exactly once; false for every replay."
  def claim(key, ttl_s) do
    :ets.insert_new(@table, {key, System.monotonic_time(:second) + ttl_s})
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end
end
