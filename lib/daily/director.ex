defmodule Daily.Director do
  @moduledoc """
  Plays a daily objective's scripted opposition against a live instance.

  The only script so far is Headhunter (`director: :headhunter` in
  `Daily.Objective`), whose rules and numbers live in `Daily.Headhunter`.
  Every `Daily.Headhunter.interval_seconds/0` of real time the Director makes
  one pass (`pulse/2`):

    1. **Arrivals.** It reads the run's clock and brings the roster up to the
       number of enemy Erased due by now, each minted for the puppet player
       and stood in the human's home system. Counting from the game clock
       rather than from its own passes means a late pass catches up and the
       run always sends the same roster.
    2. **The sweep.** Every enemy Erased in one of the human's systems is
       measured against that system's Intelligence. A newly exposed one is
       announced to the player; every exposed one has its cover held down so
       it stays in plain sight until it is removed.
    3. **Removal attempts.** A bold agent that is still hidden may be ordered,
       once, to remove one of the human's Erased in the same system.

  The Director is a task outside the instance's supervision tree, started when
  the run's clock starts (`Daily.Boot.ensure_started/1`). It holds no state the
  instance needs: it ends when the run has a winner or the instance is gone,
  and a daily does not outlive a restart.

  Everything the agents do goes through the engine's own calls: an agent is
  handed to the puppet player the way a seduced one is
  (`{:convert_character, ...}`), and a removal attempt is an ordinary queued
  action, rolled and paid for like a player's.
  """

  require Logger

  alias Daily.Headhunter
  alias Instance.Character.Character

  defstruct [:instance_id, :date, :human_id, :puppet_id, sent: 0, recruits: %{}, exposed: MapSet.new()]

  # The puppet pays wages for every agent it fields. A bankrupt player's
  # agents go on strike and refuse orders, so its purse is made bottomless.
  @puppet_purse 1_000_000_000

  @doc "Start directing `instance_id` if its objective has a script. Returns `:ok` either way."
  def start(instance_id) do
    if directed?(instance_id) do
      Task.Supervisor.start_child(RC.TaskSupervisor, fn -> run(instance_id) end)
    end

    :ok
  end

  @doc "Whether the instance's daily objective has a script for the Director."
  def directed?(instance_id) do
    match?(%{director: :headhunter}, Daily.Objective.get(Instance.Mutators.daily_objective(instance_id)))
  end

  @doc false
  def run(instance_id) do
    # one Director per instance, however many clients connect at once
    with :yes <- :global.register_name({__MODULE__, instance_id}, self()),
         {:ok, state} <- init(instance_id) do
      Logger.info("[daily] director started for instance #{instance_id}")
      loop(state, System.monotonic_time(:millisecond), 1)
    else
      :no -> :ok
      other -> Logger.warning("[daily] director could not start for instance #{instance_id}: #{inspect(other)}")
    end
  end

  # Passes are scheduled against the start time, so the work a pass does
  # never pushes the later ones back.
  defp loop(state, started_at, pass) do
    wake_at = started_at + pass * Headhunter.interval_seconds() * 1000
    Process.sleep(max(wake_at - System.monotonic_time(:millisecond), 0))

    case pulse(state) do
      {:cont, state} -> loop(state, started_at, pass + 1)
      :halt -> Logger.info("[daily] director done for instance #{state.instance_id}: #{state.sent} sent")
    end
  end

  @doc """
  The Director's starting state for a live puppet-faction daily:
  `{:ok, state}`, or the step that failed.
  """
  def init(instance_id) do
    with date when is_binary(date) <- Instance.Mutators.daily_date(instance_id),
         puppet_faction when is_binary(puppet_faction) <- Instance.Mutators.daily_puppet_faction(instance_id),
         {:ok, galaxy} <- Game.call(instance_id, :galaxy, :master, :get_state),
         players = Map.values(galaxy.players),
         %{id: puppet_id} <- Enum.find(players, &(Atom.to_string(&1.faction) == puppet_faction)),
         %{id: human_id} <- Enum.find(players, &(Atom.to_string(&1.faction) != puppet_faction)),
         :ok <- Game.call(instance_id, :player, puppet_id, {:add_resources, @puppet_purse, 0, 0}) do
      {:ok, %__MODULE__{instance_id: instance_id, date: date, human_id: human_id, puppet_id: puppet_id}}
    end
  end

  @doc """
  One pass. Returns `{:cont, state}`, or `:halt` once the run is over or the
  instance is gone.

  Options, for tests: `:due` (how many agents should have arrived, instead of
  reading the clock), `:intel` (read every system as having this much
  Intelligence) and `:roll` (a zero-arity function returning a float in
  `[0, 1)`, instead of `:rand.uniform/0`).
  """
  def pulse(%__MODULE__{} = state, opts \\ []) do
    case clock(state.instance_id) do
      {:running, elapsed} ->
        due = Keyword.get(opts, :due) || Headhunter.due(elapsed)
        roll = Keyword.get(opts, :roll, &:rand.uniform/0)
        intel = Keyword.get(opts, :intel)

        with {:ok, human} <- Game.call(state.instance_id, :player, state.human_id, :get_state) do
          state = arrivals(state, due, human)

          case Game.call(state.instance_id, :player, state.puppet_id, :get_state) do
            {:ok, puppet} -> {:cont, sweep(state, human, puppet, roll, intel)}
            _ -> :halt
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

  # --- the clock ------------------------------------------------------------

  # Real seconds of the run played so far, read off the Victory agent's
  # countdown (the same conversion as Daily.Boot's race scoring).
  defp clock(instance_id) do
    with {:ok, %{winner: nil, ut_time_left: ut_left}} <-
           Game.call_no_log(instance_id, :victory, :master, :get_state, 1),
         {:ok, %{is_running: running, speed: speed}} <- Game.call_no_log(instance_id, :time, :master, :get_state, 1),
         %{factor: factor} <- Data.Querier.one(Data.Game.Speed, instance_id, speed) do
      limit = Daily.Generator.time_limit_minutes() * 60
      if running, do: {:running, limit - max(ut_left, 0) * 180 / factor}, else: :paused
    else
      _ -> :over
    end
  end

  # --- arrivals -------------------------------------------------------------

  defp arrivals(state, due, human) do
    case human.stellar_systems do
      [home | _] -> Enum.reduce((state.sent + 1)..due//1, state, &arrive(&2, &1, home.id))
      [] -> state
    end
  end

  defp arrive(state, n, system_id) do
    recruit = Headhunter.recruit(state.date, n)

    case mint(state, recruit, system_id) do
      {:ok, id} ->
        %{state | sent: n, recruits: Map.put(state.recruits, id, Map.put(recruit, :struck?, false))}

      other ->
        Logger.warning(
          "[daily] director: recruit #{n} did not arrive in instance #{state.instance_id}: #{inspect(other)}"
        )

        %{state | sent: n}
    end
  end

  @doc """
  Mint one enemy Erased of `level` for the puppet player `puppet_id` and
  stand it in `system_id` (one of the human's systems), the way the
  Headhunter's arrivals come in. Its removal skill follows the Headhunter
  rule (half its level). Used by scenario scripts' `send_agent` (see
  `Edict.Live`). Returns `{:ok, character_id}` or the step that failed.
  """
  def mint_agent(instance_id, puppet_id, level, system_id) do
    recruit = %{level: level, skills: [0, Headhunter.removal_points(level), 0, 0, 0, 0]}
    mint(%__MODULE__{instance_id: instance_id, puppet_id: puppet_id}, recruit, system_id)
  end

  @doc "Fund the puppet player so its agents never go on strike (see `@puppet_purse`)."
  def fund_puppet(instance_id, puppet_id) do
    Game.call(instance_id, :player, puppet_id, {:add_resources, @puppet_purse, 0, 0})
  end

  # A market character is rolled, not designed. Skills and specialization go
  # in through `initial_data`; level and what a level earns (Protection,
  # Determination) are set afterwards, and so are the skills again, because
  # the constructor spends its opening experience on a random extra point.
  # Activation recomputes the bonuses on the way into the roster.
  defp mint(state, recruit, system_id) do
    iid = state.instance_id

    with {:ok, tmp_id} <- Game.call(iid, :character_market, :master, :get_next_character_id),
         {:ok, before} <- Game.call(iid, :player, state.puppet_id, :get_state) do
      type_data = Data.Querier.one(Data.Game.Character, iid, :spy)

      character = %{
        Character.new(tmp_id, :spy, :common, 1, iid, %{spec1: :assassin, spec2: :assassin, skills: recruit.skills})
        | level: recruit.level,
          skills: recruit.skills,
          protection: min(recruit.level * type_data.gain_protection, type_data.max_protection),
          determination: min(recruit.level * type_data.gain_determination, type_data.max_determination)
      }

      # the handover mints its own id: find it in the roster afterwards
      with :ok <- Game.call(iid, :player, state.puppet_id, {:convert_character, character, system_id}, 1, 30_000),
           {:ok, now} <- Game.call(iid, :player, state.puppet_id, :get_state),
           [id] <- Enum.map(now.characters, & &1.id) -- Enum.map(before.characters, & &1.id) do
        {:ok, id}
      end
    end
  end

  # --- the sweep and the removal attempts -----------------------------------

  defp sweep(state, human, puppet, roll, forced_intel) do
    # agents the player has removed leave the puppet's roster
    alive = MapSet.new(puppet.characters, & &1.id)

    state = %{
      state
      | recruits: Map.filter(state.recruits, fn {id, _} -> MapSet.member?(alive, id) end),
        exposed: MapSet.intersection(state.exposed, alive)
    }

    held = MapSet.new(human.stellar_systems, & &1.id)

    present =
      Enum.filter(puppet.characters, fn c ->
        c.type == :spy and c.status == :on_board and MapSet.member?(held, c.system) and
          Map.has_key?(state.recruits, c.id)
      end)

    systems =
      present
      |> Enum.map(& &1.system)
      |> Enum.uniq()
      |> Enum.flat_map(fn system_id ->
        case Game.call(state.instance_id, :stellar_system, system_id, :get_state) do
          {:ok, system} -> [{system_id, system}]
          _ -> []
        end
      end)
      |> Map.new()

    Enum.reduce(present, state, fn character, state ->
      recruit = state.recruits[character.id]

      case systems[character.system] do
        nil ->
          state

        system ->
          cond do
            MapSet.member?(state.exposed, character.id) ->
              hold_exposed(state, character)

            Headhunter.exposed?(forced_intel || system.counter_intelligence.value, recruit.level, recruit.evasion) ->
              expose(state, character, system)

            recruit.bold? and not recruit.struck? and character.is_discovered != true and
                roll.() < Headhunter.strike_chance() ->
              strike(state, character, human)

            true ->
              state
          end
      end
    end)
  end

  defp hold_exposed(state, character) do
    Game.cast(state.instance_id, :character, character.id, {:daily_expose, Headhunter.exposed_cover()})
    state
  end

  defp expose(state, character, system) do
    notif = Notification.Text.new(:foreign_spy_discovered, system.id, %{spy: character.name, system: system.name})
    Game.cast(state.instance_id, :player, state.human_id, {:push_notifs, notif})

    hold_exposed(%{state | exposed: MapSet.put(state.exposed, character.id)}, character)
  end

  # The one removal attempt of a bold agent: an ordinary queued removal on one
  # of the player's Erased standing in the same system. With nobody to strike
  # the agent keeps its attempt for a later pass.
  defp strike(state, character, human) do
    targets =
      Enum.filter(human.characters, fn c ->
        c.type == :spy and c.status == :on_board and c.system == character.system
      end)

    case targets do
      [] ->
        state

      _ ->
        target = Enum.random(targets)

        action = %{
          "type" => "assassination",
          "data" => %{"target" => character.system, "target_character" => target.id}
        }

        result =
          Game.call(state.instance_id, :player, state.puppet_id, {:add_character_actions, character.id, [action]})

        if result != :ok do
          Logger.warning(
            "[daily] director: removal attempt refused in instance #{state.instance_id}: #{inspect(result)}"
          )
        end

        %{state | recruits: Map.update!(state.recruits, character.id, &%{&1 | struck?: true})}
    end
  end
end
