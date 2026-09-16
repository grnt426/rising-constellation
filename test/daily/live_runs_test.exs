defmodule Daily.LiveRunsTest do
  @moduledoc """
  `Daily.Boot.live_runs/1` — the deploy drain's notion of "a restart would
  interrupt this daily". Boots a REAL persisted daily and walks it through
  the lifecycle: booted-not-connected (live within the pre-connect grace,
  abandoned after), clock ticking (live, ~30 min left), finalized (not live).
  """
  use RC.DataCase, async: false

  @moduletag timeout: 180_000

  test "a daily is live from boot until it finalizes" do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "live-runs-test@tetrarchyfalls.local",
        password: "live-runs-test-password",
        name: "Drainer",
        role: :user,
        status: :active
      })

    {:ok, profile} = RC.Accounts.create_profile(%{account_id: account.id, name: "Drainer", avatar: "todo"})

    {:ok, %{instance_id: iid}} = Daily.Boot.boot_persisted(profile)
    on_exit(fn -> Instance.Manager.destroy(iid) end)

    # Booted, browser still loading: the clock hasn't started, but it's live.
    assert [%{instance_id: ^iid, started: false}] = Daily.Boot.live_runs()

    # Never connected well past the grace window: abandoned, not worth waiting on.
    assert Daily.Boot.live_runs(DateTime.add(DateTime.utc_now(), 3600, :second)) == []

    # Clock ticking: live regardless of age, with the full session ahead.
    {:ok, :started, _} = Instance.Manager.call(iid, :start)
    later = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert [%{instance_id: ^iid, started: true, seconds_left: left}] = Daily.Boot.live_runs(later)

    limit = Daily.Generator.time_limit_minutes() * 60
    assert left > limit - 60 and left <= limit

    # Deadline reached: a winner is declared, nothing left to protect.
    Game.cast(iid, :victory, :master, :force_time_up)
    eventually(fn -> if Daily.Boot.live_runs() == [], do: {:ok, :drained}, else: :retry end)

    output = ExUnit.CaptureIO.capture_io(fn -> RC.Deploy.daily_drain_status() end)
    assert output =~ "daily_drain live=0 "
  end

  test "a live daily shows up in the deploy script's drain line" do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "live-runs-line@tetrarchyfalls.local",
        password: "live-runs-test-password",
        name: "Liner",
        role: :user,
        status: :active
      })

    {:ok, profile} = RC.Accounts.create_profile(%{account_id: account.id, name: "Liner", avatar: "todo"})

    {:ok, %{instance_id: iid}} = Daily.Boot.boot_persisted(profile)
    on_exit(fn -> Instance.Manager.destroy(iid) end)
    {:ok, :started, _} = Instance.Manager.call(iid, :start)

    output = ExUnit.CaptureIO.capture_io(fn -> RC.Deploy.daily_drain_status() end)
    assert output =~ ~r/^daily_drain live=1 max_seconds_left=\d+ ids=#{iid}\n$/
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
