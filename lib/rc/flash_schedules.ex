defmodule RC.FlashSchedules do
  @moduledoc """
  Regularly scheduled Flash matches.

  An admin defines weekly schedules (`RC.FlashSchedules.Schedule`): a US
  Eastern weekday + time, a map pool rotated in order one map per week, an
  optional mutator override, ranked/casual, minimum players and seats per
  faction. `RC.FlashSchedules.Scheduler` then, every minute:

    1. creates each occurrence's match 48h before its start
       (`create_due_matches/1`), announces it in Discord #lfg and opens a
       Discord guild scheduled event for it (`RC.Discord.FlashEvent`),
    2. keeps that event's player counts and status in step with the lobby
       (`event_data/2`),
    3. closes lobbies that still haven't started 48h after the scheduled
       start (`expire_stale_matches/1`),
    4. posts the result to #lfg once a started match declares a victory.

  The lobby of a scheduled match works differently from a user-created one:
  players join any faction and **ready up** (which locks their faction until
  they unready). Once the scheduled time has passed and at least 80% of the
  joined players are ready — never fewer than 2, nor fewer than the
  schedule's minimum — any ready player may start the match.
  Players who never readied up are removed at start.
  """

  import Ecto.Query, warn: false

  require Logger

  alias RC.Accounts.Account
  alias RC.Discord.{EasternTime, FlashAnnouncer, FlashEvent}
  alias RC.FlashSchedules.{Schedule, ScheduledMatch}
  alias RC.Instances
  alias RC.Instances.{Faction, Registration, Victory}
  alias RC.Registrations
  alias RC.Repo
  alias RC.Scenarios.Scenario

  @tz_db Tzdata.TimeZoneDatabase

  # The lobby opens this long before the scheduled start (two days, so
  # the Discord scheduled event has a lobby to link to and members have
  # time to sign up)...
  @lobby_lead_seconds 48 * 3_600
  # ...and is still created if the scheduler was down until this long after.
  @late_create_seconds 3_600
  # Unstarted lobbies close this long after the scheduled start.
  @expire_after_seconds 48 * 3_600
  @ready_floor 2

  def lobby_lead_seconds, do: @lobby_lead_seconds
  def expire_after_seconds, do: @expire_after_seconds

  ## Schedules

  def list_schedules do
    Schedule
    |> order_by([s], asc: s.weekday, asc: s.start_time, asc: s.id)
    |> Repo.all()
  end

  def get_schedule(id), do: Repo.get(Schedule, id)

  def create_schedule(attrs, account_id) do
    %Schedule{account_id: account_id, anchor_date: EasternTime.today()}
    |> Schedule.changeset(editable(attrs))
    |> validate_scenarios()
    |> Repo.insert()
  end

  def update_schedule(%Schedule{} = schedule, attrs) do
    schedule
    |> Schedule.changeset(editable(attrs))
    |> validate_scenarios()
    |> Repo.update()
  end

  def delete_schedule(%Schedule{} = schedule), do: Repo.delete(schedule)

  defp editable(attrs), do: Map.drop(attrs, ["anchor_date", "account_id", "id"])

  # Every map in the pool must be an existing Flash scenario.
  defp validate_scenarios(changeset) do
    Ecto.Changeset.validate_change(changeset, :scenario_ids, fn :scenario_ids, ids ->
      found =
        from(s in Scenario,
          where: s.id in ^ids and s.is_map == false and fragment("?->>'speed' = 'fast'", s.game_data),
          select: s.id
        )
        |> Repo.all()
        |> MapSet.new()

      case Enum.reject(ids, &MapSet.member?(found, &1)) do
        [] -> []
        missing -> [scenario_ids: "not Flash scenarios: #{Enum.join(missing, ", ")}"]
      end
    end)
  end

  @doc "`%{id => %{name, factions, system_number, mutators}}` for the given scenario ids."
  def scenario_summaries(ids) do
    from(s in Scenario, where: s.id in ^Enum.uniq(ids), select: {s.id, s.game_metadata})
    |> Repo.all()
    |> Map.new(fn {id, meta} ->
      meta = meta || %{}

      {id,
       %{
         id: id,
         name: meta["name"] || "Scenario ##{id}",
         factions: Enum.map(meta["factions"] || [], & &1["key"]),
         system_number: meta["system_number"],
         mutators: Enum.map(meta["mutators"] || [], & &1["key"])
       }}
    end)
  end

  ## Occurrences

  @doc """
  The occurrences of `schedule` whose start falls in `[from, to)`, as
  `%{starts_at: utc DateTime, date: Eastern Date, scenario_id}`.
  """
  def occurrences(%Schedule{} = schedule, %DateTime{} = from, %DateTime{} = to) do
    Date.range(Date.add(eastern_date(from), -1), Date.add(eastern_date(to), 1))
    |> Enum.filter(&(Date.day_of_week(&1) == schedule.weekday))
    |> Enum.map(fn date ->
      %{starts_at: starts_at(schedule, date), date: date, scenario_id: scenario_for(schedule, date)}
    end)
    |> Enum.filter(fn o ->
      DateTime.compare(o.starts_at, from) != :lt and DateTime.compare(o.starts_at, to) == :lt
    end)
  end

  @doc "UTC start of the schedule's slot on the given Eastern date."
  def starts_at(%Schedule{start_time: time}, %Date{} = date) do
    date
    |> NaiveDateTime.new!(Time.truncate(time, :second))
    |> EasternTime.from_naive!()
    |> EasternTime.to_utc()
  end

  @doc "The map of the week: the pool rotates in order, one step per week since `anchor_date`."
  def scenario_for(%Schedule{scenario_ids: ids, anchor_date: anchor}, %Date{} = date) do
    week = Integer.floor_div(Date.diff(date, anchor), 7)
    Enum.at(ids, Integer.mod(week, length(ids)))
  end

  defp eastern_date(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!(EasternTime.timezone(), @tz_db) |> DateTime.to_date()

  @doc """
  Calendar entries in `[from, to)`: projected occurrences of enabled
  schedules plus every scheduled match actually created in the range
  (held, running or expired), each with its lobby when one exists. Past
  slots that never got a lobby (before the schedule existed, or while it
  was disabled) are left out.
  """
  def calendar(%DateTime{} = from, %DateTime{} = to, now \\ DateTime.utc_now()) do
    not_before = DateTime.add(now, -@late_create_seconds)

    schedules = list_schedules()

    matches =
      from(m in ScheduledMatch,
        join: i in assoc(m, :instance),
        where: m.scheduled_start_at >= ^from and m.scheduled_start_at < ^to,
        select: {m, i}
      )
      |> Repo.all()

    by_slot = Map.new(matches, fn {m, i} -> {{m.schedule_id, DateTime.to_unix(m.scheduled_start_at)}, {m, i}} end)

    projected =
      for s <- schedules, s.enabled, o <- occurrences(s, from, to) do
        {m, i} = Map.get(by_slot, {s.id, DateTime.to_unix(o.starts_at)}, {nil, nil})
        entry(s, o.starts_at, (i && i.scenario_id) || o.scenario_id, m, i)
      end
      |> Enum.reject(&(is_nil(&1.instance_id) and DateTime.compare(&1.starts_at, not_before) == :lt))

    projected_keys = MapSet.new(projected, &{&1.schedule_id, DateTime.to_unix(&1.starts_at)})
    schedules_by_id = Map.new(schedules, &{&1.id, &1})

    created =
      for {m, i} <- matches,
          not MapSet.member?(projected_keys, {m.schedule_id, DateTime.to_unix(m.scheduled_start_at)}) do
        entry(Map.get(schedules_by_id, m.schedule_id), m.scheduled_start_at, i.scenario_id, m, i)
      end

    entries = projected ++ created
    names = scenario_summaries(Enum.map(entries, & &1.scenario_id))

    entries
    |> Enum.map(&Map.put(&1, :scenario_name, get_in(names, [&1.scenario_id, :name])))
    |> Enum.sort_by(&DateTime.to_unix(&1.starts_at))
  end

  defp entry(schedule, starts_at, scenario_id, match, instance) do
    %{
      schedule_id: schedule && schedule.id,
      name: (schedule && schedule.name) || (instance && instance.name),
      game_mode_type:
        (instance && instance.game_data["game_mode_type"]) || (schedule && schedule.game_mode_type) || "casual",
      starts_at: starts_at,
      scenario_id: scenario_id,
      instance_id: instance && instance.id,
      status: match && match.status
    }
  end

  ## Match creation

  @doc """
  Creates the lobby of every enabled schedule's occurrence starting within
  the next 48h (or that started under an hour ago, for a
  scheduler that was down). Idempotent. Returns the new scheduled matches.
  """
  def create_due_matches(now \\ DateTime.utc_now()) do
    from = DateTime.add(now, -@late_create_seconds)
    to = DateTime.add(now, @lobby_lead_seconds + 1)

    for schedule <- list_schedules(),
        schedule.enabled,
        occurrence <- occurrences(schedule, from, to),
        not match_exists?(schedule.id, occurrence.starts_at),
        reduce: [] do
      acc ->
        case create_match(schedule, occurrence) do
          {:ok, match} ->
            [match | acc]

          {:error, reason} ->
            Logger.error("[flash_schedules] schedule ##{schedule.id} at #{occurrence.starts_at}: #{inspect(reason)}")
            acc
        end
    end
    |> Enum.reverse()
  end

  defp match_exists?(schedule_id, starts_at) do
    from(m in ScheduledMatch, where: m.schedule_id == ^schedule_id and m.scheduled_start_at == ^starts_at)
    |> Repo.exists?()
  end

  @doc false
  def create_match(%Schedule{} = schedule, %{starts_at: starts_at, scenario_id: scenario_id}) do
    # Not one transaction: instance state transitions (Machinery) write from
    # their own process. The match row is inserted before publishing so the
    # unique slot index claims the occurrence; any later failure deletes the
    # instance again (the match row cascades with it).
    with %Scenario{} = scenario <- Repo.get(Scenario, scenario_id) || {:error, :scenario_not_found},
         owner_id when is_integer(owner_id) <- schedule.account_id || first_admin_id() || {:error, :no_owner},
         {:ok, %{instance: instance}} <-
           Instances.create_instance(instance_attrs(schedule, scenario, starts_at), model(schedule, scenario), owner_id) do
      with {:ok, match} <-
             %ScheduledMatch{}
             |> ScheduledMatch.changeset(%{
               schedule_id: schedule.id,
               instance_id: instance.id,
               scheduled_start_at: starts_at,
               min_players: schedule.min_players,
               status: "open"
             })
             |> Repo.insert(),
           {:ok, _instance} <- Instances.publish_instance(instance, owner_id) do
        {:ok, match}
      else
        error ->
          Repo.delete(instance)
          error
      end
    else
      {:error, _step, reason, _changes} -> {:error, reason}
      error -> error
    end
  end

  defp first_admin_id do
    from(a in Account, where: a.role == :admin, order_by: a.id, limit: 1, select: a.id) |> Repo.one()
  end

  defp instance_attrs(schedule, scenario, starts_at) do
    meta = scenario.game_metadata || %{}
    faction_keys = Enum.map(meta["factions"] || [], & &1["key"])

    capacity =
      schedule.faction_capacity ||
        max(1, round((meta["system_number"] || 0) / 6 / max(length(faction_keys), 1)))

    date_label = starts_at |> eastern_date() |> Calendar.strftime("%a %b %-d")

    %{
      "name" => String.slice("#{schedule.name} · #{date_label}", 0, 120),
      "description" => description(schedule),
      "opening_date" => starts_at,
      "registration_type" => "pre_registration",
      "start_setting" => "manual",
      "game_type" => "public",
      "public" => true,
      "game_mode_type" => schedule.game_mode_type,
      "cheats_enabled" => false,
      "factions" => Enum.map(faction_keys, &%{"key" => &1, "capacity" => capacity})
    }
  end

  # The lobby's description (right-hand panel): the schedule's own text, or
  # a short default, always followed by the two rules players trip over.
  @rules "Players not ready at start are removed. If not started within 48hrs of start time, this match auto-closes."

  defp description(%Schedule{description: text}) do
    intro =
      case String.trim(text || "") do
        "" ->
          "Scheduled Flash match. Join a faction and ready up; once the start time has passed " <>
            "and enough players are ready, any ready player can start the match."

        text ->
          text
      end

    intro <> "\n\n" <> @rules
  end

  # The scenario model handed to create_instance, with the schedule's
  # mutator override (nil keeps the scenario's own).
  defp model(%Schedule{mutator_keys: nil}, scenario),
    do: %{id: scenario.id, game_data: scenario.game_data, game_metadata: scenario.game_metadata}

  defp model(%Schedule{mutator_keys: keys}, scenario) do
    mutators = Enum.map(keys, &%{"key" => &1})

    %{
      id: scenario.id,
      game_data: Map.put(scenario.game_data, "mutators", mutators),
      game_metadata: Map.put(scenario.game_metadata || %{}, "mutators", mutators)
    }
  end

  ## Lobby

  def get_by_instance(instance_id), do: Repo.get_by(ScheduledMatch, instance_id: instance_id)

  @doc "Batch `%{instance_id => %{scheduled_start_at, status}}` for lobby lists."
  def scheduled_by_instance([]), do: %{}

  def scheduled_by_instance(instance_ids) do
    from(m in ScheduledMatch,
      where: m.instance_id in ^instance_ids,
      select: {m.instance_id, %{scheduled_start_at: m.scheduled_start_at, status: m.status}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Ready players needed to start with `joined` players in the lobby."
  def required_ready(joined, min_players) do
    # ceil(80%) in integer arithmetic (0.8 * 15 is 12.000000000000002).
    Enum.max([@ready_floor, min_players || @ready_floor, div(4 * joined + 4, 5)])
  end

  @doc """
  The lobby state of a scheduled match, or nil for an unscheduled instance.
  `blockers` lists what still prevents a start (empty when `can_start`).
  """
  def lobby(instance_id, now \\ DateTime.utc_now()) do
    case get_by_instance(instance_id) do
      nil -> nil
      match -> lobby_state(match, now)
    end
  end

  defp lobby_state(match, now) do
    joined = joined_registrations(match.instance_id)
    ready = Enum.filter(joined, & &1.ready_at)
    required = required_ready(length(joined), match.min_players)
    ready_factions = ready |> Enum.map(& &1.faction_id) |> Enum.uniq() |> length()
    time_reached = DateTime.compare(now, match.scheduled_start_at) != :lt

    blockers =
      [
        {match.status != "open", :not_open},
        {not time_reached, :before_start_time},
        {length(ready) < required, :not_enough_ready},
        {ready_factions < 2, :single_faction}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %{
      status: match.status,
      scheduled_start_at: match.scheduled_start_at,
      expires_at: DateTime.add(match.scheduled_start_at, @expire_after_seconds),
      min_players: match.min_players,
      joined_count: length(joined),
      ready_count: length(ready),
      required_ready: required,
      blockers: blockers,
      can_start: blockers == []
    }
  end

  defp joined_registrations(instance_id) do
    instance_id
    |> Registrations.list()
    |> Enum.filter(&(&1.state == "joined"))
  end

  defp player_registration(instance_id, account_id) do
    instance_id
    |> joined_registrations()
    |> Enum.find(&(&1.profile.account_id == account_id))
  end

  @doc "Whether new players may join the lobby (false while it is starting)."
  def accepting_registrations?(instance_id) do
    case get_by_instance(instance_id) do
      nil -> true
      match -> match.status == "open"
    end
  end

  @doc """
  Sets or clears the caller's ready flag. A ready player can't change
  faction (unjoin is refused) until they unready.
  """
  def set_ready(instance_id, account_id, ready?) when is_boolean(ready?) do
    with %ScheduledMatch{status: "open"} <- get_by_instance(instance_id) || {:error, :not_scheduled},
         %Registration{} = registration <- player_registration(instance_id, account_id) || {:error, :not_registered} do
      ready_at = if ready?, do: DateTime.utc_now()

      from(r in Registration, where: r.id == ^registration.id)
      |> Repo.update_all(set: [ready_at: ready_at])

      {:ok, lobby(instance_id)}
    else
      %ScheduledMatch{} -> {:error, :lobby_closed}
      {:error, _} = error -> error
    end
  end

  @doc """
  Starts a scheduled match on behalf of any ready player once the lobby
  allows it (the starter must be ready: unready players leave at start). Claims the lobby (open → starting) atomically so two players
  pressing Start at once can't double-start, then builds the world in a
  background task (`async: false` runs it inline, for tests).
  """
  def start_match(instance_id, account_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with %ScheduledMatch{} = match <- get_by_instance(instance_id) || {:error, :not_scheduled},
         %Registration{} = registration <- player_registration(instance_id, account_id) || {:error, :not_registered},
         true <- not is_nil(registration.ready_at) || {:error, :not_ready},
         %{can_start: true} <- lobby_state(match, now),
         {1, _} <-
           from(m in ScheduledMatch, where: m.id == ^match.id and m.status == "open")
           |> Repo.update_all(set: [status: "starting", started_by_account_id: account_id, updated_at: now]) do
      if Keyword.get(opts, :async, true) do
        Task.Supervisor.start_child(RC.TaskSupervisor, fn -> do_start(match.id, account_id) end)
        {:ok, :starting}
      else
        do_start(match.id, account_id)
      end
    else
      %{blockers: [blocker | _]} -> {:error, blocker}
      {0, _} -> {:error, :not_open}
      {:error, _} = error -> error
    end
  end

  @doc false
  def do_start(match_id, account_id) do
    match = Repo.get!(ScheduledMatch, match_id)
    removed = remove_unready(match.instance_id)
    instance = Instances.get_instance_with_registration(match.instance_id)

    with {:ok, :instantiated} <- Instance.Manager.create_from_model(instance, nil),
         {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
         {:ok, _} <- Instances.start_instance(instance, account_id) do
      match
      |> ScheduledMatch.changeset(%{status: "started", started_at: DateTime.utc_now()})
      |> Repo.update()

      Logger.info("[flash_schedules] instance ##{instance.id} started (#{removed} unready players removed)")
      {:ok, :started}
    else
      error ->
        Logger.error("[flash_schedules] start of instance ##{match.instance_id} failed: #{inspect(error)}")
        if Instance.Manager.created?(match.instance_id), do: Instance.Manager.destroy(match.instance_id)

        match
        |> ScheduledMatch.changeset(%{status: "open", started_by_account_id: nil})
        |> Repo.update()

        {:error, :start_failed}
    end
  end

  # Players who never readied up leave the match at start (their Discord
  # faction role goes with them). Returns how many were removed.
  defp remove_unready(instance_id) do
    unready = instance_id |> joined_registrations() |> Enum.reject(& &1.ready_at)

    Enum.each(unready, fn registration ->
      Repo.delete(registration)
      RC.Discord.RoleSync.sync_account_in_instance(registration.profile.account_id, instance_id)
    end)

    length(unready)
  end

  ## Housekeeping

  @doc "Closes lobbies still not started 48h after the scheduled start."
  def expire_stale_matches(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@expire_after_seconds)

    from(m in ScheduledMatch, where: m.status == "open" and m.scheduled_start_at <= ^cutoff)
    |> Repo.all()
    |> Enum.map(fn match ->
      instance = Instances.get_instance(match.instance_id)

      if instance && instance.state in ["created", "open"] do
        with {:ok, instance} <- Instances.close_instance(instance),
             {:ok, _} <- Instances.finish_instance(instance, instance.account_id) do
          :ok
        else
          error -> Logger.error("[flash_schedules] closing instance ##{instance.id} failed: #{inspect(error)}")
        end
      end

      {:ok, match} = match |> ScheduledMatch.changeset(%{status: "expired"}) |> Repo.update()
      match
    end)
  end

  @doc "Open lobbies whose #lfg announcement hasn't gone out yet."
  def unannounced_matches do
    from(m in ScheduledMatch, where: m.status == "open" and is_nil(m.announced_at)) |> Repo.all()
  end

  @doc "Started matches with a declared victory whose result hasn't been posted."
  def unposted_results do
    from(m in ScheduledMatch,
      join: v in Victory,
      on: v.instance_id == m.instance_id,
      where: m.status == "started" and is_nil(m.result_posted_at)
    )
    |> Repo.all()
  end

  def mark(%ScheduledMatch{} = match, field) when field in [:announced_at, :result_posted_at] do
    match |> ScheduledMatch.changeset(%{field => DateTime.utc_now()}) |> Repo.update()
  end

  @doc """
  Matches whose Discord guild scheduled event may still need a push: every
  open lobby that could still get one, plus any match already carrying an
  event we haven't finished with.
  """
  def matches_needing_event_sync(now \\ DateTime.utc_now()) do
    terminal = FlashEvent.terminal_statuses()

    from(m in ScheduledMatch,
      where:
        (is_nil(m.discord_event_status) or m.discord_event_status not in ^terminal) and
          (not is_nil(m.discord_event_id) or
             (m.status == "open" and m.scheduled_start_at > ^now))
    )
    |> Repo.all()
  end

  @doc "Records what was pushed to Discord for a match's scheduled event."
  def record_event(%ScheduledMatch{} = match, attrs) do
    match |> ScheduledMatch.changeset(attrs) |> Repo.update()
  end

  @doc """
  Everything the Discord guild scheduled event shows: the announcement
  fields plus the live lobby counts, the window the match occupies and
  the state the event should be in (`RC.Discord.FlashEvent`).
  """
  def event_data(%ScheduledMatch{} = match, now \\ DateTime.utc_now()) do
    instance = Instances.get_instance(match.instance_id)
    summary = scenario_summaries([instance.scenario_id])[instance.scenario_id] || %{}
    lobby = lobby_state(match, now)
    state = event_state(match, instance)

    %{
      instance_id: instance.id,
      name: instance.name,
      map_name: (instance.game_metadata || %{})["name"] || summary[:name],
      scheduled_start_at: match.scheduled_start_at,
      # Flash scenarios carry their wall-clock length in game_data.
      ends_at: DateTime.add(match.started_at || match.scheduled_start_at, time_limit_seconds(instance)),
      ranked: instance.game_data["game_mode_type"] == "ranked",
      state: state,
      joined_count: lobby.joined_count,
      ready_count: lobby.ready_count,
      required_ready: lobby.required_ready,
      lobby_url: FlashAnnouncer.lobby_url(instance.id),
      result: if(state == :completed, do: result_data(match)),
      now: now
    }
  end

  # Which Discord status the match's scheduled event should be in.
  defp event_state(%ScheduledMatch{status: "expired"}, _instance), do: :cancelled

  defp event_state(match, instance) do
    cond do
      Repo.exists?(from(v in Victory, where: v.instance_id == ^instance.id)) -> :completed
      match.status in ["starting", "started"] -> :active
      true -> :scheduled
    end
  end

  @default_time_limit_minutes 120

  defp time_limit_seconds(instance) do
    case instance.game_data["time_limit"] do
      minutes when is_integer(minutes) and minutes > 0 -> minutes * 60
      _ -> @default_time_limit_minutes * 60
    end
  end

  @doc "Everything the #lfg announcement shows about a scheduled match."
  def announcement_data(%ScheduledMatch{} = match) do
    instance = Instances.get_instance(match.instance_id)
    summary = scenario_summaries([instance.scenario_id])[instance.scenario_id] || %{}
    mutator_names = Map.new(Data.Game.Mutator.catalog(), &{to_string(&1.key), &1.name})

    %{
      instance_id: instance.id,
      name: instance.name,
      map_name: (instance.game_metadata || %{})["name"] || summary[:name],
      scheduled_start_at: match.scheduled_start_at,
      event_url: FlashEvent.event_url(match.discord_event_id),
      ranked: instance.game_data["game_mode_type"] == "ranked",
      min_players: match.min_players,
      factions: Enum.map(instance.factions, &%{key: &1.faction_ref, capacity: &1.capacity}),
      mutators: Enum.map(instance.game_data["mutators"] || [], &Map.get(mutator_names, &1["key"], &1["key"]))
    }
  end

  @doc "Winner, standings and the winning faction's players of a finished scheduled match."
  def result_data(%ScheduledMatch{} = match) do
    instance = Instances.get_instance(match.instance_id)
    victory = Repo.get_by(Victory, instance_id: instance.id)

    players =
      from(r in Registration,
        join: f in Faction,
        on: f.id == r.faction_id,
        join: p in assoc(r, :profile),
        where: f.instance_id == ^instance.id,
        order_by: p.name,
        select: {f.faction_ref, p.name}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    factions =
      instance.factions
      |> Enum.sort_by(&(&1.final_rank || 99))
      |> Enum.map(fn f ->
        %{key: f.faction_ref, rank: f.final_rank, victory_points: f.final_victory_points}
      end)

    winner = Enum.find(factions, &(&1.rank == 1))

    %{
      instance_id: instance.id,
      name: instance.name,
      map_name: (instance.game_metadata || %{})["name"],
      ranked: instance.game_data["game_mode_type"] == "ranked",
      victory_type: victory && victory.victory_type,
      winner: winner && winner.key,
      winner_players: (winner && Map.get(players, winner.key)) || [],
      factions: factions
    }
  end
end
