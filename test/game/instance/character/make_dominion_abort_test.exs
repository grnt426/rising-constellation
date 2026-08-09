defmodule Character.Actions.MakeDominionAbortTest do
  @moduledoc """
  Locks the under-attack unmark on conquest abort paths.

  `MakeDominion.start/2` marks the target dominion's owner
  (`dominions_under_attack` drives the red pulse on their side panel) and
  `finish/2` unmarks — but an in-progress conquest can also end without
  finishing: the Siderian's owner clears the action queue, or the
  Siderian is assassinated/converted/killed. Those paths route through
  `MakeDominion.unmark_if_interrupted/1`; without it the owner's dominion
  pulsed "under attack" forever (observed in prod: Preid, instance 49,
  ~10 hours after the attacker was gone).
  """

  use ExUnit.Case, async: true

  alias Instance.Character.Actions.MakeDominion
  alias Test.FleetScenario

  @system_id 344
  @owner_id 7

  defp owner_struct do
    %Instance.StellarSystem.Player{
      id: @owner_id,
      avatar: "",
      name: "owner",
      faction: :ark,
      faction_id: 1
    }
  end

  defp speaker_with_action(iid, action) do
    speaker =
      FleetScenario.build_character(
        character_id: 501,
        instance_id: iid,
        faction: :myrmezir,
        faction_id: 2,
        type: :speaker,
        has_ships?: false,
        system: @system_id
      )

    %{speaker | actions: %{speaker.actions | queue: Queue.insert(speaker.actions.queue, action)}}
  end

  setup do
    instance_id = FleetScenario.unique_instance_id()

    {_system, _pid} =
      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: instance_id,
        system_id: @system_id,
        owner: owner_struct(),
        status: :inhabited_dominion
      )

    {_player, player_pid} =
      FleetScenario.spawn_fake_player(self(),
        instance_id: instance_id,
        player_id: @owner_id,
        faction: :ark
      )

    {:ok, instance_id: instance_id, player_pid: player_pid}
  end

  test "a started make_dominion being dropped unmarks the dominion owner",
       %{instance_id: iid, player_pid: player_pid} do
    action = FleetScenario.build_action(:make_dominion, %{"target" => @system_id}, started_at: 123)
    MakeDominion.unmark_if_interrupted(speaker_with_action(iid, action))

    assert FleetScenario.get_under_attack_casts(player_pid) ==
             [{:unmark_dominion_under_attack, @system_id}]
  end

  test "a make_dominion that never started does not unmark (start/2 never marked)",
       %{instance_id: iid, player_pid: player_pid} do
    action = FleetScenario.build_action(:make_dominion, %{"target" => @system_id})
    MakeDominion.unmark_if_interrupted(speaker_with_action(iid, action))

    assert FleetScenario.get_under_attack_casts(player_pid) == []
  end

  test "other in-progress actions do not unmark", %{instance_id: iid, player_pid: player_pid} do
    action =
      FleetScenario.build_action(:jump, %{"source" => @system_id, "target" => 1}, started_at: 123)

    MakeDominion.unmark_if_interrupted(speaker_with_action(iid, action))

    assert FleetScenario.get_under_attack_casts(player_pid) == []
  end

  test "an empty action queue does not unmark", %{instance_id: iid, player_pid: player_pid} do
    speaker =
      FleetScenario.build_character(
        character_id: 501,
        instance_id: iid,
        faction: :myrmezir,
        faction_id: 2,
        type: :speaker,
        has_ships?: false,
        system: @system_id
      )

    MakeDominion.unmark_if_interrupted(speaker)

    assert FleetScenario.get_under_attack_casts(player_pid) == []
  end

  test "nil actions (governors, older snapshots) neither crash nor unmark",
       %{instance_id: iid, player_pid: player_pid} do
    # this helper runs inside player-agent handlers — a crash there resets
    # the player's state, so nil-tolerance is load-bearing
    speaker =
      FleetScenario.build_character(
        character_id: 501,
        instance_id: iid,
        faction: :myrmezir,
        faction_id: 2,
        type: :speaker,
        has_ships?: false,
        system: @system_id
      )

    assert :ok = MakeDominion.unmark_if_interrupted(%{speaker | actions: nil})
    assert FleetScenario.get_under_attack_casts(player_pid) == []
  end

  test "an unowned target system unmarks nobody", %{player_pid: player_pid} do
    iid = FleetScenario.unique_instance_id()

    {_system, _pid} =
      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: @system_id,
        owner: nil,
        status: :inhabited_neutral
      )

    action = FleetScenario.build_action(:make_dominion, %{"target" => @system_id}, started_at: 123)
    MakeDominion.unmark_if_interrupted(speaker_with_action(iid, action))

    assert FleetScenario.get_under_attack_casts(player_pid) == []
  end
end
