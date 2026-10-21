defmodule Edict.Live do
  @moduledoc """
  Runs a scenario script against a live game: the Scenario Workshop's
  playtest.

  `boot/2` checks the script, builds the day from its setup
  (`Daily.Generator.for_script/3`) and stands up a persisted single-player
  instance the same way a daily does (`Daily.Boot.boot_definition/3`). From
  there the daily's machinery runs it: the clock starts on the player's first
  connect, and the runner starts with it (`start/1`, called from
  `Daily.Boot.ensure_started/1`).

  The runner is a task outside the instance's supervision tree, like the
  Daily.Director: nothing in the game waits on it, and if it fails the game
  carries on without its script. Once a second it:

    1. reads the clock (real seconds played, from the Victory agent) and the
       human player, and builds the world the script reads (`Edict.World`);
    2. runs the script's due handlers in `Edict.Sandbox` (`Edict.Runtime`);
    3. passes the effects through the gate (`Edict.Effects`: own systems
       only, clean text, rate limits) and applies the survivors through the
       engine's own calls: resources with `{:add_resources, …}`, stability
       with `{:add_happiness_penalty, …}`, agents through
       `Daily.Director.mint_agent/4`, messages on the instance's global
       channel (`scenario_message`), shown in the game as plain text.

  The run ends when the script calls finish() (the clock is stopped through
  the Victory agent's `:force_time_up`, as a won daily race does) or at the
  deadline (`finalize/1`, called by `Daily.Boot.finalize/1`). Either way the
  script's score is counted and pushed to the player (`daily_result`,
  reason "scenario"). A playtest keeps no leaderboard.
  """

  require Logger

  alias Edict.{Checker, Effects, Parser, Printer, Runtime, Sandbox, World}
  alias Portal.Controllers.GlobalChannel

  defstruct [:instance_id, :rt, :human_id, :puppet_id, :limit, :gate, minted: [], sandbox_failures: 0, needs: %{}]

  @max_sandbox_failures 5

  # --- boot ------------------------------------------------------------------

  @doc """
  Boot a playtest of `source` for `profile`. Returns `{:ok, info}` (as
  `Daily.Boot.boot_persisted/2`) or `{:error, diagnostics}` when the script
  has errors.
  """
  def boot(%RC.Accounts.Profile{} = profile, source) when is_binary(source) do
    with {:ok, program} <- parse(source),
         :ok <- clean(program),
         {:ok, rt} <- Runtime.new(program) do
      canonical = Printer.print(program)
      game_data = Daily.Generator.for_script(rt.config, rt.seed, canonical)

      definition = %{
        date: get_in(game_data, ["daily", "date"]),
        game_data: game_data,
        game_metadata: Map.put(Daily.Generator.metadata_for(game_data), "scenario_script", true),
        faction: get_in(game_data, ["daily", "faction"])
      }

      case Daily.Boot.boot_definition(profile, definition, "Scenario playtest — #{rt.config["name"]}") do
        {:ok, info} ->
          {:ok, info}

        {:error, reason} ->
          {:error, [%{message: "the game could not start: #{inspect(reason)}", node_id: nil, at: nil}]}
      end
    end
  end

  defp parse(source) do
    case Parser.parse(source) do
      {:ok, program} -> {:ok, program}
      {:error, e} -> {:error, [%{message: e.message, node_id: nil, at: [e.line, e.col]}]}
    end
  end

  defp clean(program) do
    case Enum.filter(Checker.check(program), &(&1.severity == "error")) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # --- the runner ----------------------------------------------------------------

  @doc "Start the runner for `instance_id` if it is a scripted day. Returns `:ok` either way."
  def start(instance_id) do
    if Instance.Mutators.daily_scripted?(instance_id) do
      Task.Supervisor.start_child(RC.TaskSupervisor, fn -> run(instance_id) end)
    end

    :ok
  end

  @doc """
  The deadline: the Victory agent's time-up reached `Daily.Boot.finalize/1`.
  The runner counts the score and ends the run; without a runner (it
  already finished, or never started) the game is just stopped.
  """
  def finalize(instance_id) do
    case :global.whereis_name({__MODULE__, instance_id}) do
      pid when is_pid(pid) ->
        send(pid, :finalize)

      :undefined ->
        Task.Supervisor.start_child(RC.TaskSupervisor, fn -> Instance.Manager.call(instance_id, :stop) end)
    end

    :ok
  end

  @doc false
  def run(instance_id) do
    with :yes <- :global.register_name({__MODULE__, instance_id}, self()),
         {:ok, state} <- init(instance_id) do
      Logger.info("[edict] runner started for instance #{instance_id}")
      loop(state, System.monotonic_time(:millisecond), 1)
    else
      :no -> :ok
      other -> Logger.warning("[edict] runner could not start for instance #{instance_id}: #{inspect(other)}")
    end
  end

  @doc false
  def init(instance_id) do
    with %{"script" => source} <- Instance.Mutators.daily_setup(instance_id),
         {:ok, program} <- Parser.parse(source),
         {:ok, rt} <- Runtime.new(program),
         %{game_data: game_data} <- RC.Instances.get_instance(instance_id),
         {:ok, galaxy} <- Game.call(instance_id, :galaxy, :master, :get_state) do
      puppet_ref = Instance.Mutators.daily_puppet_faction(instance_id)
      players = Map.values(galaxy.players)
      human = Enum.find(players, &(Atom.to_string(&1.faction) != puppet_ref))
      puppet = puppet_ref && Enum.find(players, &(Atom.to_string(&1.faction) == puppet_ref))
      if puppet, do: Daily.Director.fund_puppet(instance_id, puppet.id)

      {:ok,
       %__MODULE__{
         instance_id: instance_id,
         rt: rt,
         human_id: human && human.id,
         puppet_id: puppet && puppet.id,
         limit: (game_data["time_limit"] || 30) * 60,
         gate: Effects.new(),
         needs: needs(source)
       }}
    end
  end

  # Only read what the script can see: system Intelligence costs a call per
  # system, so it is fetched only for scripts that mention it.
  defp needs(source), do: %{intelligence: String.contains?(source, "intelligence")}

  defp loop(state, started_at, pass) do
    wake_at = started_at + pass * 1000
    wait = max(wake_at - System.monotonic_time(:millisecond), 0)

    receive do
      :finalize -> end_run(state, :deadline)
    after
      wait ->
        case pulse(state) do
          {:cont, state} -> loop(state, started_at, pass + 1)
          {:finished, state} -> await_end(state)
          :halt -> Logger.info("[edict] runner done for instance #{state.instance_id}")
        end
    end
  end

  # After finish(): the Victory agent's time-up comes back as :finalize,
  # which this run has already handled. Linger briefly so it isn't mistaken
  # for a deadline with no runner.
  defp await_end(state) do
    receive do
      :finalize -> :ok
    after
      30_000 -> :ok
    end

    Logger.info("[edict] runner finished instance #{state.instance_id}")
  end

  @doc false
  # One pass: {:cont, state}, {:finished, state} or :halt. Public for tests.
  def pulse(state) do
    case clock(state) do
      {:running, elapsed} ->
        with {:ok, player} <- Game.call(state.instance_id, :player, state.human_id, :get_state) do
          world = world(state, player, elapsed)

          run = fn ->
            {rt, result} = Runtime.pulse(state.rt, world, elapsed)
            {rt, result, Runtime.peek_score(rt, world)}
          end

          case Sandbox.run(run) do
            {:ok, {rt, result, score}} ->
              state = %{state | rt: rt}
              state = apply_effects(state, result.effects, world, elapsed)
              report_errors(state, result.errors)
              status(state, score, elapsed)

              if result.finished do
                finish(state, world, elapsed)
                {:finished, state}
              else
                {:cont, state}
              end

            {:error, reason} ->
              failures = state.sandbox_failures + 1
              say(state, "Script stopped this second: #{Sandbox.describe(reason)}", "error")

              if failures >= @max_sandbox_failures do
                say(
                  state,
                  "The script failed #{failures} times and was switched off. The game carries on without it.",
                  "error"
                )

                :halt
              else
                {:cont, %{state | sandbox_failures: failures}}
              end
          end
        else
          _ -> :halt
        end

      :paused ->
        {:cont, state}

      :over ->
        :halt
    end
  end

  defp clock(state) do
    with {:ok, %{winner: nil, ut_time_left: ut_left}} <-
           Game.call_no_log(state.instance_id, :victory, :master, :get_state, 1),
         {:ok, %{is_running: running, speed: speed}} <-
           Game.call_no_log(state.instance_id, :time, :master, :get_state, 1),
         %{factor: factor} <- Data.Querier.one(Data.Game.Speed, state.instance_id, speed) do
      if running, do: {:running, max(state.limit - max(ut_left, 0) * 180 / factor, 0.0)}, else: :paused
    else
      _ -> :over
    end
  end

  defp world(state, player, elapsed) do
    intelligence =
      if state.needs.intelligence do
        Map.new(player.stellar_systems, fn s ->
          case Game.call(state.instance_id, :stellar_system, s.id, :get_state) do
            {:ok, system} -> {s.id, system.counter_intelligence.value}
            _ -> {s.id, 0}
          end
        end)
      else
        %{}
      end

    rival =
      if state.puppet_id do
        left =
          case Game.call(state.instance_id, :player, state.puppet_id, :get_state) do
            {:ok, puppet} -> Enum.count(puppet.characters, &(&1.id in state.minted))
            _ -> 0
          end

        %{faction: Instance.Mutators.daily_puppet_faction(state.instance_id), sent: length(state.minted), left: left}
      end

    World.build(player,
      clock: %{elapsed: elapsed, left: state.limit - elapsed, limit: state.limit},
      config: state.rt.config,
      intelligence: intelligence,
      rival: rival
    )
  end

  # --- effects -------------------------------------------------------------------

  defp apply_effects(state, effects, world, t) do
    {accepted, refused, gate} = Effects.prepare(effects, world, state.rt.config, state.gate, t)
    Enum.each(refused, fn %{effect: e, reason: why} -> say(state, "#{e["action"]} refused: #{why}", "error") end)
    echo(state, accepted, world)
    Enum.reduce(accepted, %{state | gate: gate}, &apply_effect/2)
  end

  # In a playtest the player is the author: say what the script did that the
  # game itself wouldn't show (agents arrive hidden, a stability hit or a
  # gift has no notice of its own). Small amounts and repeats stay quiet, so
  # a per-second drain doesn't flood the feed.
  defp echo(state, effects, world) do
    names = Map.new(get_in(world, ["player", "systems"]) || [], &{&1["id"], &1["name"]})

    effects
    |> Enum.flat_map(fn
      %{"action" => "send_agent", "args" => a} ->
        ["an enemy Erased of level #{trunc(a["level"])} slipped into #{names[a["system"]] || "your system"}"]

      %{"action" => "destabilize", "args" => a} ->
        ["stability #{fmt(-a["amount"])} in #{names[a["system"]] || "your system"}"]

      %{"action" => "give", "args" => %{"amount" => n} = a} when n >= 100 ->
        ["#{fmt(n)} #{a["resource"]}"]

      %{"action" => "take", "args" => %{"amount" => n} = a} when n >= 100 ->
        ["#{fmt(-n)} #{a["resource"]}"]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.take(3)
    |> Enum.each(&say(state, "Scenario: " <> &1, "echo"))
  end

  # 12345.0 -> "12,345"; -2.5 -> "-2.5"
  defp fmt(n) when is_number(n) do
    rounded = Float.round(n / 1, 1)

    if rounded == Float.round(rounded) do
      whole = trunc(rounded)

      digits =
        whole
        |> abs()
        |> Integer.to_string()
        |> String.reverse()
        |> String.to_charlist()
        |> Enum.chunk_every(3)
        |> Enum.join(",")
        |> String.reverse()

      if(whole < 0, do: "-", else: "+") <> digits
    else
      if(rounded < 0, do: "", else: "+") <> Float.to_string(rounded)
    end
  end

  # The scenario's name and score as they stand, for the in-game panel.
  defp status(state, score, elapsed) do
    GlobalChannel.broadcast_change(GlobalChannel.topic(state.instance_id), %{
      scenario_status: %{
        name: state.rt.config["name"],
        description: state.rt.config["description"],
        race: Runtime.race?(state.rt),
        score: score,
        elapsed: elapsed,
        limit: state.limit
      }
    })
  end

  defp apply_effect(%{"action" => "give", "args" => %{"resource" => r, "amount" => n}}, state) do
    add_resources(state, r, n)
  end

  defp apply_effect(%{"action" => "take", "args" => %{"resource" => r, "amount" => n}}, state) do
    add_resources(state, r, -n)
  end

  defp apply_effect(%{"action" => "notify", "args" => %{"message" => text, "tone" => tone}}, state) do
    say(state, text, tone)
    state
  end

  defp apply_effect(%{"action" => "destabilize", "args" => %{"amount" => n, "system" => id}}, state) do
    # the game's own Destabilization penalty, so the stability breakdown
    # names it and it fades the usual way
    Game.cast(state.instance_id, :stellar_system, trunc(id), {:add_happiness_penalty, :encourage_hate, n})
    state
  end

  defp apply_effect(%{"action" => "send_agent", "args" => %{"level" => level, "system" => id}}, state) do
    case state.puppet_id && Daily.Director.mint_agent(state.instance_id, state.puppet_id, trunc(level), trunc(id)) do
      {:ok, character_id} ->
        %{state | minted: [character_id | state.minted]}

      other ->
        Logger.warning("[edict] send_agent failed in instance #{state.instance_id}: #{inspect(other)}")
        state
    end
  end

  defp apply_effect(_effect, state), do: state

  defp add_resources(state, resource, n) do
    {c, t, i} =
      case resource do
        "credit" -> {n, 0, 0}
        "technology" -> {0, n, 0}
        "ideology" -> {0, 0, n}
      end

    Game.call(state.instance_id, :player, state.human_id, {:add_resources, c, t, i})
    state
  end

  # Script errors go to the player's message feed: in a playtest the player
  # is the author.
  defp report_errors(_state, []), do: :ok

  defp report_errors(state, errors) do
    errors
    |> Enum.uniq_by(& &1.message)
    |> Enum.take(3)
    |> Enum.each(fn e -> say(state, "Script error: #{e.message}", "error") end)
  end

  defp say(state, text, tone) do
    GlobalChannel.broadcast_change(GlobalChannel.topic(state.instance_id), %{
      scenario_message: %{text: Effects.clean_text(text), tone: tone}
    })
  end

  # --- the end -------------------------------------------------------------------

  # finish(): count the score now, stop the clock the way a won race does.
  defp finish(state, world, elapsed) do
    result = count(state, world, elapsed)
    Game.cast(state.instance_id, :victory, :master, :force_time_up)
    announce(state, result, elapsed, "finished")
  end

  # The deadline: freeze the economy first so the score can't move, then
  # count it with no time left.
  defp end_run(state, reason) do
    Instance.Manager.call(state.instance_id, :stop)

    case Game.call(state.instance_id, :player, state.human_id, :get_state) do
      {:ok, player} ->
        world = world(state, player, state.limit / 1)
        result = count(state, world, state.limit / 1)
        announce(state, result, state.limit / 1, Atom.to_string(reason))

      _ ->
        :ok
    end
  end

  defp count(state, world, t) do
    case Sandbox.run(fn -> Runtime.finish(state.rt, world, t) end) do
      {:ok, {_rt, result}} ->
        report_errors(state, result.errors)
        {accepted, _refused, _gate} = Effects.prepare(result.effects, world, state.rt.config, state.gate, t)
        Enum.each(accepted, &apply_effect(&1, state))
        result

      {:error, reason} ->
        say(state, "The score couldn't be counted: #{Sandbox.describe(reason)}", "error")
        %{score: 0.0, tiebreak: 0.0}
    end
  end

  defp announce(state, result, t, reason) do
    Logger.info("[edict] instance #{state.instance_id} ended (#{reason}) score=#{result.score}")

    GlobalChannel.broadcast_change(GlobalChannel.topic(state.instance_id), %{
      daily_result: %{
        reason: "scenario",
        ended: reason,
        title: state.rt.config["name"],
        run_score: result.score,
        tiebreak: result.tiebreak,
        message: get_in(state.rt.finished || %{}, [:message]),
        seconds_left: max(state.limit - t, 0),
        time_limit_seconds: state.limit,
        return_to: "/scenario-workshop"
      }
    })
  end
end
