defmodule Player.RecallUnderAttackMarkTest do
  @moduledoc """
  Recalling a Siderian in the middle of a Control (`{:deactivate_character, _}`
  on `Instance.Player.Agent`) and the target owner's under-attack mark.

  `MakeDominion.start/2` marks the target dominion for its owner
  (`dominions_under_attack`, the red pulse on their side panel). A recall
  kills the agent, so the recall handler lifts that mark through
  `MakeDominion.unmark_if_interrupted/1`. It used to lift it before it knew
  whether the recall was allowed. A busy agent cannot be recalled: the recall
  was refused, the Control went on, and the owner's warning was gone. A
  player could hide a running Control by asking for a recall the game was
  bound to refuse.

  The mark is lifted only by a recall that goes through.

  The tests call the real `Instance.Player.Agent` handler with a hand-built
  state (tick not running, so the tick decorator is a no-op). The Siderian's
  agent, the target dominion and its owner are `Test.FleetScenario` stand-ins.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Speaker
  alias Instance.Player.Agent, as: PlayerAgent
  alias Instance.Player.Player
  alias Test.FleetScenario

  # the victim's dominion, where the Control runs
  @target 344
  @victim 7
  @attacker 42
  @siderian 501

  # `metadata` is the instance metadata on top of the game content, for the
  # "recall from anywhere" cheat.
  defp world(metadata \\ []) do
    iid = FleetScenario.unique_instance_id()
    FleetScenario.load_game_data(iid, [speed: :fast, mode: :dev] ++ metadata)
    # a recalled agent leaves the map
    FleetScenario.spawn_spatial(self(), instance_id: iid)

    FleetScenario.spawn_fake_stellar_system(self(),
      instance_id: iid,
      system_id: @target,
      status: :inhabited_dominion,
      owner: %Instance.StellarSystem.Player{id: @victim, avatar: "", name: "victim", faction: :ark, faction_id: 1}
    )

    {_player, victim} = FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: @victim, faction: :ark)

    %{iid: iid, victim: victim}
  end

  # The attacker's Siderian in the target dominion, its Control started.
  defp siderian(iid, action_status) do
    control = FleetScenario.build_action(:make_dominion, %{"target" => @target}, started_at: 123)

    character =
      FleetScenario.build_character(
        character_id: @siderian,
        instance_id: iid,
        faction: :myrmezir,
        faction_id: 2,
        owner_id: @attacker,
        type: :speaker,
        has_ships?: false,
        system: @target,
        action_status: action_status
      )

    %{
      character
      | speaker: Speaker.new(),
        on_sold: false,
        actions: %{character.actions | queue: Queue.insert(character.actions.queue, control)}
    }
  end

  # A stand-in agent is enough for a recall that is refused: it only has to
  # answer :get_state.
  defp spawn_stand_in(character) do
    {:ok, pid} =
      GenServer.start_link(FleetScenario.FakeCharacter, character,
        name: Game.via_tuple({character.instance_id, :character, character.id})
      )

    on_exit(fn -> Process.exit(pid, :shutdown) end)
    pid
  end

  # A recall that goes through stops the agent through the instance
  # supervisor, so this one is a real agent under a real supervisor. It is
  # never started: it answers calls and does not tick.
  defp spawn_supervised(character) do
    iid = character.instance_id
    supervisor = FleetScenario.spawn_instance_supervisor(self(), instance_id: iid)
    gen_state = Core.GenState.new(:character, iid, character.id, character, "test:recall-mark:character:#{iid}")

    {:ok, pid} = DynamicSupervisor.start_child(supervisor, {Instance.Character.Agent, state: gen_state})
    pid
  end

  defp agent_state(iid) do
    %{
      tick: %{running?: false},
      instance_id: iid,
      data: attacker(iid),
      channel: "test:recall-mark:#{iid}"
    }
  end

  defp recall(iid), do: PlayerAgent.on_call({:deactivate_character, @siderian}, nil, agent_state(iid))

  test "a recall refused because the Siderian is away from home leaves the mark", %{} do
    %{iid: iid, victim: victim} = world()
    spawn_stand_in(siderian(iid, :make_dominion))

    assert {:reply, {:error, :character_not_at_home}, _state} = recall(iid)
    assert FleetScenario.get_under_attack_casts(victim) == []
  end

  test "a recall refused because the Siderian is busy leaves the mark", %{} do
    # "recall from anywhere" lifts the home rule, so the busy rule answers
    %{iid: iid, victim: victim} = world(cheats_enabled: true, cheat_recall_anywhere: true)
    spawn_stand_in(siderian(iid, :make_dominion))

    assert {:reply, {:error, :character_must_be_idle}, _state} = recall(iid)
    assert FleetScenario.get_under_attack_casts(victim) == []
  end

  test "a recall that goes through lifts the mark of the Control it cuts short", %{} do
    # No rule lets a recall cut a Control short today: a Siderian with a
    # started Control is busy. The state is built by hand (idle, the started
    # Control still at the head of its queue) to hold the backstop in place.
    %{iid: iid, victim: victim} = world(cheats_enabled: true, cheat_recall_anywhere: true)
    agent = spawn_supervised(siderian(iid, :idle))

    assert {:reply, %Player{} = player, _state} = recall(iid)

    assert player.characters == []
    assert [%{character: %{id: @siderian, status: :in_deck}}] = player.character_deck
    refute Process.alive?(agent)
    assert FleetScenario.get_under_attack_casts(victim) == [{:unmark_dominion_under_attack, @target}]
  end

  defp res(value), do: %Core.DynamicValue{value: value, details: %{}, change: 0}

  # A whole player: a recall that goes through recomputes its bonuses.
  defp attacker(iid) do
    %Player{
      id: @attacker,
      account_id: @attacker,
      faction_id: 2,
      faction: :myrmezir,
      is_dead: false,
      is_bankrupt: false,
      is_active: true,
      avatar: "",
      name: "attacker",
      stellar_systems: [],
      dominions: [],
      characters: [%{id: @siderian, type: :speaker}],
      credit: res(1_000),
      technology: res(1_000),
      ideology: res(1_000),
      patents: [],
      doctrines: [],
      policies: [],
      character_deck: [],
      max_policies: 1,
      update_policies_count: 1,
      policies_cooldown: Core.CooldownValue.new(),
      max_systems: Core.Value.new(),
      max_dominions: Core.Value.new(),
      max_admirals: Core.Value.new(),
      max_spies: Core.Value.new(),
      max_speakers: Core.Value.new(),
      dominion_rate: Core.Value.new(),
      transformed_system_count: 0,
      dominions_under_attack: [],
      instance_id: iid,
      registration_id: @attacker,
      connected_clients: 0,
      pending_notifications: [],
      next_stats: 0,
      last_connection: Core.DynamicValue.new(0)
    }
  end
end
