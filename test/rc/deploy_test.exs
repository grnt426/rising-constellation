defmodule RC.DeployTest do
  use RC.DataCase

  alias RC.Deploy

  @moduledoc """
  Deployment-notice flag: DB log persistence + flag lifecycle. The
  Portal.Config cache and channel broadcast sides are exercised
  implicitly (they no-op harmlessly when the cache/endpoint audience is
  empty); the durable DB truth is what must survive the mid-deploy
  restart, so that is what we pin here.
  """

  test "flag defaults to false with an empty log" do
    assert Deploy.get_flag_from_db() == false
  end

  test "set_flag persists an append-only log row" do
    assert {:ok, _} = Deploy.set_flag(true, "test")
    assert Deploy.get_flag_from_db() == true

    assert {:ok, _} = Deploy.set_flag(false, "test")
    assert Deploy.get_flag_from_db() == false

    # Append-only: both rows kept, newest wins.
    assert Repo.aggregate(RC.Deploy.Log, :count) == 2
  end

  test "start/finish/clear lifecycle drives the flag" do
    assert :ok = Deploy.start_deploy("test")
    assert Deploy.get_flag_from_db() == true

    assert :ok = Deploy.finish_deploy("test")
    assert Deploy.get_flag_from_db() == false

    assert :ok = Deploy.start_deploy("test")
    assert :ok = Deploy.clear_deploy("discord:123")
    assert Deploy.get_flag_from_db() == false
  end

  test "source is recorded on the log row" do
    assert {:ok, log} = Deploy.set_flag(true, "discord:42")
    assert log.source == "discord:42"
    assert log.flag == true
  end

  test "changeset rejects a missing source" do
    changeset = RC.Deploy.Log.changeset(%RC.Deploy.Log{}, %{flag: true})
    refute changeset.valid?
  end
end
