defmodule Edict.Match do
  @moduledoc """
  Runs the scripts a Forge scenario attaches, in a Legacy, Tactic or Flash
  match (`Edict.Live` runs a daily's playtest; this is its many-player
  sibling).

  **One run per player.** Each script runs once for every player, as if
  each had their own copy: `player` is that player, its `var`s are theirs,
  `notify` reaches them alone, `give` fills their stocks, `finish()` ends
  their run (the match goes on). What a script knows of everyone else is
  what the match shows openly (`factions`, `players`; `Edict.World`). A
  player who joins late starts their run then: `on start` runs for them, an
  `at` already past doesn't, an `every` picks up at its next occurrence on
  the match's clock (`Edict.Runtime.skip_to/2`). The Rebellion of a Rebel
  Defense match is the game's own opponent and gets no run.

  **The clock** is the match's running time in seconds, pauses excluded
  (`time.elapsed`), up to its time limit (`time.limit`). In Legacy a game
  day is 3 minutes of it, in Tactic 9 seconds, in Flash 1.5.

  **The runner** is a task outside the instance's supervision tree, like
  the daily's: nothing in the game waits on it, and if it fails the game
  carries on. `Instance.Manager` starts it with the match (`start/1`, a
  no-op when it already runs), so a resume, a restart or the autosave
  cycle's stop/start bring it back. Its state (every run's vars, timers and
  score) is saved to `edict_match_runs` every few seconds and whenever an
  `on start` ran, and read back when it starts again, so a Legacy match's
  scripts survive deploys.

  **Cost.** A pulse reads a player's state only when one of their runs has
  something due (a timer, a `when`, which checks every second) or every
  #{10} seconds to refresh the scores they see; the steps a pulse may take are
  shared out among the runs due (`@match_fuel`), each sandboxed. See
  docs/scenario-scripting.md, "Scripts in matches".

  When the match is won, every run still going is finished (its score
  counted, its `on end` run) and the standings are posted to everyone.
  """

  require Logger

  import Ecto.Query

  alias Edict.{Attachment, Effects, Limits, Parser, Runtime, Sandbox, World}
  alias Portal.Controllers.{GlobalChannel, PlayerChannel}

  @status_every 10
  @roster_every 15
  @save_every_ms 5_000
  @max_paused_s 600
  # steps a match's runs may take in one second, all together, and the least
  # one run gets (a typical pulse takes tens; test/edict/resource_bench_test.exs,
  # section 10)
  @match_fuel 500_000
  @min_fuel 5_000
  @recent 5
  @max_state_bytes 8 * 1024 * 1024
  # a run whose pulse kills its sandbox (memory, time) this often is switched off
  @max_sandbox_failures 5

  defstruct [
    :instance_id,
    :mode,
    :limit,
    :factor,
    :systems,
    :rebel_faction,
    scripts: [],
    roster: [],
    roster_at: nil,
    everyone: %{},
    intelligence: %{},
    standings: [],
    recent: %{},
    msg_id: 0,
    started_us: 0,
    last_status: nil,
    last_t: 0.0,
    ended: false,
    dirty: false,
    saved_at: 0,
    save_now: false,
    paused_s: 0
  ]

  # --- lifecycle ---------------------------------------------------------------

  @doc "Start the runner for a scripted match, unless it already runs. Returns `:ok`."
  def start(instance_id) do
    case :global.whereis_name({__MODULE__, instance_id}) do
      pid when is_pid(pid) -> :ok
      :undefined -> Task.Supervisor.start_child(RC.TaskSupervisor, fn -> run(instance_id) end)
    end

    :ok
  end

  @doc "Stop the runner after saving its state (it starts again with the match). Returns `:ok`."
  def stop(instance_id) do
    case :global.whereis_name({__MODULE__, instance_id}) do
      pid when is_pid(pid) -> send(pid, :stop)
      :undefined -> :ok
    end

    :ok
  end

  @doc "A player opened the game: send them the scores and recent messages now rather than in a few seconds."
  def joined(instance_id, player_id) do
    case :global.whereis_name({__MODULE__, instance_id}) do
      pid when is_pid(pid) -> send(pid, {:status_for, player_id})
      :undefined -> :ok
    end

    :ok
  end

  @doc false
  def run(instance_id) do
    with :yes <- :global.register_name({__MODULE__, instance_id}, self()),
         {:ok, state} <- init(instance_id) do
      Logger.info("[edict] match runner started for instance #{instance_id} (#{length(state.scripts)} scripts)")
      loop(state, System.monotonic_time(:millisecond), 1)
    else
      :no -> :ok
      :ended -> :ok
      other -> Logger.warning("[edict] match runner could not start for instance #{instance_id}: #{inspect(other)}")
    end
  end

  @doc false
  # The runner's starting state: the scripts from the instance's game_data,
  # every run saved so far. Public for tests.
  def init(instance_id) do
    with %{game_data: game_data} <- RC.Instances.get_instance(instance_id),
         {:ok, %{speed: speed}} <- Game.call_no_log(instance_id, :time, :master, :get_state, 1),
         %{factor: factor} <- Data.Querier.one(Data.Game.Speed, instance_id, speed) do
      saved = load(instance_id)

      scripts =
        game_data
        |> Attachment.scripts()
        |> Enum.flat_map(&prepare_script/1)
        |> Enum.map(&restore_runs(&1, saved))

      cond do
        saved[:ended] -> :ended
        scripts == [] -> {:error, :no_runnable_script}
        true -> start_state(instance_id, game_data, speed, factor, scripts)
      end
    else
      nil -> {:error, :no_instance}
      other -> other
    end
  end

  defp start_state(instance_id, game_data, speed, factor, scripts) do
    {:ok,
     %__MODULE__{
       instance_id: instance_id,
       mode: Attachment.mode(speed),
       limit: (game_data["time_limit"] || 0) * 60.0,
       factor: factor,
       systems: length(List.wrap(game_data["systems"])),
       rebel_faction: Wave.Lobby.wave?(game_data) && get_in(game_data, ["wave", "bot_faction"]),
       scripts: scripts,
       started_us: System.os_time(:microsecond),
       saved_at: System.monotonic_time(:millisecond)
     }}
  end

  defp prepare_script(%{"source" => source, "digest" => digest} = frozen) do
    with {:ok, program} <- Parser.parse(source),
         [] <- Enum.filter(Edict.Checker.check(program), &(&1.severity == "error")),
         {:ok, template} <- Runtime.new(program) do
      [
        %{
          digest: digest,
          name: Effects.clean_text(frozen["name"] || template.config["name"] || "", 60),
          description: Effects.clean_text(template.config["description"] || "", 500),
          template: template,
          # a match has no rival court: send_agent is refused at the gate
          config: Map.put(template.config, "rival", false),
          race?: Runtime.race?(template),
          reads_players?: String.contains?(source, "players"),
          reads_intelligence?: String.contains?(source, "intelligence"),
          runs: %{}
        }
      ]
    else
      _ ->
        Logger.warning("[edict] script #{inspect(frozen["name"])} (#{digest}) can't run; skipped")
        []
    end
  end

  defp prepare_script(_), do: []

  defp restore_runs(script, saved) do
    runs =
      saved
      |> Map.get(:runs, %{})
      |> Map.get(script.digest, %{})
      |> Map.new(fn {pid, %{dump: dump} = run} ->
        {pid, new_run(Runtime.restore(script.template, dump), run[:score], run[:tiebreak])}
      end)

    %{script | runs: runs}
  end

  defp new_run(rt, score \\ nil, tiebreak \\ nil),
    do: %{rt: rt, gate: Effects.new(), seen: MapSet.new(), score: score, tiebreak: tiebreak, crashes: 0}

  defp loop(state, started_at, pass) do
    wait = max(started_at + pass * 1000 - System.monotonic_time(:millisecond), 0)

    receive do
      {:status_for, player_id} ->
        state |> send_status(player_id) |> loop(started_at, pass)

      :stop ->
        save(state)
        Logger.info("[edict] match runner stopped for instance #{state.instance_id}")
    after
      wait ->
        case tick(state) do
          {:cont, state} ->
            loop(maybe_save(state), started_at, pass + 1)

          {:halt, state} ->
            save(state)
            Logger.info("[edict] match runner stopped for instance #{state.instance_id}")
        end
    end
  end

  @doc false
  # One pass. Public for tests.
  def tick(state) do
    case clock(state) do
      {:running, elapsed, victory} ->
        {:cont, pulse(%{state | paused_s: 0}, elapsed, victory)}

      :paused ->
        # stopped for a while (a pause, maintenance): the next start brings
        # the runner back
        if state.paused_s >= @max_paused_s, do: {:halt, state}, else: {:cont, %{state | paused_s: state.paused_s + 1}}

      {:over, victory} ->
        {:halt, finalize(state, victory)}

      :gone ->
        {:halt, state}
    end
  end

  defp clock(state) do
    with {:ok, victory} <- Game.call_no_log(state.instance_id, :victory, :master, :get_state, 1),
         {:ok, %{is_running: running}} <- Game.call_no_log(state.instance_id, :time, :master, :get_state, 1) do
      cond do
        victory.winner != nil -> {:over, victory}
        running -> {:running, max(state.limit - max(victory.ut_time_left, 0) * 180 / state.factor, 0.0), victory}
        true -> :paused
      end
    else
      _ -> :gone
    end
  end

  # --- a pulse -----------------------------------------------------------------------

  defp pulse(state, t, victory) do
    state = state |> refresh_roster(victory, t) |> Map.put(:standings, standings(victory))
    status? = state.last_status == nil or t - state.last_status >= @status_every

    due =
      for %{id: pid} <- state.roster,
          script <- state.scripts,
          run <- [script.runs[pid]],
          run == nil or Runtime.due?(run.rt, t),
          do: {pid, script.digest}

    fuel = fuel_per_run(length(due))
    due_players = due |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    state =
      Enum.reduce(state.roster, state, fn %{id: pid} = who, state ->
        if status? or MapSet.member?(due_players, pid), do: pulse_player(state, who, t, fuel, status?), else: state
      end)

    state = %{state | last_t: t}

    if status? do
      Enum.each(state.roster, &push_status(state, &1.id))
      %{state | last_status: t}
    else
      state
    end
  end

  @doc "The steps each of `due` runs may take this second: the match's budget shared out."
  def fuel_per_run(due) do
    due |> max(1) |> then(&div(@match_fuel, &1)) |> max(@min_fuel) |> min(Limits.fuel_per_pulse())
  end

  defp pulse_player(state, %{id: pid}, t, fuel, status?) do
    case Game.call_no_log(state.instance_id, :player, pid, :get_state, 1) do
      {:ok, %{is_active: false}} ->
        state

      {:ok, player} ->
        state = %{state | everyone: Map.put(state.everyone, pid, World.someone(player))}
        state = refresh_intelligence(state, pid, player, t)

        Enum.reduce(state.scripts, state, fn script, state ->
          run_script(state, script, pid, player, t, fuel, status?)
        end)

      _ ->
        state
    end
  end

  defp run_script(state, script, pid, player, t, fuel, status?) do
    run =
      case script.runs[pid] do
        nil -> new_run(if(t > 30, do: Runtime.skip_to(script.template, t), else: script.template))
        run -> run
      end

    world = world(state, script, player, t)

    work = fn ->
      {rt, result} =
        if Runtime.due?(run.rt, t), do: Runtime.pulse(run.rt, world, t, fuel: fuel), else: {run.rt, nil}

      score = if status? or result, do: Runtime.peek_score(rt, world), else: run.score
      {rt, result, score}
    end

    case Sandbox.run(work) do
      {:ok, {rt, nil, score}} ->
        put_run(state, script, pid, %{run | rt: rt, score: score})

      {:ok, {rt, result, score}} ->
        started? = Enum.any?(result.fired, &(&1.kind == :start))
        run = %{run | rt: rt, score: score}
        {run, state} = apply_effects(state, script, pid, run, result.effects, world, t)
        {run, state} = report_errors(state, script, pid, run, result.errors)
        # an on start that ran must never run again: save at once
        state = %{state | dirty: true, save_now: state.save_now or started?}

        if result.finished do
          finish_run(state, script, pid, run, world, t, result.finished)
        else
          put_run(state, script, pid, run)
        end

      {:error, reason} ->
        {run, state} = report_errors(state, script, pid, run, [%{message: Sandbox.describe(reason)}])
        crashes = run.crashes + 1

        if crashes >= @max_sandbox_failures do
          # the playtest's rule: five times and the script is off (for this player)
          state = say(state, pid, script.name, "script problem: it failed #{crashes} times and is now off", "error")
          rt = %{run.rt | handlers: Enum.map(run.rt.handlers, &%{&1 | off?: true})}
          put_run(%{state | dirty: true}, script, pid, %{run | rt: rt, crashes: crashes})
        else
          put_run(state, script, pid, %{run | crashes: crashes})
        end
    end
  end

  defp put_run(state, script, pid, run) do
    scripts =
      Enum.map(state.scripts, fn
        %{digest: d} = s when d == script.digest -> %{s | runs: Map.put(s.runs, pid, run)}
        s -> s
      end)

    %{state | scripts: scripts}
  end

  defp world(state, script, player, t) do
    World.build(player,
      clock: %{elapsed: t, left: state.limit - t, limit: state.limit},
      config: script.config,
      intelligence: Map.get(state.intelligence, player.id, {nil, %{}}) |> elem(1),
      mode: state.mode,
      factions: state.standings,
      players: if(script.reads_players?, do: Map.values(state.everyone), else: [World.someone(player)]),
      systems: state.systems
    )
  end

  # System Intelligence costs a call per system: only for scripts that read
  # it, at most every few seconds per player.
  defp refresh_intelligence(state, pid, player, t) do
    fresh? =
      case Map.get(state.intelligence, pid) do
        {at, _} -> t - at < @status_every
        nil -> false
      end

    if fresh? or not Enum.any?(state.scripts, & &1.reads_intelligence?) do
      state
    else
      values =
        Map.new(player.stellar_systems, fn s ->
          case Game.call_no_log(state.instance_id, :stellar_system, s.id, :get_state, 1) do
            {:ok, system} -> {s.id, system.counter_intelligence.value}
            _ -> {s.id, 0}
          end
        end)

      %{state | intelligence: Map.put(state.intelligence, pid, {t, values})}
    end
  end

  # Players by faction, from the factions' own agents (every few seconds:
  # players join a Legacy match all along).
  defp refresh_roster(state, victory, t) do
    if state.roster_at != nil and t - state.roster_at < @roster_every and state.roster != [] do
      state
    else
      roster =
        for faction <- victory.factions,
            Atom.to_string(faction.key) != state.rebel_faction,
            {:ok, %{players: players}} <- [Game.call_no_log(state.instance_id, :faction, faction.id, :get_state, 1)],
            player <- players,
            do: %{id: player.id, name: player.name, faction: Atom.to_string(faction.key)}

      %{state | roster: Enum.uniq_by(roster, & &1.id), roster_at: t}
    end
  end

  defp standings(victory) do
    victory
    |> Instance.Victory.Victory.rank_factions()
    |> Enum.with_index(1)
    |> Enum.map(fn {faction, rank} -> World.faction(faction, rank) end)
  end

  # --- effects ---------------------------------------------------------------------

  defp apply_effects(state, script, pid, run, effects, world, t) do
    {accepted, refused, gate} = Effects.prepare(effects, world, script.config, run.gate, t)
    run = %{run | gate: gate}

    {run, state} =
      report_errors(
        state,
        script,
        pid,
        run,
        Enum.map(refused, fn %{effect: e, reason: why} -> %{message: "#{e["action"]} refused: #{why}"} end)
      )

    state = Enum.reduce(accepted, state, &apply_effect(&1, &2, script, pid))
    {run, state}
  end

  defp apply_effect(%{"action" => "give", "args" => %{"resource" => r, "amount" => n}}, state, _script, pid),
    do: add_resources(state, pid, r, n)

  defp apply_effect(%{"action" => "take", "args" => %{"resource" => r, "amount" => n}}, state, _script, pid),
    do: add_resources(state, pid, r, -n)

  defp apply_effect(%{"action" => "notify", "args" => %{"message" => text, "tone" => tone}}, state, script, pid),
    do: say(state, pid, script.name, text, tone)

  defp apply_effect(%{"action" => "destabilize", "args" => %{"amount" => n, "system" => id}}, state, _script, _pid) do
    Game.cast(state.instance_id, :stellar_system, trunc(id), {:add_happiness_penalty, :encourage_hate, n})
    state
  end

  defp apply_effect(_effect, state, _script, _pid), do: state

  defp add_resources(state, pid, resource, n) do
    {c, t, i} =
      case resource do
        "credit" -> {n, 0, 0}
        "technology" -> {0, n, 0}
        "ideology" -> {0, 0, n}
      end

    Game.call_no_log(state.instance_id, :player, pid, {:add_resources, c, t, i}, 1)
    state
  end

  # A player sees each distinct problem of their run once: they didn't write
  # the script, but they should know the scenario misbehaved.
  defp report_errors(state, _script, _pid, run, []), do: {run, state}

  defp report_errors(state, script, pid, run, errors) do
    fresh = errors |> Enum.map(& &1.message) |> Enum.uniq() |> Enum.reject(&MapSet.member?(run.seen, &1))

    state =
      fresh
      |> Enum.take(2)
      |> Enum.reduce(state, fn message, state ->
        say(state, pid, script.name, "script problem: " <> message, "error")
      end)

    {%{run | seen: Enum.reduce(fresh, run.seen, &MapSet.put(&2, &1))}, state}
  end

  # --- messages and status -------------------------------------------------------

  defp say(state, pid, source, text, tone) do
    id = state.msg_id + 1
    # unique across runner restarts: the client shows each id once
    message = %{id: "#{state.started_us}-#{id}", text: Effects.clean_text("#{source}: #{text}"), tone: tone}
    PlayerChannel.broadcast_change(topic(state, pid), %{scenario_message: message})
    recent = [message | Map.get(state.recent, pid, [])] |> Enum.take(@recent)
    %{state | msg_id: id, recent: Map.put(state.recent, pid, recent)}
  end

  defp topic(state, pid), do: "instance:player:#{state.instance_id}:#{pid}"

  defp send_status(state, pid) do
    if Enum.any?(state.roster, &(&1.id == pid)), do: push_status(state, pid)
    state
  end

  # Each script's name, goal and the player's score and place, plus their
  # last few messages (a player who was away sees what they missed).
  defp push_status(state, pid) do
    entries =
      Enum.map(state.scripts, fn script ->
        run = script.runs[pid]
        {rank, of} = rank(script, pid)

        %{
          name: script.name,
          description: script.description,
          race: script.race?,
          score: run && run.score,
          rank: rank,
          of: of,
          finished: run != nil and run.rt.finished != nil
        }
      end)

    PlayerChannel.broadcast_change(topic(state, pid), %{
      scenario_status: %{
        kind: "match",
        entries: entries,
        recent: state.recent |> Map.get(pid, []) |> Enum.reverse()
      }
    })
  end

  defp rank(script, pid) do
    scored = for {id, %{score: s} = run} <- script.runs, is_number(s), do: {id, s, run.tiebreak || 0}
    ordered = Enum.sort_by(scored, fn {_id, s, tb} -> {-s, -tb} end)

    case Enum.find_index(ordered, &(elem(&1, 0) == pid)) do
      nil -> {nil, length(ordered)}
      i -> {i + 1, length(ordered)}
    end
  end

  # --- finishing ----------------------------------------------------------------------

  # finish() in one player's run: their score is counted now, their on end
  # runs, and the match goes on.
  defp finish_run(state, script, pid, run, world, t, finished) do
    case Sandbox.run(fn -> Runtime.finish(run.rt, world, t) end) do
      {:ok, {rt, result}} ->
        run = %{run | rt: rt, score: result.score, tiebreak: result.tiebreak}
        {run, state} = apply_effects(state, script, pid, run, result.effects, world, t)
        {run, state} = report_errors(state, script, pid, run, result.errors)

        text =
          case finished do
            %{message: m} when is_binary(m) and m != "" -> "#{sentence(m)} Your score: #{fmt(result.score)}."
            _ -> "complete. Your score: #{fmt(result.score)}."
          end

        state = say(state, pid, script.name, text, "good")
        state = put_run(%{state | dirty: true, save_now: true}, script, pid, run)
        push_status(state, pid)
        state

      {:error, reason} ->
        {run, state} = report_errors(state, script, pid, run, [%{message: Sandbox.describe(reason)}])
        put_run(state, script, pid, %{run | rt: %{run.rt | finished: %{message: nil, t: t}}})
    end
  end

  @doc false
  # The match is won: every run still going is finished against the last
  # world, then each script's standings go to everyone. Public for tests.
  def finalize(%{ended: true} = state, _victory), do: state

  def finalize(state, victory) do
    # once won, the clock runs a short tail; the run ended at the last pulse
    t = state.last_t
    state = state |> refresh_roster(victory, t) |> Map.put(:standings, standings(victory))

    state =
      Enum.reduce(state.roster, state, fn %{id: pid}, state ->
        case Game.call_no_log(state.instance_id, :player, pid, :get_state, 1) do
          {:ok, player} ->
            Enum.reduce(state.scripts, state, fn script, state ->
              case script.runs[pid] do
                %{rt: %{finished: nil}} = run -> end_run(state, script, pid, run, world(state, script, player, t), t)
                _ -> state
              end
            end)

          _ ->
            state
        end
      end)

    Enum.each(state.scripts, &announce(state, &1))
    %{state | ended: true, dirty: true}
  end

  # The match is over: count the score and run on end, but change nothing
  # in a game that has finished (only its messages go out).
  defp end_run(state, script, pid, run, world, t) do
    case Sandbox.run(fn -> Runtime.finish(run.rt, world, t) end) do
      {:ok, {rt, result}} ->
        {accepted, _refused, _gate} = Effects.prepare(result.effects, world, script.config, run.gate, t)

        state =
          accepted
          |> Enum.filter(&(&1["action"] == "notify"))
          |> Enum.reduce(state, &apply_effect(&1, &2, script, pid))

        put_run(state, script, pid, %{run | rt: rt, score: result.score, tiebreak: result.tiebreak})

      {:error, _} ->
        state
    end
  end

  defp announce(state, script) do
    names = Map.new(state.roster, &{&1.id, &1.name})

    podium =
      script.runs
      |> Enum.filter(fn {_pid, run} -> is_number(run.score) end)
      |> Enum.sort_by(fn {_pid, run} -> {-run.score, -(run.tiebreak || 0)} end)
      |> Enum.take(3)
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{pid, run}, i} -> "#{i}. #{names[pid] || "?"} (#{fmt(run.score)})" end)

    if podium != "" do
      GlobalChannel.broadcast_change(GlobalChannel.topic(state.instance_id), %{
        scenario_message: %{text: Effects.clean_text("#{script.name}, final standings: #{podium}"), tone: "good"}
      })
    end

    Enum.each(state.roster, &push_status(state, &1.id))
    Logger.info("[edict] match #{state.instance_id}: #{script.name} final standings #{podium}")
  end

  defp sentence(text), do: if(String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> ".")

  # 12345.0 -> "12,345"
  defp fmt(n) when is_number(n), do: Edict.Printer.text(Float.round(n / 1, 1))
  defp fmt(_), do: "0"

  # --- saving --------------------------------------------------------------------------

  defp maybe_save(%{dirty: true} = state) do
    if state.save_now or System.monotonic_time(:millisecond) - state.saved_at >= @save_every_ms,
      do: save(state),
      else: state
  end

  defp maybe_save(state), do: state

  @doc false
  def save(state) do
    data = %{
      v: 1,
      ended: state.ended,
      runs:
        Map.new(state.scripts, fn script ->
          {script.digest,
           Map.new(script.runs, fn {pid, run} ->
             {pid, %{dump: Runtime.dump(run.rt), score: run.score, tiebreak: run.tiebreak}}
           end)}
        end)
    }

    binary = :erlang.term_to_binary(data, compressed: 6)

    if byte_size(binary) > @max_state_bytes do
      Logger.warning("[edict] match #{state.instance_id}: state too large to save (#{byte_size(binary)} bytes)")
    else
      now = DateTime.utc_now()

      RC.Repo.insert_all(
        "edict_match_runs",
        [%{instance_id: state.instance_id, state: binary, inserted_at: now, updated_at: now}],
        on_conflict: {:replace, [:state, :updated_at]},
        conflict_target: :instance_id
      )
    end

    %{state | dirty: false, save_now: false, saved_at: System.monotonic_time(:millisecond)}
  rescue
    e ->
      Logger.warning("[edict] match #{state.instance_id}: saving failed: #{Exception.message(e)}")
      state
  end

  @doc false
  def load(instance_id) do
    case RC.Repo.one(from(r in "edict_match_runs", where: r.instance_id == ^instance_id, select: r.state)) do
      nil -> %{}
      binary -> :erlang.binary_to_term(binary, [:safe])
    end
  rescue
    e ->
      Logger.warning("[edict] match #{instance_id}: saved state unreadable: #{Exception.message(e)}")
      %{}
  end
end
