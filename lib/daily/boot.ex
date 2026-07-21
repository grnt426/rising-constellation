defmodule Daily.Boot do
  @moduledoc """
  MVP live boot for a daily challenge.

  Builds an in-memory instance — the same shape the tutorial uses
  (`Portal.GameController.tutorial_data/2`), so no scenario/instance DB rows
  are needed — from a generated `Daily` definition and a reusable demo
  profile, then stands up the live supervision tree with
  `Instance.Manager.create_from_model/2` followed by `:start`. The economy
  begins ticking immediately at the daily's fast clock.

  This is a developer / MVP trigger, reached via the harness-secret endpoint
  `POST /api/harness/daily/start`. The real per-player flow — persisted
  instance + registration, lobby hiding, leaderboard — is a later milestone
  (see docs/daily-challenge.md).

  Player stats are intentionally not persisted here: the in-memory instance /
  registration ids aren't real rows, so the periodic `PlayerStat` insert fails
  its FK constraint and is discarded (the player agent ignores the result).
  Fine for the MVP — the economy still ticks. The moment we move to real
  per-player instances, stats persist for free.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias RC.Accounts
  alias RC.Accounts.Profile

  @demo_email "daily-demo@tetrarchyfalls.local"
  @demo_name "DailyDemo"

  @doc "Boot today's daily (UTC). Returns `{:ok, summary}` | `{:error, reason}`."
  def boot_today, do: boot_for(Date.utc_today())

  @doc "Boot the daily for `date` (a `Date` or ISO-8601 string)."
  def boot_for(date) do
    definition = Daily.definition_for(date)
    profile = ensure_demo_profile()
    instance_id = gen_instance_id()
    instance = in_memory_instance(instance_id, definition.game_data, profile)

    with {:ok, :instantiated} <- Instance.Manager.create_from_model(instance, nil),
         {:ok, :started, _} <- Instance.Manager.call(instance_id, :start) do
      Logger.info("[daily] booted instance #{instance_id} for #{definition.date}")

      {:ok,
       %{
         instance_id: instance_id,
         player_id: profile.id,
         date: definition.date,
         objective: definition.objective,
         mutators: definition.mutators
       }}
    else
      error ->
        Logger.error("[daily] boot failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Persisted boot for browser play. Creates real scenario + instance +
  registration rows for `profile`, stands up the live supervision tree, and
  transitions the instance to "running". Returns the join payload the SPA
  feeds straight into its game store (same shape as
  `Portal.GameController.join/2`), so the player goes to /game without the
  lobby/registration UI.

  Each call creates a fresh instance (one attempt) — retries are new
  instances, matching the "keep best score" design. Unlike `boot_for/1`, this
  one persists, so PlayerStat / leaderboard work once those land.
  """
  def boot_persisted(profile, date \\ Date.utc_today())

  def boot_persisted(%Profile{} = profile, date) do
    # Reap any of this player's still-live dailies first, so repeatedly
    # starting-then-abandoning runs can't pile up instances and DoS the server.
    reap_running_dailies(profile.id)

    definition = Daily.definition_for(date)

    {:ok, scenario} =
      %RC.Scenarios.Scenario{}
      |> RC.Scenarios.Scenario.changeset(%{
        game_data: definition.game_data,
        game_metadata: definition.game_metadata,
        is_map: false
      })
      |> RC.Repo.insert()

    instance_attrs = %{
      "name" => "Daily Challenge — #{definition.date}",
      "description" => "Daily challenge for #{definition.date}",
      "opening_date" => DateTime.to_iso8601(DateTime.utc_now()),
      "registration_type" => "pre_registration",
      "game_type" => "private",
      "public" => false,
      "start_setting" => "auto",
      "factions" => [%{"key" => definition.faction, "capacity" => 1}]
    }

    {:ok, %{instance: instance}} =
      RC.Instances.create_instance(instance_attrs, scenario, profile.account_id)

    {:ok, _} = RC.Instances.publish_instance(instance, profile.account_id)

    [faction] = instance.factions
    {:ok, %{registration: registration}} = RC.Registrations.register_profile(faction, profile)

    loaded = RC.Instances.get_instance_with_registration(instance.id)

    with {:ok, :instantiated} <- Instance.Manager.create_from_model(loaded, nil),
         {:ok, _} <- RC.Instances.start_instance(loaded, profile.account_id) do
      # NB: the economy (and the per-minute autosave) start on the first client
      # connect via `ensure_started/1`, NOT here — so the 3-minute clock doesn't
      # burn while the browser is still loading the game. `start_instance` above
      # is a pure DB-state transition; it doesn't tick anything.
      Logger.info("[daily] persisted boot instance=#{instance.id} for #{definition.date}")

      {:ok,
       %{
         instance_id: instance.id,
         faction_id: faction.id,
         profile_id: profile.id,
         registration_token: registration.token,
         definition: definition
       }}
    else
      error ->
        Logger.error("[daily] persisted boot failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Read a live daily instance's current economy state — for confirming it's
  ticking. Returns a plain (JSON-encodable) map; missing/unreachable agents
  come back as nil rather than raising.
  """
  def status(instance_id, player_id) do
    time = call(instance_id, :time, :master, :get_state)
    player = call(instance_id, :player, player_id, :get_state)
    galaxy = call(instance_id, :galaxy, :master, :get_state)

    %{
      instance_id: instance_id,
      running: match?(%{is_running: true}, time),
      date: time && (Map.get(time, :current_date) || Map.get(time, :date)),
      player: player_summary(player),
      systems: galaxy && Enum.map(galaxy.stellar_systems, &system_summary(instance_id, &1))
    }
  end

  @doc """
  Finalize a daily the instant its clock expires: freeze the economy, then
  record the score exactly once. Called from the Victory agent's `:victory`
  tick — which fires a single time per instance, when `ut_time_left` first hits
  zero — so the recorded score is the value "at the moment the game ended",
  not whenever the player happens to leave.

  Stopping every tick server *before* reading the player guarantees the value
  can't move: with the clock halted the player can no longer accrue resources
  or complete buildings on the victory screen. Runs async (under
  RC.TaskSupervisor) because `Instance.Manager.call/2` `:stop` calls into every
  tick server — including the Victory agent that invokes this — so doing it
  inline would deadlock the victory tick on itself.
  """
  def finalize(instance_id) do
    Task.Supervisor.start_child(RC.TaskSupervisor, fn ->
      # Freeze first so the score we read next is the deadline value.
      Instance.Manager.call(instance_id, :stop)

      case fetch_player(instance_id) do
        nil ->
          Logger.warning("[daily] finalize: no live player for instance #{instance_id}")

        player ->
          score = record_for(instance_id, player)
          Logger.info("[daily] finalized instance #{instance_id} score=#{inspect(score)}")
      end
    end)

    :ok
  end

  @doc """
  Start the economy on the first client connect (called from the player agent's
  `:connect` handler). Deferring the tick-start from boot to connect means the
  3-minute clock only begins once the player's browser is actually in the game,
  not while it spends ~20s loading. Idempotent — a no-op once the sim is already
  ticking, so reconnects don't restart it. Also kicks off the per-minute
  leaderboard autosave. Runs async because `Instance.Manager.call/2` `:stop`
  /`:start` fan out to every tick server — including the player agent that
  calls this — so doing it inline would deadlock.
  """
  def ensure_started(instance_id) do
    Task.Supervisor.start_child(RC.TaskSupervisor, fn ->
      case Game.call(instance_id, :time, :master, :get_state) do
        {:ok, %{is_running: true}} ->
          :noop

        _ ->
          Instance.Manager.call(instance_id, :start)

          case fetch_player(instance_id) do
            %Instance.Player.Player{id: profile_id} ->
              Game.cast(instance_id, :player, profile_id, :start_daily_autosave)

            _ ->
              :noop
          end

          Logger.info("[daily] started instance #{instance_id} on client connect")
      end
    end)

    :ok
  end

  @doc """
  Per-minute safety net, driven by the player agent's wall-clock timer (see
  `Instance.Player.Agent` `:daily_autosave`). Keeps the leaderboard within a
  minute of the player's progress so a crash or dropped connection *before* the
  deadline still records something. Returns `:stop` once the run has finalized
  (deadline reached) so the agent ends the loop and the locked deadline score
  stands; otherwise records the live score and returns `:continue`.
  """
  def autosave(instance_id, %Instance.Player.Player{} = player) do
    if finalized?(instance_id) do
      :stop
    else
      record_for(instance_id, player)
      :continue
    end
  end

  @doc """
  Explicitly quit a daily — the player hit "Exit". Records a final keep-best
  score and tears the instance down right away. This is the *intentional* exit
  path; a mere websocket drop (the disconnect handler) deliberately does NOT
  destroy, so a transient blip during loading can't end the run. Runs async so
  the caller (a channel handler) can reply before the tree is destroyed.
  """
  def quit(instance_id) do
    Task.Supervisor.start_child(RC.TaskSupervisor, fn -> teardown(instance_id, fetch_player(instance_id)) end)
    :ok
  end

  @doc """
  Reap every still-live daily instance owned by `profile_id`. Called before a
  player boots a fresh daily, so a player who repeatedly starts-then-abandons
  runs (e.g. a flaky connection, or a deliberate flood) can't accumulate live
  instances and exhaust the server. Each reaped run keeps its best score (in
  case the disconnect that should have ended it never landed). Runs
  synchronously — the old runs are gone before the new one stands up.
  """
  def reap_running_dailies(profile_id) do
    for instance_id <- running_daily_instance_ids(profile_id) do
      teardown(instance_id, fetch_player(instance_id))
      Logger.info("[daily] reaped stale instance #{instance_id} for profile #{profile_id}")
    end

    :ok
  end

  # Record a final keep-best score (unless already finalized / no live player)
  # then finish + destroy the instance. Shared by quit/1 and the reaper.
  defp teardown(instance_id, player) do
    if match?(%Instance.Player.Player{}, player) and not finalized?(instance_id) do
      record_for(instance_id, player)
    end

    case RC.Instances.get_instance(instance_id) do
      nil -> :noop
      %{state: "ended"} -> :noop
      instance -> RC.Instances.finish_instance(instance, instance.account_id)
    end

    Instance.Manager.destroy(instance_id)
  end

  # Ids of this profile's daily instances that haven't ended — the candidates
  # for reaping. Scoped to dailies (`game_mode_type`) so a player's live
  # *multiplayer* games are never touched.
  defp running_daily_instance_ids(profile_id) do
    from(i in RC.Instances.Instance,
      join: f in assoc(i, :factions),
      join: r in assoc(f, :registrations),
      where: r.profile_id == ^profile_id,
      where: i.state != "ended",
      where: fragment("? ->> ? = ?", i.game_data, "game_mode_type", "daily"),
      distinct: true,
      select: i.id
    )
    |> RC.Repo.all()
  end

  # True once the daily has reached its time limit. The Victory agent sets
  # `winner` synchronously at the deadline tick — before `finalize/1` runs — so
  # this is a reliable "score is locked" gate for the disconnect path even
  # while finalization is still in flight.
  defp finalized?(instance_id) do
    case Game.call(instance_id, :victory, :master, :get_state) do
      {:ok, %{winner: winner}} -> winner != nil
      _ -> false
    end
  end

  @doc """
  Live race-completion check, called from the player agent's tick (every
  player in every game — the non-daily path is a couple of map lookups and
  bails). On the tick where a race objective's goal first holds, records the
  win — score = real seconds left on the clock — and flags the player
  (`:daily_race_won`, snapshot-tolerant via Map.put) so it fires exactly once.
  The record itself runs async: reading the Victory agent from inside the
  player tick could deadlock the tick fan-out.
  """
  def race_tick(instance_id, %Instance.Player.Player{} = player) do
    with false <- Map.get(player, :daily_race_won, false),
         objective_key when is_binary(objective_key) <- Instance.Mutators.daily_objective(instance_id),
         %{mode: :race} = objective <- Daily.Objective.get(objective_key),
         true <- Daily.Objective.race_completed?(objective, player) do
      record_race_win(instance_id, objective, player)
      Map.put(player, :daily_race_won, true)
    else
      _ -> player
    end
  end

  def race_tick(_instance_id, player), do: player

  # Score a race win: seconds of real time left when the goal was met. Reads
  # ut_time_left from the Victory agent and converts using the speed factor
  # (real ms per ut = 180_000 / factor — see Core.Tick.delta). Async because
  # the caller is inside the player agent's tick.
  defp record_race_win(instance_id, objective, %Instance.Player.Player{} = player) do
    date = Instance.Mutators.daily_date(instance_id)
    profile_id = player.id

    Task.Supervisor.start_child(RC.TaskSupervisor, fn ->
      with {:ok, %{ut_time_left: ut_left}} <- Game.call(instance_id, :victory, :master, :get_state),
           {:ok, %{speed: speed}} <- Game.call(instance_id, :time, :master, :get_state),
           %{factor: factor} <- Data.Querier.one(Data.Game.Speed, instance_id, speed) do
        seconds_left = max(ut_left, 0) * 180 / factor
        Daily.record_score(profile_id, date, objective.key, seconds_left, 1.0, instance_id)
        Logger.info("[daily] race won instance=#{instance_id} seconds_left=#{Float.round(seconds_left / 1, 1)}")
      else
        other ->
          Logger.warning("[daily] race win could not be scored for instance #{instance_id}: #{inspect(other)}")
      end
    end)
  end

  # Compute the day's score from the live player and upsert it (keep-best). The
  # objective/date come from the in-memory metadata cache, so this is cheap
  # enough to run on the stats-tick autosave. Returns the score, or nil when
  # the instance isn't a daily / its metadata is gone.
  defp record_for(instance_id, %Instance.Player.Player{} = player) do
    objective = Instance.Mutators.daily_objective(instance_id)
    date = Instance.Mutators.daily_date(instance_id)

    if is_binary(objective) and is_binary(date) do
      stats =
        Instance.Player.Player.get_stats(player)
        |> Map.put(:stored_technology, trunc(player.technology.value))
        |> Map.put(:stored_ideology, trunc(player.ideology.value))
        # Dominion count for sector days (Hegemon). get_stats folds dominions
        # into total_systems; the daily needs them counted on their own.
        |> Map.put(:total_dominions, length(player.dominions))
        # Owned-system count for conquest sector days (Siege Breaker) — excludes
        # dominions, so vassalizing can't score a conquest day.
        |> Map.put(:total_owned, length(player.stellar_systems))

      %{score: score, tiebreak: tiebreak} = Daily.Objective.evaluate(objective, stats, player)
      Daily.record_score(player.id, date, objective, score, tiebreak, instance_id)
      score
    end
  end

  # Resolve the single live player agent for a daily instance via its faction's
  # registration (one faction, one profile by construction).
  defp fetch_player(instance_id) do
    with instance when not is_nil(instance) <- RC.Instances.get_instance_with_registration(instance_id),
         [faction | _] <- instance.factions,
         [registration | _] <- faction.registrations,
         %Profile{id: profile_id} <- registration.profile,
         {:ok, player} <- Game.call(instance_id, :player, profile_id, :get_state) do
      player
    else
      _ -> nil
    end
  end

  # --- internals -----------------------------------------------------------

  defp gen_instance_id, do: :os.system_time(:second) * 1000 + :rand.uniform(999)

  defp in_memory_instance(instance_id, game_data, profile) do
    %{
      id: instance_id,
      factions: [
        %{
          id: 1,
          capacity: 1,
          faction_ref: get_in(game_data, ["daily", "faction"]) || "tetrarchy",
          registrations: [%{id: 1, profile: profile}]
        }
      ],
      game_data: game_data
    }
  end

  # Idempotent: one shared demo account+profile, reused across boots.
  defp ensure_demo_profile do
    account =
      case Accounts.get_account_by_email(@demo_email) do
        {:ok, account} ->
          account

        {:error, _} ->
          {:ok, account} =
            Accounts.create_account(%{
              email: @demo_email,
              password: random_password(),
              name: @demo_name,
              role: :user,
              status: :active
            })

          account
      end

    case RC.Repo.get_by(Profile, account_id: account.id) do
      nil ->
        {:ok, profile} =
          Accounts.create_profile(%{account_id: account.id, name: @demo_name, avatar: "todo"})

        profile

      profile ->
        profile
    end
  end

  defp random_password, do: "daily-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))

  defp call(instance_id, type, id, action) do
    case Game.call(instance_id, type, id, action, 3, 2_000) do
      {:ok, state} -> state
      _ -> nil
    end
  end

  defp player_summary(nil), do: nil

  defp player_summary(p) do
    %{
      name: p.name,
      owned_systems: length(p.stellar_systems),
      credit: dynamic_value(p.credit),
      technology: dynamic_value(p.technology),
      ideology: dynamic_value(p.ideology)
    }
  end

  # The galaxy holds a lightweight system summary (no economy/bodies); the
  # per-system agent holds production and the bodies (with their factors/tiles
  # — i.e. what the world-gen mutators changed). Read both and merge.
  defp system_summary(instance_id, gs) do
    full = call(instance_id, :stellar_system, gs.id, :get_state)

    %{
      name: gs.name,
      type: gs.type,
      status: gs.status,
      owner: gs.owner,
      population: round1(gs.population),
      production: full && value(full.production),
      credit: full && value(full.credit),
      technology: full && value(full.technology),
      ideology: full && value(full.ideology),
      bodies: full && Enum.map(full.bodies, &body_summary/1)
    }
  end

  defp body_summary(b) do
    %{
      type: b.type,
      factors: "#{b.industrial_factor}/#{b.technological_factor}/#{b.activity_factor}",
      tiles: length(b.tiles),
      moons: length(b.bodies)
    }
  end

  defp dynamic_value(%Core.DynamicValue{value: v, change: c}),
    do: %{value: round1(v), per_day: round1(c)}

  defp dynamic_value(_), do: nil

  defp value(%Core.Value{value: v}), do: round1(v)
  defp value(_), do: nil

  defp round1(n) when is_number(n), do: Float.round(n / 1, 1)
  defp round1(_), do: nil
end
