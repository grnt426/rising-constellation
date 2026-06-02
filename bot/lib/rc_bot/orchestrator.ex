defmodule RcBot.Orchestrator do
  @moduledoc """
  Drives the bot fleet on a long-running schedule.

  For each bot in `RcBot.Roster`, the orchestrator owns a single state:
  whether the bot's session is currently running, and when its next
  session should start. When a session ends (process `:DOWN`), the
  orchestrator schedules the next one after an idle interval that's
  modulated by the schedule config.

  ## Schedule

  Configured under `:rc_bot, :schedule` (see `config/dev.exs` for
  defaults). Knobs:

    * `:launch_surge_seconds` — every bot's first session is scheduled
      to start within a uniform random offset in [0, this]. Compresses
      the initial wave so the operator can see meaningful load fast.

    * `:idle_seconds_min`/`:idle_seconds_max` — random idle between
      sessions outside peak hours.

    * `:peak_hours` — list of `{start_utc_hour, end_utc_hour}` ranges
      where idle is multiplied by `:peak_factor` (typically <1.0 so
      bots are more active during peaks).

    * `:peak_factor` — multiplier on idle during peak windows.

    * `:jitter_seconds` — per-wake random offset on top of the chosen
      idle, so bots don't all wake at the same instant.

  Sessions are spawned with the per-bot multi-burst defaults from
  `:rc_bot, :session_defaults`, which are merged into each bot's args.
  """

  use GenServer

  require Logger

  alias RcBot.{Fleet, Roster}

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return a snapshot of the orchestrator's state — useful for debugging
  and (later) for surfacing to the dashboard.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    roster = Roster.all() |> Enum.map(&normalize_entry/1)
    schedule = Application.get_env(:rc_bot, :schedule, default_schedule())

    state = %{
      roster: roster,
      schedule: schedule,
      bots: %{},
      session_defaults: Application.get_env(:rc_bot, :session_defaults, %{})
    }

    Logger.info("Orchestrator starting with #{length(roster)} bots in roster")

    # Initial wake: stagger every bot within the launch_surge window.
    surge_ms = schedule[:launch_surge_seconds] * 1000

    state =
      Enum.reduce(roster, state, fn entry, acc ->
        delay = :rand.uniform(max(surge_ms, 1))
        Logger.info("scheduling first session for #{entry.bot_id} in #{delay}ms")
        ref = Process.send_after(self(), {:wake, entry.bot_id}, delay)
        put_in(acc, [:bots, entry.bot_id], %{wake_ref: ref, session_pid: nil, monitor_ref: nil})
      end)

    {:ok, state}
  end

  @impl true
  def handle_info({:wake, bot_id}, state) do
    case Enum.find(state.roster, &(&1.bot_id == bot_id)) do
      nil ->
        Logger.warning("wake for unknown bot #{bot_id} — dropping")
        {:noreply, state}

      entry ->
        start_session(entry, state)
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case find_bot_by_pid(state, pid) do
      nil ->
        {:noreply, state}

      bot_id ->
        Logger.info("bot #{bot_id} session ended: #{inspect(reason)}")

        idle_ms = pick_idle(state.schedule)
        ref = Process.send_after(self(), {:wake, bot_id}, idle_ms)
        Logger.info("scheduling next session for #{bot_id} in #{div(idle_ms, 1000)}s")

        state =
          update_in(state, [:bots, bot_id], fn b ->
            %{b | wake_ref: ref, session_pid: nil, monitor_ref: nil}
          end)

        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    snapshot =
      Enum.map(state.roster, fn entry ->
        b = Map.get(state.bots, entry.bot_id, %{})

        %{
          bot_id: entry.bot_id,
          instance_id: entry.instance_id,
          running: not is_nil(b[:session_pid]),
          session_pid: b[:session_pid]
        }
      end)

    {:reply, %{schedule: state.schedule, bots: snapshot}, state}
  end

  # ── Internals ───────────────────────────────────────────────────────

  defp start_session(entry, state) do
    session_args =
      entry
      |> Map.merge(state.session_defaults)
      |> Map.to_list()

    case Fleet.start_bot(session_args) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)

        Logger.info("started session for #{entry.bot_id} pid=#{inspect(pid)}")

        state =
          update_in(state, [:bots, entry.bot_id], fn b ->
            %{b | wake_ref: nil, session_pid: pid, monitor_ref: monitor_ref}
          end)

        {:noreply, state}

      {:error, reason} ->
        Logger.error("failed to start session for #{entry.bot_id}: #{inspect(reason)}")
        # Retry after a short delay so a transient failure doesn't kill
        # the bot permanently.
        ref = Process.send_after(self(), {:wake, entry.bot_id}, 30_000)

        state =
          update_in(state, [:bots, entry.bot_id], fn b ->
            %{b | wake_ref: ref, session_pid: nil, monitor_ref: nil}
          end)

        {:noreply, state}
    end
  end

  defp find_bot_by_pid(state, pid) do
    Enum.find_value(state.bots, fn {bot_id, b} ->
      if b[:session_pid] == pid, do: bot_id
    end)
  end

  # Pick a random idle interval in ms, applying peak-window multiplier
  # and jitter.
  defp pick_idle(schedule) do
    base_ms =
      uniform_between(
        schedule[:idle_seconds_min] * 1000,
        schedule[:idle_seconds_max] * 1000
      )

    factor = if in_peak_window?(schedule), do: schedule[:peak_factor], else: 1.0
    jitter = :rand.uniform(schedule[:jitter_seconds] * 1000)

    round(base_ms * factor) + jitter
  end

  defp in_peak_window?(schedule) do
    hour = DateTime.utc_now().hour

    Enum.any?(schedule[:peak_hours] || [], fn {start_h, end_h} ->
      hour >= start_h and hour < end_h
    end)
  end

  defp uniform_between(min, max) when max <= min, do: min
  defp uniform_between(min, max), do: min + :rand.uniform(max - min)

  defp default_schedule do
    %{
      launch_surge_seconds: 30,
      idle_seconds_min: 60,
      idle_seconds_max: 300,
      peak_hours: [],
      peak_factor: 0.3,
      jitter_seconds: 15
    }
  end

  # Normalize a roster entry — whether it came from JSON over HTTP
  # (string keys) or directly from a test (atom keys / mixed) — into a
  # stable atom-keyed map ready to feed into Fleet.start_bot/1.
  defp normalize_entry(entry) do
    get = fn key -> Map.get(entry, key) || Map.get(entry, Atom.to_string(key)) end

    %{
      bot_id: to_string(get.(:bot_id)),
      instance_id: get.(:instance_id),
      faction_id: get.(:faction_id),
      profile_id: get.(:profile_id),
      jwt: get.(:jwt),
      policy: policy_module(get.(:policy)),
      bursts_total: get.(:bursts_total),
      inter_burst_ms_min: get.(:inter_burst_ms_min),
      inter_burst_ms_max: get.(:inter_burst_ms_max)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Convert "RcBot.Policy.Dumb" string into the module atom. Safe
  # against malformed input — falls back to Policy.Dumb if the named
  # module isn't available, since loading an arbitrary atom from
  # network-supplied data is a code-injection risk.
  defp policy_module(nil), do: RcBot.Policy.Dumb

  defp policy_module(name) when is_binary(name) do
    try do
      String.to_existing_atom("Elixir." <> name)
    rescue
      ArgumentError ->
        Logger.warning("unknown policy module '#{name}', falling back to RcBot.Policy.Dumb")
        RcBot.Policy.Dumb
    end
  end

  defp policy_module(mod) when is_atom(mod), do: mod
end
