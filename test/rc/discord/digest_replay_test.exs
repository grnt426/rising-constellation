defmodule RC.Discord.DigestReplayTest do
  @moduledoc """
  The deploy-loss hardening for the 6-hour digest: on relay boot the
  current window is rebuilt from `player_events`. Covers the pure
  row → `{bulletin_key, payload}` mapping and the replay query's
  filters (window boundary, discord_ready, ended instances, global
  rows, digest-feed keys, per-instance cap).
  """

  use RC.DataCase

  import RC.ScenarioFixtures

  alias RC.Discord.DigestReplay
  alias RC.Instances.Instance
  alias RC.Instances.PlayerEvent
  alias RC.Repo

  # A prod-shaped moment: deploy at 17:59:04 UTC, boundary at 18:00 —
  # the window under replay opened at 12:00.
  @now ~U[2026-08-11 17:59:04Z]
  @window_start ~U[2026-08-11 12:00:00Z]

  describe "replay_event/2 — row mapping" do
    test "maps the colonize first back to the every-event Discord kind" do
      data =
        Jason.encode!(%{
          faction: "ark",
          player_name: "Nova",
          system_name: "Mardir",
          system_id: 4,
          sector_id: 2,
          sector_name: "Azurie"
        })

      assert {:ok, {"discord.colonized", payload}} = DigestReplay.replay_event("news.colonize.first", data)

      assert payload == %{
               faction: "ark",
               player_name: "Nova",
               system_name: "Mardir",
               system_id: 4,
               sector_id: 2,
               sector_name: "Azurie"
             }
    end

    test "maps the dominion first, keeping an explicit null prev_faction" do
      data = Jason.encode!(%{faction: "ark", system_name: "Zaproron", system_id: 9, prev_faction: nil})

      assert {:ok, {"discord.dominion", payload}} = DigestReplay.replay_event("news.dominion.first", data)
      assert payload[:prev_faction] == nil
      assert Map.has_key?(payload, :prev_faction)
    end

    test "digest-feed keys pass through under their own key" do
      for key <- [
            "news.dominion.liberated",
            "news.system.abandoned",
            "news.sector.claimed",
            "news.sector.lost",
            "news.sector.flipped"
          ] do
        data = Jason.encode!(%{faction: "synelle", prev_faction: "ark", sector_name: "Azurie"})

        assert {:ok, {^key, %{faction: "synelle", prev_faction: "ark", sector_name: "Azurie"}}} =
                 DigestReplay.replay_event(key, data)
      end
    end

    test "drops fields outside the payload whitelist" do
      data = Jason.encode!(%{faction: "ark", system_name: "Mardir", winning_faction_id: 3, surprise: "x"})

      assert {:ok, {_key, payload}} = DigestReplay.replay_event("news.colonize.first", data)
      assert Map.keys(payload) |> Enum.sort() == [:faction, :system_name]
    end

    test "skips non-digest keys and undecodable data" do
      assert :skip = DigestReplay.replay_event("news.battle", Jason.encode!(%{faction: "ark"}))
      assert :skip = DigestReplay.replay_event("news.colonize.first", "not json{")
      assert :skip = DigestReplay.replay_event("news.colonize.first", Jason.encode!([1, 2]))
    end
  end

  describe "rebuild/1 — replay query" do
    test "rebuilds the window for a discord_ready instance, in insertion order" do
      instance = ready_instance()

      insert_event!(instance, "news.colonize.first", %{faction: "ark", system_name: "Mardir", system_id: 4}, @now)

      insert_event!(
        instance,
        "news.sector.flipped",
        %{faction: "ark", prev_faction: "synelle", sector_name: "Azurie"},
        @now
      )

      result = DigestReplay.rebuild(now: @now)
      assert Map.keys(result) == [instance.id]
      assert %{count: 2, events: events} = result[instance.id]

      assert [
               {"discord.colonized", %{faction: "ark", system_name: "Mardir", system_id: 4}},
               {"news.sector.flipped", %{faction: "ark", prev_faction: "synelle", sector_name: "Azurie"}}
             ] = events
    end

    test "excludes rows from before the window boundary" do
      instance = ready_instance()

      insert_event!(instance, "news.system.abandoned", %{faction: "ark"}, DateTime.add(@window_start, -1, :second))
      insert_event!(instance, "news.system.abandoned", %{faction: "ark"}, @window_start)

      assert %{count: 1} = DigestReplay.rebuild(now: @now)[instance.id]
    end

    test "excludes non-global rows and non-digest keys" do
      instance = ready_instance()

      insert_event!(instance, "news.colonize.first", %{faction: "ark"}, @now, "player")
      insert_event!(instance, "news.battle", %{faction: "ark"}, @now)
      insert_event!(instance, "news.raid", %{faction: "ark"}, @now)

      assert DigestReplay.rebuild(now: @now) == %{}
    end

    test "excludes instances that are not discord_ready" do
      %{instance: instance} = instance_fixture()

      insert_event!(instance, "news.colonize.first", %{faction: "ark"}, @now)

      assert DigestReplay.rebuild(now: @now) == %{}
    end

    test "excludes ended instances" do
      instance = ready_instance()
      set_state!(instance, "ended")

      insert_event!(instance, "news.colonize.first", %{faction: "ark"}, @now)

      assert DigestReplay.rebuild(now: @now) == %{}
    end

    test "caps the window at max_events" do
      instance = ready_instance()

      for i <- 1..3 do
        insert_event!(instance, "news.colonize.first", %{faction: "ark", system_id: i}, @now)
      end

      assert %{count: 2, events: [_, _]} = DigestReplay.rebuild(now: @now, max_events: 2)[instance.id]
    end
  end

  defp ready_instance do
    %{instance: instance} = instance_fixture()

    Instance
    |> Repo.get!(instance.id)
    |> Ecto.Changeset.change(discord_ready: true)
    |> Repo.update!()
  end

  defp set_state!(instance, state) do
    Instance
    |> Repo.get!(instance.id)
    |> Ecto.Changeset.change(state: state)
    |> Repo.update!()
  end

  # Direct struct insert so inserted_at can sit exactly where the test
  # needs it relative to the window boundary.
  defp insert_event!(instance, key, payload, inserted_at, type \\ "global") do
    Repo.insert!(%PlayerEvent{
      type: type,
      key: key,
      data: Jason.encode!(payload),
      instance_id: instance.id,
      inserted_at: DateTime.truncate(inserted_at, :second)
    })
  end
end
