defmodule Headless.Runner do
  @moduledoc """
  Headless turbo runner: boot an in-memory Fast instance with bot players,
  run it to its victory/timer end at the compiled `SPEEDUP`, tear it down,
  and report wall-clock + outcome + load statistics.

  Design constraints (docs/game-ai.md §8 Phase 0, adjusted per direction):

    * **Minimal engine change.** The engine's wall-clock-derived time model is
      used as-is — acceleration comes entirely from the existing compile-time
      `SPEEDUP` multiplier (`Core.Tick`). At overload the engine degrades by
      coarsening tick granularity (bigger `delta` per tick), which is
      rate-correct for the economy; we measure that pressure rather than
      forbid it.
    * **No RNG replicability requirement.** Scenario-level seeding (same
      `game_data` seed → same galaxy with `RC_DETERMINISTIC_GENERATION=1`) is
      available for paired A/B evaluations, but intra-game determinism is not
      pursued.
    * Boot path mirrors `Daily.Boot`: an in-memory instance model (no
      scenario/instance DB rows) through `Instance.Manager.create_from_model/2`
      + `:start`. Bot profiles are real DB rows (created once, reused), so
      per-player agents boot exactly like production ones; their PlayerStat
      inserts fail FK and are discarded, same as the daily MVP.

  Usage (inside the dev container — SPEEDUP is compile-time, see
  `mix headless.run`):

      SPEEDUP=120 mix headless.run --bots 1 --time-limit 120
  """

  require Logger

  alias RC.Accounts
  alias RC.Accounts.Profile

  @bot_email_domain "tetrarchyfalls.local"

  @doc """
  Run one headless game. Options:

    * `:game_data` — scenario map (default: `Headless.Scenario.fixture/0`)
    * `:time_limit` — override the scenario's wall-minute time limit
    * `:players_per_faction` — bot players per faction (default 1)
    * `:bots` — `false` to run engine-only (no bot drivers; default true)
    * `:bot_interval_ms` — bot decision cadence in wall ms (default 500)
    * `:poll_ms` — victory-poll cadence (default 250)

  Returns `{:ok, report}` | `{:error, reason}`.
  """
  def run(opts \\ []) do
    game_data =
      Keyword.get_lazy(opts, :game_data, fn -> Headless.Scenario.fixture() end)
      |> maybe_override_time_limit(opts[:time_limit])
      # The test fixture's win threshold is 2 VP (a shortcut for fast tests);
      # benchmarks that must run the full timer pass e.g. 999 here.
      |> maybe_override_victory_points(opts[:victory_points])
      # Marks the instance headless in its metadata (Instance.Mutators.headless?):
      # skips endgame DB bookkeeping and the autosave loop, neither of which can
      # work without DB rows.
      |> Map.put("headless", true)

    per_faction = Keyword.get(opts, :players_per_faction, 1)
    faction_keys = Headless.Scenario.faction_keys(game_data)
    profiles = ensure_bot_profiles(length(faction_keys) * per_faction)

    instance_id = gen_instance_id()
    model = build_model(instance_id, game_data, faction_keys, profiles, per_faction)

    # Per-game CPU accounting (busy scheduler-seconds across boot→destroy).
    # Only attributable when the game runs alone in the BEAM — in a parallel
    # batch every game's window sees the whole VM's work; use the batch
    # totals from mix headless.run instead.
    Headless.Cpu.enable()
    cpu0 = Headless.Cpu.snapshot()

    boot_t0 = System.monotonic_time(:millisecond)

    with {:ok, :instantiated} <- Instance.Manager.create_from_model(model, nil),
         boot_ms = System.monotonic_time(:millisecond) - boot_t0,
         {:ok, :started, _} <- Instance.Manager.call(instance_id, :start) do
      run_t0 = System.monotonic_time(:millisecond)
      initial_systems = snapshot_initial_systems(instance_id, model)

      bots =
        if Keyword.get(opts, :bots, true),
          do: start_bots(instance_id, model, game_data, opts),
          else: []

      sampler = start_sampler()

      expected_wall_ms = expected_wall_ms(game_data)
      outcome = await_end(instance_id, Keyword.get(opts, :poll_ms, 100), expected_wall_ms * 3 + 60_000)

      wall_ms = System.monotonic_time(:millisecond) - run_t0
      load = stop_sampler(sampler)

      bot_stats =
        Enum.map(bots, fn {pid, faction, _policy, player_id} ->
          Headless.Bot.stats(pid)
          |> Map.put(:faction, faction)
          |> Map.put(:colonies, colonies_with_strength(instance_id, player_id, initial_systems))
        end)

      Enum.each(bots, fn {pid, _, _, _} -> GenServer.stop(pid, :normal) end)

      destroy_t0 = System.monotonic_time(:millisecond)
      Instance.Manager.destroy(instance_id)
      destroy_ms = System.monotonic_time(:millisecond) - destroy_t0

      cpu = Headless.Cpu.delta(cpu0, Headless.Cpu.snapshot())

      report = build_report(instance_id, outcome, boot_ms, wall_ms, expected_wall_ms, load, bot_stats, destroy_ms, cpu)
      {:ok, report}
    else
      error ->
        # Best-effort cleanup on a failed boot.
        Instance.Manager.destroy(instance_id)
        {:error, error}
    end
  end

  # --- instance model --------------------------------------------------------

  # Mirrors Daily.Boot.in_memory_instance/3, generalized to N factions × M
  # players. Faction/registration ids are synthetic; profiles are real rows.
  defp build_model(instance_id, game_data, faction_keys, profiles, per_faction) do
    factions =
      faction_keys
      |> Enum.with_index(1)
      |> Enum.map(fn {key, faction_id} ->
        registrations =
          for slot <- 1..per_faction do
            profile = Enum.at(profiles, (faction_id - 1) * per_faction + (slot - 1))
            %{id: (faction_id - 1) * per_faction + slot, profile: profile}
          end

        %{id: faction_id, capacity: per_faction, faction_ref: key, registrations: registrations}
      end)

    %{id: instance_id, factions: factions, game_data: game_data}
  end

  defp maybe_override_time_limit(game_data, nil), do: game_data
  defp maybe_override_time_limit(game_data, minutes), do: Map.put(game_data, "time_limit", minutes)

  defp maybe_override_victory_points(game_data, nil), do: game_data
  defp maybe_override_victory_points(game_data, points), do: Map.put(game_data, "victory_points", points)

  # Wall-clock the game should take at this build's speedup: the UT budget is
  # fixed (minutes × factor / 180_000 at base factor), and UT flows at
  # factor × SPEEDUP — so wall time compresses by exactly SPEEDUP.
  defp expected_wall_ms(game_data) do
    div(game_data["time_limit"] * 60_000, Core.Tick.speedup())
  end

  # Millisecond epoch + per-BEAM unique counter: safe for concurrent runs
  # (the daily's second-resolution + rand id can collide across parallel boots).
  defp gen_instance_id do
    :os.system_time(:millisecond) * 1_000 + rem(System.unique_integer([:positive]), 1_000)
  end

  # --- bots -------------------------------------------------------------------

  # One driver per player. `:policies` assigns a policy module per FACTION
  # (cycled if shorter), so matchups pit strategies against each other in the
  # same game. Cadence is expressed in game-time (`:bot_interval_ut`,
  # default 3 UT-days ≈ a decision burst every few in-game days) and
  # converted to wall ms at this build's speedup — bots think at the same
  # game-relative rate regardless of SPEEDUP.
  defp start_bots(instance_id, model, game_data, opts) do
    policies = Keyword.get(opts, :policies, [Headless.Policies.Idle])
    interval_ut = Keyword.get(opts, :bot_interval_ut, 3)

    speed = Data.Querier.one(Data.Game.Speed, instance_id, String.to_existing_atom(game_data["speed"]))
    interval_ms = max(round(interval_ut * 180_000 / (speed.factor * Core.Tick.speedup())), 10)

    for {faction, idx} <- Enum.with_index(model.factions), reg <- faction.registrations do
      policy = Enum.at(policies, rem(idx, length(policies)))

      {:ok, pid} =
        Headless.Bot.start_link(
          instance_id: instance_id,
          player_id: reg.profile.id,
          policy: policy,
          interval_ms: interval_ms
        )

      {pid, faction.faction_ref, policy, reg.profile.id}
    end
  end

  # Each player's starting system ids, captured right after boot so end-state
  # ownership can be diffed into "colonies settled during the game".
  defp snapshot_initial_systems(instance_id, model) do
    for faction <- model.factions, reg <- faction.registrations, into: %{} do
      ids =
        case Game.call(instance_id, :player, reg.profile.id, :get_state) do
          {:ok, player} -> MapSet.new(player.stellar_systems, & &1.id)
          _ -> MapSet.new()
        end

      {reg.profile.id, ids}
    end
  end

  # Settled systems beyond the starting ones, scored by "strength" — the sum
  # of every body's prod/sci/appeal factors (industrial/technological/
  # activity). The matchup tie-breaker: rewards settling GOOD systems, not
  # just settling first.
  defp colonies_with_strength(instance_id, player_id, initial_systems) do
    initial = Map.get(initial_systems, player_id, MapSet.new())

    with {:ok, player} <- Game.call(instance_id, :player, player_id, :get_state) do
      player.stellar_systems
      |> Enum.reject(&MapSet.member?(initial, &1.id))
      |> Enum.map(fn %{id: id} ->
        strength =
          case Game.call(instance_id, :stellar_system, id, :get_state) do
            {:ok, system} -> system_strength(system)
            _ -> nil
          end

        %{system_id: id, strength: strength}
      end)
    else
      _ -> []
    end
  end

  defp system_strength(system) do
    system.bodies
    |> Headless.Policies.HomeDev.flatten_bodies()
    |> Enum.map(fn body ->
      Map.get(body, :industrial_factor, 0) + Map.get(body, :technological_factor, 0) +
        Map.get(body, :activity_factor, 0)
    end)
    |> Enum.sum()
  end

  # --- end detection -----------------------------------------------------------

  # The victory agent sets `winner` exactly once — on points (≥14 VP) or when
  # ut_time_left hits zero. Poll until then; the safety timeout covers a hung
  # instance (report :timeout rather than block forever).
  defp await_end(instance_id, poll_ms, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(instance_id, poll_ms, deadline)
  end

  defp do_await(instance_id, poll_ms, deadline) do
    case Game.call(instance_id, :victory, :master, :get_state) do
      {:ok, %{winner: winner} = victory} when not is_nil(winner) ->
        {:ended, victory}

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:timeout, safe_victory_state(instance_id)}
        else
          Process.sleep(poll_ms)
          do_await(instance_id, poll_ms, deadline)
        end
    end
  end

  defp safe_victory_state(instance_id) do
    case Game.call(instance_id, :victory, :master, :get_state) do
      {:ok, victory} -> victory
      _ -> nil
    end
  end

  # --- load sampling -----------------------------------------------------------

  # Cheap saturation telemetry, sampled twice a second for the whole run:
  #   * run_queue — total runnable processes across schedulers; sustained
  #     values ≫ core count mean the box can't keep up with this SPEEDUP.
  #   * memory / process_count — peaks, for parallel-game capacity planning.
  defp start_sampler do
    parent = self()

    pid =
      spawn_link(fn ->
        sample_loop(parent, %{max_run_queue: 0, sum_run_queue: 0, samples: 0, peak_mem: 0, peak_procs: 0})
      end)

    pid
  end

  defp sample_loop(parent, acc) do
    receive do
      {:stop, from} -> send(from, {:sampler_result, acc})
    after
      500 ->
        rq = :erlang.statistics(:run_queue)
        mem = :erlang.memory(:total)
        procs = :erlang.system_info(:process_count)

        sample_loop(parent, %{
          max_run_queue: max(acc.max_run_queue, rq),
          sum_run_queue: acc.sum_run_queue + rq,
          samples: acc.samples + 1,
          peak_mem: max(acc.peak_mem, mem),
          peak_procs: max(acc.peak_procs, procs)
        })
    end
  end

  defp stop_sampler(pid) do
    send(pid, {:stop, self()})

    receive do
      {:sampler_result, acc} ->
        %{
          max_run_queue: acc.max_run_queue,
          avg_run_queue: if(acc.samples > 0, do: Float.round(acc.sum_run_queue / acc.samples, 1), else: 0.0),
          peak_mem_mb: div(acc.peak_mem, 1024 * 1024),
          peak_procs: acc.peak_procs
        }
    after
      2_000 -> %{max_run_queue: nil, avg_run_queue: nil, peak_mem_mb: nil, peak_procs: nil}
    end
  end

  # --- report -------------------------------------------------------------------

  defp build_report(
         instance_id,
         {ended_or_timeout, victory},
         boot_ms,
         wall_ms,
         expected_wall_ms,
         load,
         bot_stats,
         destroy_ms,
         cpu
       ) do
    factions =
      case victory do
        %{factions: fs} -> Enum.map(fs, &%{key: &1.key, victory_points: &1.victory_points})
        _ -> []
      end

    %{
      instance_id: instance_id,
      result: ended_or_timeout,
      winner: victory && victory.winner,
      ut_time_left: victory && Float.round(victory.ut_time_left / 1, 1),
      factions: factions,
      boot_ms: boot_ms,
      wall_ms: wall_ms,
      destroy_ms: destroy_ms,
      expected_wall_ms: expected_wall_ms,
      cpu: cpu,
      speedup: Core.Tick.speedup(),
      load: load,
      bots: bot_stats
    }
  end

  # --- bot profiles ---------------------------------------------------------------

  @doc """
  Ensure `n` reusable bot accounts+profiles exist (headless-bot-1..n). Real DB
  rows so `Instance.Player.Player.new/4` sees a production-shaped profile;
  idempotent across runs.
  """
  def ensure_bot_profiles(n) when n > 0 do
    Enum.map(1..n, fn i ->
      email = "headless-bot-#{i}@#{@bot_email_domain}"
      name = "HeadlessBot#{i}"

      account =
        case Accounts.get_account_by_email(email) do
          {:ok, account} ->
            account

          {:error, _} ->
            case Accounts.create_account(%{
                   email: email,
                   password: "headless-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)),
                   name: name,
                   role: :user,
                   status: :active
                 }) do
              {:ok, account} ->
                account

              # Two concurrent runs raced the check-then-insert (the smoke
              # suite starts games simultaneously; the marathon's start
              # stagger only masked this) — the loser re-reads the winner's
              # row.
              {:error, _} ->
                {:ok, account} = Accounts.get_account_by_email(email)
                account
            end
        end

      case RC.Repo.get_by(Profile, account_id: account.id) do
        nil ->
          case Accounts.create_profile(%{account_id: account.id, name: name, avatar: "bot"}) do
            {:ok, profile} -> profile
            {:error, _} -> RC.Repo.get_by(Profile, account_id: account.id)
          end

        profile ->
          profile
      end
    end)
  end
end
