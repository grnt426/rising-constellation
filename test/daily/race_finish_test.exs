defmodule Daily.RaceFinishTest do
  @moduledoc """
  Integration test for the race-completion end-of-run flow (the Shareels bug:
  completing a race goal recorded the score silently and let the timer run
  out).

  Boots a REAL persisted daily (scenario + instance + registration rows, live
  supervision tree) for the first upcoming race-objective date, then feeds
  `Daily.Boot.race_tick/2` a player doctored to satisfy the goal — the same
  entry point the player agent's push-point checks use. Asserts the full
  sequence the fix wires up:

    1. the score (seconds left at completion) is recorded on the leaderboard,
    2. the Victory agent declares a winner via :force_time_up (natural
       win_on_time path),
    3. finalize freezes the sim (time agent stopped),
    4. a `daily_result` payload (reason race_won, rank, seconds_left) is
       broadcast on the instance's global channel for the client banner.
  """
  use RC.DataCase, async: false

  # A live boot + graceful teardown is slow but bounded.
  @moduletag timeout: 180_000

  test "completing a race objective ends the run: score, victory, freeze, result broadcast" do
    {profile, _account} = create_profile()
    {date_iso, objective} = first_race_date()

    {:ok, %{instance_id: iid}} = Daily.Boot.boot_persisted(profile, date_iso)
    on_exit(fn -> Instance.Manager.destroy(iid) end)

    Portal.Endpoint.subscribe(Portal.Controllers.GlobalChannel.topic(iid))

    # Start the clock (normally done on first client connect).
    {:ok, :started, _} = Instance.Manager.call(iid, :start)

    {:ok, player} = Game.call(iid, :player, profile.id, :get_state)
    doctored = satisfy_race(player, objective)

    flagged = Daily.Boot.race_tick(iid, doctored)
    assert Map.get(flagged, :daily_race_won) == true

    # 1. Score recorded (async task): seconds left at completion, rank 1.
    %{score: score, rank: rank} =
      eventually(fn ->
        case Daily.player_rank(profile.id, date_iso) do
          %{score: score} = best when score > 0 -> {:ok, best}
          _ -> :retry
        end
      end)

    assert score > 0
    assert rank == 1

    # 4. Result banner payload on the global channel.
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "broadcast",
                     payload: %{daily_result: result}
                   },
                   10_000

    assert result.reason == "race_won"
    assert result.rank == 1
    assert result.seconds_left > 0
    assert result.time_limit_seconds == Daily.Generator.time_limit_minutes() * 60

    # 2. The Victory agent declared a winner through the natural time-up path.
    eventually(fn ->
      case Game.call(iid, :victory, :master, :get_state) do
        {:ok, %{winner: winner}} when not is_nil(winner) -> {:ok, winner}
        _ -> :retry
      end
    end)

    # 3. finalize froze the sim — the time agent is no longer running.
    eventually(fn ->
      case Game.call(iid, :time, :master, :get_state) do
        {:ok, %{is_running: false}} -> {:ok, :frozen}
        _ -> :retry
      end
    end)

    # The recorded entry is the race win, not a deadline re-record: keep-best
    # kept the positive seconds-left score through finalize's 0-score upsert.
    assert %{score: ^score} = Daily.player_rank(profile.id, date_iso)
  end

  test "deadline (no race win) freezes, records, and broadcasts the time_up result" do
    {profile, _account} = create_profile()
    {date_iso, _objective} = first_race_date()

    {:ok, %{instance_id: iid}} = Daily.Boot.boot_persisted(profile, date_iso)
    on_exit(fn -> Instance.Manager.destroy(iid) end)

    Portal.Endpoint.subscribe(Portal.Controllers.GlobalChannel.topic(iid))
    {:ok, :started, _} = Instance.Manager.call(iid, :start)

    # Hit the deadline without completing the goal — the same path the real
    # 30-minute expiry takes through check_for_victory's win_on_time branch.
    Game.cast(iid, :victory, :master, :force_time_up)

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "broadcast",
                     payload: %{daily_result: result}
                   },
                   10_000

    assert result.reason == "time_up"
    assert result.mode == :race
    assert result.rank == 1

    # DNF on a race day scores 0 — but the entry exists and ranks.
    assert %{score: 0.0, rank: 1} = Daily.player_rank(profile.id, date_iso)

    eventually(fn ->
      case Game.call(iid, :time, :master, :get_state) do
        {:ok, %{is_running: false}} -> {:ok, :frozen}
        _ -> :retry
      end
    end)
  end

  # --- helpers --------------------------------------------------------------

  defp create_profile do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "race-finish-test@tetrarchyfalls.local",
        password: "race-finish-test-password",
        name: "RaceFinisher",
        role: :user,
        status: :active
      })

    {:ok, profile} =
      RC.Accounts.create_profile(%{account_id: account.id, name: "RaceFinisher", avatar: "todo"})

    {profile, account}
  end

  # The first date from today whose daily is a race objective (any race shape
  # works — satisfy_race/2 dispatches on it). The rotation mixes ~19
  # objectives of which 6 are races, so a hit lands within a few days.
  defp first_race_date do
    Enum.find_value(0..60, fn offset ->
      date_iso = Date.utc_today() |> Date.add(offset) |> Date.to_iso8601()

      case Daily.definition_for(date_iso) do
        %{objective: %{mode: :race} = objective} -> {date_iso, objective}
        _ -> nil
      end
    end) || flunk("no race objective within 60 days — rotation broken?")
  end

  # Doctor the live player so the objective's goal predicate holds, per race
  # shape (see Daily.Objective.race_progress/2).
  defp satisfy_race(player, %{race: %{army: spec}}) do
    [{metric, target}] = Enum.to_list(spec)

    field =
      case metric do
        :raid -> :army_raid
        :invasion -> :army_invasion
        :maintenance -> :army_maintenance
      end

    admiral = Map.put(%{type: :admiral, status: :on_board}, field, target * 2)
    %{player | characters: [admiral]}
  end

  defp satisfy_race(player, %{race: %{patent: key}}), do: Map.put(player, :patents, [key])

  defp satisfy_race(player, %{race: %{wonder: key}}), do: Map.put(player, :wonders_built, [key])

  defp satisfy_race(player, %{race: %{system_income: thresholds}}) do
    system = Map.new(thresholds, fn {field, target} -> {field, target * 2} end)
    %{player | stellar_systems: [system]}
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      {:ok, value} ->
        value

      :retry when tries > 0 ->
        Process.sleep(100)
        eventually(fun, tries - 1)

      :retry ->
        flunk("condition not met in time")
    end
  end
end
