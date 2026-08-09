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

  describe "filter_stale_chat/3 serve-time chat hygiene" do
    alias Instance.Faction.ChatMessage

    defp system_line(message, timestamp) do
      %ChatMessage{from: "SYSTEM", from_id: nil, timestamp: timestamp, message: message}
    end

    defp player_line(message, timestamp) do
      %ChatMessage{from: "somePlayer", from_id: 42, timestamp: timestamp, message: message}
    end

    test "ongoing notice is served only while the deploy flag is up" do
      chat = [system_line(Deploy.ongoing_message(), 1_000)]

      assert Deploy.filter_stale_chat(chat, 2_000, true) == chat
      assert Deploy.filter_stale_chat(chat, 2_000, false) == []
    end

    test "finished notice is served only to sockets connected when it fired" do
      chat = [system_line(Deploy.finished_message(), 1_000)]

      # joined before (or at) the push: was connected through the deploy — keep
      assert Deploy.filter_stale_chat(chat, 900, false) == chat
      assert Deploy.filter_stale_chat(chat, 1_000, false) == chat

      # loaded the game after the deploy finished: already on new code — drop
      assert Deploy.filter_stale_chat(chat, 1_001, false) == []
    end

    test "a fresh post-deploy load sees neither notice, whatever the order" do
      chat = [
        player_line("hello", 500),
        system_line(Deploy.ongoing_message(), 1_000),
        system_line(Deploy.finished_message(), 1_100),
        player_line("gg", 1_200)
      ]

      assert Deploy.filter_stale_chat(chat, 2_000, false) == [
               player_line("hello", 500),
               player_line("gg", 1_200)
             ]
    end

    test "player messages quoting the notice text verbatim are never filtered" do
      chat = [
        player_line(Deploy.ongoing_message(), 1_000),
        player_line(Deploy.finished_message(), 1_000)
      ]

      assert Deploy.filter_stale_chat(chat, 2_000, false) == chat
    end

    test "other system lines pass through untouched" do
      chat = [system_line("CHEAT enabled for this game", 1_000)]

      assert Deploy.filter_stale_chat(chat, 2_000, false) == chat
    end
  end
end
