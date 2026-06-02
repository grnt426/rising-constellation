defmodule RcBot.Orchestrator do
  @moduledoc """
  Drives the bot fleet on a long-running schedule. This is the
  **driver-side** scheduler: it lives in the same OTP app as the bot
  Session processes and is controlled by whoever runs this harness.

  Two pause flags both have to be permissive for a session to spawn:

    * `locally_paused` — set/cleared by THIS driver's operator via
      `pause/0` and `resume/0` (driven from the harness LiveView at
      `http://localhost:5500/bots`).

    * `globally_permitted` (via `fleet_enabled?/0`) — polled from the
      rc server's `/api/harness/bot-control/state`. The rc admin can
      flip this from the supervisor dashboard as a fleet-wide kill
      switch. Fails closed on transport errors.

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

  # Sentinel file: present on the rc app's prod EC2 host
  # (/etc/rc/secret.json holds the secret blob rc-fetch-secrets reads).
  # If we see it, we're running on the same machine as the rc server —
  # double-eating CPU + RAM is exactly what we DON'T want for stress
  # testing. Refuse to spawn the orchestrator, but leave manual
  # `RcBot.Fleet.start_bot/1` probes available for live debugging.
  #
  # Override via `RC_BOT_FORCE_RUN=1` for the rare deliberate case
  # (e.g. emergency in-place stress test you've thought through).
  @prod_host_sentinel "/etc/rc/secret.json"

  def start_link(opts \\ []) do
    case host_guard() do
      :ok ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      {:refused, reason} ->
        Logger.error("""
        RcBot.Orchestrator refused to start: #{reason}

        This machine looks like the rc app's prod host (#{@prod_host_sentinel}
        is present). Running the bot fleet here would double-eat the same
        machine's CPU/RAM, defeating the stress test's purpose.

        If this is intentional, set RC_BOT_FORCE_RUN=1 and try again.
        """)

        :ignore
    end
  end

  defp host_guard do
    cond do
      System.get_env("RC_BOT_FORCE_RUN") == "1" ->
        :ok

      File.exists?(@prod_host_sentinel) ->
        {:refused, "host guard tripped — #{@prod_host_sentinel} present"}

      true ->
        :ok
    end
  end

  @doc """
  Return a snapshot of the orchestrator's state — useful for debugging
  and for surfacing to the driver dashboard.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Pause THIS driver. The orchestrator stops spawning new sessions; any
  in-flight sessions complete their burst loop naturally. Distinct from
  the prod-side global kill switch (which affects every driver). Both
  must be permissive for sessions to spawn.
  """
  def pause, do: GenServer.call(__MODULE__, :pause)

  @doc """
  Resume THIS driver. No effect if the prod-side global kill switch is
  set to DENY — sessions still won't spawn until the global is also OK.
  """
  def resume, do: GenServer.call(__MODULE__, :resume)

  @doc """
  Is this driver locally paused right now? Cheap getter for the UI.
  """
  def paused?, do: GenServer.call(__MODULE__, :paused?)

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    roster = Roster.all() |> Enum.map(&normalize_entry/1)
    schedule = Application.get_env(:rc_bot, :schedule, default_schedule())

    state = %{
      roster: roster,
      schedule: schedule,
      bots: %{},
      session_defaults: Application.get_env(:rc_bot, :session_defaults, %{}),
      # Local pause — controlled by THIS driver's operator via the
      # harness LiveView. Distinct from the prod-side global kill switch
      # (queried over HTTP per fleet_enabled?/0). Both must be true for
      # sessions to spawn.
      locally_paused: false
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
    cond do
      state.locally_paused ->
        Logger.info("driver locally paused; deferring wake for #{bot_id}")
        ref = Process.send_after(self(), {:wake, bot_id}, paused_backoff_ms())

        state =
          update_in(state, [:bots, bot_id], fn b ->
            %{(b || %{}) | wake_ref: ref}
          end)

        {:noreply, state}

      not fleet_enabled?() ->
        Logger.info("fleet globally denied; deferring wake for #{bot_id}")
        ref = Process.send_after(self(), {:wake, bot_id}, paused_backoff_ms())

        state =
          update_in(state, [:bots, bot_id], fn b ->
            %{(b || %{}) | wake_ref: ref}
          end)

        {:noreply, state}

      true ->
        case Enum.find(state.roster, &(&1.bot_id == bot_id)) do
          nil ->
            Logger.warning("wake for unknown bot #{bot_id} — dropping")
            {:noreply, state}

          entry ->
            start_session(entry, state)
        end
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

    {:reply,
     %{
       schedule: state.schedule,
       bots: snapshot,
       locally_paused: state.locally_paused,
       globally_permitted: fleet_enabled?()
     }, state}
  end

  def handle_call(:pause, _from, state) do
    Logger.info("driver locally paused by operator")
    {:reply, :ok, %{state | locally_paused: true}}
  end

  def handle_call(:resume, _from, state) do
    Logger.info("driver locally resumed by operator")
    {:reply, :ok, %{state | locally_paused: false}}
  end

  def handle_call(:paused?, _from, state) do
    {:reply, state.locally_paused, state}
  end

  # ── Internals ───────────────────────────────────────────────────────

  # Poll the rc server's bot-control endpoint with a short cache so we
  # don't hit the network per-wake when the fleet is large. Defaults to
  # false (paused) on transport errors — fail closed.
  defp fleet_enabled? do
    case :persistent_term.get({__MODULE__, :fleet_enabled}, nil) do
      {value, expires_at_ms} when is_integer(expires_at_ms) ->
        if System.system_time(:millisecond) < expires_at_ms do
          value
        else
          refresh_fleet_enabled()
        end

      _ ->
        refresh_fleet_enabled()
    end
  end

  defp refresh_fleet_enabled do
    url = Application.fetch_env!(:rc_bot, :target_http) <> "/api/harness/bot-control/state"
    secret = System.get_env("RC_BOT_HARNESS_SECRET") || Application.get_env(:rc_bot, :harness_secret)

    headers = if secret, do: [{"x-harness-secret", secret}], else: []

    value =
      case Req.get(url, headers: headers, retry: false, receive_timeout: 3_000) do
        {:ok, %{status: 200, body: %{"enabled" => enabled}}} when is_boolean(enabled) ->
          enabled

        other ->
          Logger.warning("fleet_enabled probe failed: #{inspect(other)} — assuming paused")
          false
      end

    expires_at_ms = System.system_time(:millisecond) + 10_000
    :persistent_term.put({__MODULE__, :fleet_enabled}, {value, expires_at_ms})
    value
  end

  defp paused_backoff_ms, do: 15_000

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
      # Pre-fetched server-side so Session.obtain_jwt + get_or_register
      # both short-circuit without an extra HTTP round-trip. Especially
      # important on bot-only instances where the registrations endpoint
      # is gated behind admin.
      registration_token: get.(:registration_token),
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
