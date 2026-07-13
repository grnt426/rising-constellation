defmodule Instance.StellarSystem.OwnerNotificationTest do
  @moduledoc """
  Locks the owner-notification contract on the stellar system agent's
  character handlers.

  The `Player.StellarSystem` snapshot (which feeds the side-panel agent
  dots and the governor display) is only as fresh as the
  `{:update_system | :update_dominion, data}` casts the system agent
  sends its owner. Before this contract existed, push/remove/
  update_character mutated the system silently and a foreign agent
  could leave a quiet system while its dot lingered forever (observed
  in prod: instance 49, system Alvar).

  Every departure flavor funnels through the same three handlers, so
  these tests cover them all by proxy:

    * jump-out           -> {:remove_character, _, :on_board}
    * fleet-battle death -> Fight.kill_character -> remove_character
    * assassination      -> Player.Agent assassinate -> remove_character
    * recall/deactivate  -> Player.Agent deactivate -> remove_character
    * seduction          -> assassinate (remove) + convert (push, new owner)
    * spy exposure       -> {:update_character, _}

  The tests call the real `Instance.StellarSystem.Agent` handlers
  directly with a hand-built `Core.GenState` (tick not running, so the
  `@decorate tick()` next_tick wrapper is a no-op) and assert on the
  casts observed by a `Test.FleetScenario.FakePlayer` registered under
  the owner's registry slot.
  """

  use ExUnit.Case, async: true

  alias Instance.StellarSystem.Agent, as: SystemAgent
  alias Instance.StellarSystem.StellarSystem
  alias Test.FleetScenario

  defp spawn_owner(instance_id, player_id, faction) do
    {_player, pid} =
      FleetScenario.spawn_fake_player(self(),
        instance_id: instance_id,
        player_id: player_id,
        faction: faction
      )

    pid
  end

  defp build_system(instance_id, system_id, opts) do
    owner = Keyword.get(opts, :owner)

    struct(StellarSystem, %{
      id: system_id,
      instance_id: instance_id,
      name: "sys-#{system_id}",
      status: Keyword.get(opts, :status, :inhabited_player),
      owner: owner,
      characters: Keyword.get(opts, :characters, []),
      siege: nil
    })
  end

  defp owner_struct(player_id, faction, faction_id) do
    %Instance.StellarSystem.Player{
      id: player_id,
      avatar: "",
      name: "player-#{player_id}",
      faction: faction,
      faction_id: faction_id
    }
  end

  defp gen_state(instance_id, system) do
    %Core.GenState{
      type: :stellar_system,
      instance_id: instance_id,
      speed: :fast,
      agent_id: system.id,
      data: system,
      channel: "test",
      tick: %Core.Tick{time: 0, factor: 1},
      kill: false
    }
  end

  defp foreign_character(instance_id, character_id, system_id, opts \\ []) do
    FleetScenario.build_character(
      Keyword.merge(
        [
          character_id: character_id,
          instance_id: instance_id,
          faction: :myrmezir,
          faction_id: 2,
          system: system_id,
          type: :speaker,
          has_ships?: false
        ],
        opts
      )
    )
  end

  defp character_ids(system), do: system.characters |> Enum.map(& &1.id) |> Enum.sort()

  setup do
    instance_id = FleetScenario.unique_instance_id()
    owner_id = 7
    owner_pid = spawn_owner(instance_id, owner_id, :ark)
    owner = owner_struct(owner_id, :ark, 1)
    {:ok, instance_id: instance_id, owner: owner, owner_pid: owner_pid}
  end

  test "arrival: push_character notifies the owner with the newcomer in the snapshot",
       %{instance_id: iid, owner: owner, owner_pid: owner_pid} do
    system = build_system(iid, 101, owner: owner)
    intruder = foreign_character(iid, 128, 101)

    {:reply, {:ok, _}, _state} =
      SystemAgent.on_call({:push_character, intruder, :on_board}, self(), gen_state(iid, system))

    assert [{:update_system, %StellarSystem{} = pushed}] = FleetScenario.get_system_updates(owner_pid)
    assert character_ids(pushed) == [128]
  end

  test "departure: remove_character notifies the owner without the leaver",
       %{instance_id: iid, owner: owner, owner_pid: owner_pid} do
    resident = foreign_character(iid, 128, 101)
    converted = Instance.StellarSystem.Character.convert(resident)
    system = build_system(iid, 101, owner: owner, characters: [converted])

    {:reply, {:ok, _}, _state} =
      SystemAgent.on_call({:remove_character, resident, :on_board}, self(), gen_state(iid, system))

    assert [{:update_system, %StellarSystem{} = pushed}] = FleetScenario.get_system_updates(owner_pid)
    assert character_ids(pushed) == []
  end

  test "spy exposure: update_character notifies the owner with the refreshed copy",
       %{instance_id: iid, owner: owner, owner_pid: owner_pid} do
    covered =
      foreign_character(iid, 300, 101, type: :spy)
      |> Map.put(:spy, Instance.Character.Spy.new())

    system = build_system(iid, 101, owner: owner, characters: [Instance.StellarSystem.Character.convert(covered)])

    exposed = %{covered | spy: %{covered.spy | cover: Core.DynamicValue.new(10)}}

    {:noreply, _state} =
      SystemAgent.on_cast({:update_character, exposed}, gen_state(iid, system))

    assert [{:update_system, %StellarSystem{} = pushed}] = FleetScenario.get_system_updates(owner_pid)
    assert [%{id: 300, cover: cover}] = pushed.characters
    assert cover == 10
  end

  test "seduction: remove + re-push under the new owner ends with the converted character",
       %{instance_id: iid, owner: owner, owner_pid: owner_pid} do
    # Conversion (seduction) is assassinate + convert_character:
    # the victim owner's agent removes the old character, then the
    # seducer's agent pushes a NEW character (new id, new owner).
    victim = foreign_character(iid, 128, 101, faction: :myrmezir, faction_id: 2)
    system = build_system(iid, 101, owner: owner, characters: [Instance.StellarSystem.Character.convert(victim)])
    state = gen_state(iid, system)

    {:reply, {:ok, _}, state} =
      SystemAgent.on_call({:remove_character, victim, :on_board}, self(), state)

    converted = foreign_character(iid, 501, 101, faction: :cardan, faction_id: 3, owner_id: 44)

    {:reply, {:ok, _}, _state} =
      SystemAgent.on_call({:push_character, converted, :on_board}, self(), state)

    assert [
             {:update_system, after_remove},
             {:update_system, after_push}
           ] = FleetScenario.get_system_updates(owner_pid)

    assert character_ids(after_remove) == []
    assert [%{id: 501, owner: %{faction: :cardan}}] = after_push.characters
  end

  test "dominions notify via :update_dominion",
       %{instance_id: iid, owner: owner, owner_pid: owner_pid} do
    system = build_system(iid, 101, owner: owner, status: :inhabited_dominion)
    intruder = foreign_character(iid, 128, 101)

    {:reply, {:ok, _}, _state} =
      SystemAgent.on_call({:push_character, intruder, :on_board}, self(), gen_state(iid, system))

    assert [{:update_dominion, %StellarSystem{}}] = FleetScenario.get_system_updates(owner_pid)
  end

  test "unowned systems notify nobody", %{instance_id: iid, owner_pid: owner_pid} do
    system = build_system(iid, 101, owner: nil, status: :uninhabited)
    visitor = foreign_character(iid, 128, 101)

    {:reply, {:ok, _}, state} =
      SystemAgent.on_call({:push_character, visitor, :on_board}, self(), gen_state(iid, system))

    {:reply, {:ok, _}, _state} =
      SystemAgent.on_call({:remove_character, visitor, :on_board}, self(), state)

    assert FleetScenario.get_system_updates(owner_pid) == []
  end
end
