defmodule Edict.LiveTest do
  @moduledoc """
  A scenario script driving a real game: boots a persisted single-player
  instance from a script (`Edict.Live.boot/2`, the workshop's Playtest),
  starts its clock and runs the script's runner pass by pass. Checks that the
  script's setup reached the engine (grants, discounts, the rival court),
  that its actions land through the engine's own calls (resources, an enemy
  agent, a plain-text message), that finish() ends the run with the script's
  score, and that a scripted run never writes to the daily leaderboard.
  """
  use RC.DataCase, async: false

  @moduletag timeout: 180_000

  @script """
  setup {
    name = "Live test"
    time_limit = 10m
    grant_patents = ["shipyard_2"]
    patent_discounts = {capital_1: 20%}
    rival = true
  }

  var pulses = 0

  score player.credit

  on start {
    give("credit", 12345)
    notify("hello <b>live</b> [x](javascript:alert(1))", tone: "good")
    send_agent("erased", level: 3)
  }

  every 1s {
    pulses = pulses + 1
  }

  when pulses >= 2 {
    finish("done")
  }
  """

  test "a script runs a live game from setup to finish" do
    {profile, _} = create_profile()

    {:ok, %{instance_id: iid}} = Edict.Live.boot(profile, @script)
    on_exit(fn -> Instance.Manager.destroy(iid) end)
    Portal.Endpoint.subscribe(Portal.Controllers.GlobalChannel.topic(iid))
    {:ok, :started, _} = Instance.Manager.call(iid, :start)

    # the instance (seen in lobbies and admin lists) carries no script text
    assert %{name: "Scenario playtest", description: "Scenario playtest"} = RC.Instances.get_instance(iid)

    # setup reached the engine
    assert Instance.Mutators.daily_scripted?(iid)
    {:ok, before} = Game.call(iid, :player, profile.id, :get_state)
    assert :shipyard_2 in before.patents
    assert Instance.Player.Player.patent_discounts(iid) == %{capital_1: 0.2}
    assert is_binary(Instance.Mutators.daily_puppet_faction(iid))

    # first pass: on start fires
    {:ok, state} = Edict.Live.init(iid)
    assert state.puppet_id
    {:cont, state} = Edict.Live.pulse(state)

    {:ok, player} = Game.call(iid, :player, profile.id, :get_state)
    assert player.credit.value >= before.credit.value + 12_000

    assert_receive %Phoenix.Socket.Broadcast{payload: %{scenario_message: %{text: text, tone: "good"}}}, 5_000
    # plain text, cleaned: what the client shows is exactly this string
    assert text == "hello <b>live</b> [x](javascript:alert(1))"

    [home | _] = player.stellar_systems
    {:ok, puppet} = Game.call(iid, :player, state.puppet_id, :get_state)
    assert Enum.any?(puppet.characters, &(&1.type == :spy and &1.level == 3 and &1.system == home.id))
    assert length(state.minted) == 1

    # the script's state lives across passes; finish() ends the run
    Process.sleep(1_100)
    {:cont, state} = Edict.Live.pulse(state)
    assert state.rt.globals["pulses"] >= 1.0
    Process.sleep(1_100)

    result =
      case Edict.Live.pulse(state) do
        {:finished, _} -> :finished
        {:cont, state} -> Process.sleep(1_100) && elem(Edict.Live.pulse(state), 0)
      end

    assert result == :finished

    assert_receive %Phoenix.Socket.Broadcast{payload: %{daily_result: banner}}, 10_000
    assert banner.reason == "scenario"
    assert banner.ended == "finished"
    assert banner.message == "done"
    assert banner.return_to == "/scenario-workshop"
    assert banner.run_score >= 12_000

    # the clock stopped the way a won race stops it
    eventually(fn ->
      case Game.call(iid, :victory, :master, :get_state) do
        {:ok, %{winner: winner}} when not is_nil(winner) -> {:ok, winner}
        _ -> :retry
      end
    end)

    # a playtest never touches the daily leaderboard
    assert RC.Repo.aggregate(Daily.Entry, :count) == 0
  end

  test "a script with errors doesn't boot" do
    {profile, _} = create_profile()
    assert {:error, [%{message: message} | _]} = Edict.Live.boot(profile, "score player.credt")
    assert message =~ "did you mean credit"
    assert {:error, [_ | _]} = Edict.Live.boot(profile, "score (")
  end

  test "catalog dailies still read their grants from the objective" do
    # the setup seam falls back to Daily.Objective when there's no script
    assert Instance.Mutators.daily_setup(-1) == nil
    refute Instance.Mutators.daily_scripted?(-1)
    assert Instance.Mutators.daily_granted_patents(-1) == []
  end

  defp create_profile do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "edict-live-#{System.unique_integer([:positive])}@tetrarchyfalls.local",
        password: "edict-live-test-password",
        name: "EdictLive",
        role: :user,
        status: :active
      })

    {:ok, profile} = RC.Accounts.create_profile(%{account_id: account.id, name: "EdictLive", avatar: "todo"})
    {profile, account}
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
