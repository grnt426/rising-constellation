defmodule Instance.Faction.FactionChatChannelsTest do
  use ExUnit.Case, async: true

  alias Instance.Faction.ChatMessage
  alias Instance.Faction.Faction
  alias Instance.Faction.Sighting
  alias Spatial.Position

  @moduledoc """
  Chat channels, the posts the game makes for a player (claims), and
  sightings (reported enemy fleets / agents). Pure Faction-module tests:
  no instance boot, no DB. The tick that follows a live sighting talks to
  other agents and is exercised in a running game instead.
  """

  @iid 999_999_886

  setup_all do
    Data.Data.insert(@iid, speed: :fast, mode: :prod)
    on_exit(fn -> Data.Data.clear(@iid) end)
    :ok
  end

  defp faction, do: Faction.new(%{id: 1, faction_ref: "myrmezir"}, @iid)

  defp blip(overrides \\ %{}) do
    Map.merge(
      %{
        faction: :cardan,
        character_id: 9,
        owner_player_id: 50,
        position: %Position{x: 10.0, y: 10.0},
        angle: 0.0,
        target_system_id: 4,
        target_position: %Position{x: 20.0, y: 10.0}
      },
      overrides
    )
  end

  # A system as the faction sees it (Faction.visible_system/2), cut down
  # to what report_agent/5 reads.
  defp system(characters) do
    %{id: 3, position: %Position{x: 1.0, y: 2.0}, characters: characters}
  end

  defp agent(overrides \\ %{}) do
    Map.merge(
      %{id: 7, type: :spy, name: "Vex", owner: %{id: 50, name: "Bob", faction: :cardan, faction_id: 2}},
      overrides
    )
  end

  describe "channels" do
    test "a message is filed under its channel, General by default" do
      state =
        faction()
        |> Faction.push_message("Alice", 1, "hello")
        |> Faction.push_message("Alice", 1, "need tech", "aid")

      assert [%{channel: "general", message: "hello"}, %{channel: "aid", message: "need tech"}] = state.chat
    end

    test "an unknown channel falls back to General" do
      state = Faction.push_message(faction(), "Alice", 1, "hello", "nonsense")
      assert [%{channel: "general"}] = state.chat
      refute ChatMessage.valid_channel?("nonsense")
    end

    test "messages are numbered in order, across channels" do
      state =
        faction()
        |> Faction.push_message("Alice", 1, "one")
        |> Faction.push_message("Alice", 1, "two", "ask")
        |> Faction.push_system_message("three")

      assert [1, 2, 3] = Enum.map(state.chat, & &1.id)
    end

    test "each channel keeps its own history: a busy one never evicts another's" do
      state = Faction.push_message(faction(), "Alice", 1, "taking Sol", "claims")

      state =
        Enum.reduce(1..200, state, fn i, acc ->
          Faction.push_message(acc, "Bob", 2, "chatter #{i}")
        end)

      assert Enum.count(state.chat, &(&1.channel == "general")) == 80
      assert [%{message: "taking Sol"}] = Enum.filter(state.chat, &(&1.channel == "claims"))
      # the survivors of the busy channel are its newest
      assert List.last(state.chat).message == "chatter 200"
    end

    test "a side channel is capped too" do
      state =
        Enum.reduce(1..70, faction(), fn i, acc ->
          Faction.push_message(acc, "Bob", 2, "q#{i}", "ask")
        end)

      asked = Enum.filter(state.chat, &(&1.channel == "ask"))
      assert length(asked) == 50
      assert hd(asked).message == "q21"
    end
  end

  describe "claims" do
    test "push_claim posts a system chip in Claims, marked as a claim" do
      state = Faction.push_claim(faction(), "Alice", 1, 123)

      assert [message] = state.chat
      assert message.channel == "claims"
      assert message.from_id == 1
      assert message.message == "[[sys:123]]"
      assert message.meta == %{"kind" => "claim", "system_id" => 123}
    end

    test "push_claim ignores a malformed call" do
      state = faction()
      assert ^state = Faction.push_claim(state, "Alice", nil, 123)
      assert ^state = Faction.push_claim(state, "Alice", 1, "123")
    end
  end

  describe "factions restored from a snapshot older than chat channels" do
    test "the ring is numbered and filed under General, the counters added" do
      old_message = fn text ->
        "Alice"
        |> ChatMessage.new(1, text)
        |> Map.drop([:id, :channel, :meta])
      end

      old =
        faction()
        |> Map.drop([:chat_seq, :sighting_seq, :sightings])
        |> Map.put(:chat, [old_message.("one"), old_message.("two")])

      state = Faction.ensure_chat_fields(old)

      assert [%{id: 1, channel: "general", meta: nil}, %{id: 2, channel: "general", meta: nil}] = state.chat
      assert state.chat_seq == 3
      assert state.sightings == []

      # and the next message carries on from there
      state = Faction.push_message(old, "Bob", 2, "three", "aid")
      assert [1, 2, 3] = Enum.map(state.chat, & &1.id)
    end

    test "an up-to-date faction is left untouched" do
      state = Faction.push_message(faction(), "Alice", 1, "hello")
      assert Faction.ensure_chat_fields(state) == state
    end
  end

  describe "reporting a fleet" do
    test "the blip nearest the reported point becomes a live sighting, announced in Spotted" do
      state = %{faction() | detected_objects: [blip()]}

      assert {:ok, state, sighting, :created} =
               Faction.report_fleet(state, 1, "Alice", %Position{x: 10.4, y: 9.8}, "cardan")

      assert %Sighting{kind: "fleet", status: "live", faction: "cardan", agent_type: "admiral"} = sighting
      assert sighting.character_id == 9
      assert sighting.system_id == 4
      assert sighting.position == %Position{x: 10.0, y: 10.0}
      assert sighting.reporter_id == 1

      assert [message] = state.chat
      assert message.channel == "spotted"
      assert message.from == "Alice"
      assert message.message == "[[spot:#{sighting.id}]]"
      assert message.meta == %{"kind" => "sighting", "sighting_id" => sighting.id}
      assert sighting.message_id == message.id
      assert state.sightings == [sighting]
    end

    test "a fleet with a live sighting is not reported twice" do
      state = %{faction() | detected_objects: [blip()]}
      point = %Position{x: 10.0, y: 10.0}

      {:ok, state, first, :created} = Faction.report_fleet(state, 1, "Alice", point, "cardan")
      assert {:ok, ^state, ^first, :duplicate} = Faction.report_fleet(state, 2, "Bob", point, "cardan")
      assert length(state.chat) == 1
    end

    test "nothing of that faction near the point: nothing to report" do
      state = %{faction() | detected_objects: [blip()]}

      assert {:error, :contact_lost} =
               Faction.report_fleet(state, 1, "Alice", %Position{x: 60.0, y: 60.0}, "cardan")

      assert {:error, :contact_lost} =
               Faction.report_fleet(state, 1, "Alice", %Position{x: 10.0, y: 10.0}, "synelle")
    end

    test "a faction-mate's fleet is not an enemy to report" do
      state = %{faction() | detected_objects: [blip(%{faction: :myrmezir})]}

      assert {:error, :contact_lost} =
               Faction.report_fleet(state, 1, "Alice", %Position{x: 10.0, y: 10.0}, "myrmezir")
    end

    test "of two fleets, the one closest to the point is taken" do
      near = blip(%{character_id: 21, position: %Position{x: 11.0, y: 10.0}})
      far = blip(%{character_id: 22, position: %Position{x: 13.0, y: 10.0}})
      state = %{faction() | detected_objects: [far, near]}

      assert {:ok, _state, %{character_id: 21}, :created} =
               Faction.report_fleet(state, 1, "Alice", %Position{x: 10.5, y: 10.0}, "cardan")
    end

    test "reports are rate limited per player" do
      blips = for i <- 1..11, do: blip(%{character_id: i, position: %Position{x: i * 20.0, y: 0.0}})
      state = %{faction() | detected_objects: blips}

      state =
        Enum.reduce(1..10, state, fn i, acc ->
          {:ok, acc, _sighting, :created} =
            Faction.report_fleet(acc, 1, "Alice", %Position{x: i * 20.0, y: 0.0}, "cardan")

          acc
        end)

      assert {:error, :report_rate_limited} =
               Faction.report_fleet(state, 1, "Alice", %Position{x: 220.0, y: 0.0}, "cardan")

      # another member is not held back by Alice's burst
      assert {:ok, _state, _sighting, :created} =
               Faction.report_fleet(state, 2, "Bob", %Position{x: 220.0, y: 0.0}, "cardan")
    end
  end

  describe "reporting an agent" do
    test "an enemy agent the faction sees in a system becomes a live sighting" do
      assert {:ok, state, sighting, :created} =
               Faction.report_agent(faction(), 1, "Alice", system([agent()]), 7)

      assert %Sighting{kind: "agent", status: "live", faction: "cardan", agent_type: "spy"} = sighting
      assert sighting.name == "Vex"
      assert sighting.owner == "Bob"
      assert sighting.system_id == 3
      assert sighting.position == %Position{x: 1.0, y: 2.0}
      assert [%{channel: "spotted", meta: %{"kind" => "sighting"}}] = state.chat
    end

    test "an agent the faction cannot see there cannot be reported" do
      # not in the list (left, or under cover)…
      assert {:error, :agent_not_visible} = Faction.report_agent(faction(), 1, "Alice", system([agent()]), 8)
      # …or no view of who stands in the system at all
      assert {:error, :agent_not_visible} = Faction.report_agent(faction(), 1, "Alice", system(nil), 7)
    end

    test "an agent of one's own faction is not reported" do
      mate = agent(%{owner: %{id: 60, name: "Carol", faction: :myrmezir, faction_id: 1}})
      assert {:error, :own_faction_agent} = Faction.report_agent(faction(), 1, "Alice", system([mate]), 7)
    end

    test "beyond the watch cap, the oldest watched agents stop being followed" do
      # each report from a different member: the cap under test is the
      # watch list's, not the per-player rate limit
      state =
        Enum.reduce(1..22, faction(), fn i, acc ->
          {:ok, acc, _sighting, :created} =
            Faction.report_agent(acc, i, "Member #{i}", system([agent(%{id: i})]), i)

          acc
        end)

      live = Enum.filter(state.sightings, &Sighting.live?/1)
      assert length(live) == 20
      assert Enum.map(live, & &1.character_id) == Enum.to_list(22..3//-1)

      assert [%{character_id: 2, reason: "untracked"}, %{character_id: 1, reason: "untracked"}] =
               Enum.reject(state.sightings, &Sighting.live?/1)
    end
  end

  describe "a sighting's life" do
    setup do
      state = %{faction() | detected_objects: [blip()]}
      {:ok, _state, sighting, :created} = Faction.report_fleet(state, 1, "Alice", %Position{x: 10.0, y: 10.0}, "cardan")
      %{sighting: sighting}
    end

    test "a fleet still on its leg is followed", %{sighting: sighting} do
      moved = blip(%{position: %Position{x: 14.0, y: 10.0}})

      assert %Sighting{status: "live", position: %Position{x: 14.0, y: 10.0}} = Sighting.track_fleet(sighting, moved)
    end

    test "a fleet seen on another leg has reached where it was going", %{sighting: sighting} do
      onward = blip(%{target_system_id: 5, position: %Position{x: 21.0, y: 11.0}})
      lost = Sighting.track_fleet(sighting, onward)

      assert %Sighting{status: "lost", reason: "arrived"} = lost
      # the chip now leads to the destination it reached
      assert lost.position == %Position{x: 20.0, y: 10.0}
      assert is_integer(lost.lost_at)
    end

    test "an unreadable leg proves nothing", %{sighting: sighting} do
      unknown = blip(%{target_system_id: nil, target_position: nil})
      assert %Sighting{status: "live"} = Sighting.track_fleet(sighting, unknown)
    end

    test "lost is final", %{sighting: sighting} do
      lost = Sighting.lose(sighting, "out_of_range")
      assert %Sighting{status: "lost", reason: "out_of_range"} = lost
      assert Sighting.lose(lost, "arrived") == lost
    end

    test "who a fleet sighting really is never reaches a client", %{sighting: sighting} do
      encoded = sighting |> Jason.encode!() |> Jason.decode!()

      refute Map.has_key?(encoded, "character_id")
      refute Map.has_key?(encoded, "target_position")
      assert %{"kind" => "fleet", "status" => "live", "faction" => "cardan", "system_id" => 4} = encoded
    end
  end
end
