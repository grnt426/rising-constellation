defmodule Character.ArmadaScenariosTest do
  @moduledoc """
  End-to-end armada scenarios, mapped to the user's test classes:

    1. merging/splitting — real Character.Agents driven through
       `Instance.Player.ArmadaImpl.form/join/break`.
    2. losing members — detach on death/removal via `detach_by_map`,
       sabotage leaving membership intact.
    3. flee-stance ban — `check_reaction` gate.
    4. the lead rule — `check_enqueue` gate against live members.
    5. armada-wide retreat — flee-lead/follower role detection plus the
       `:armada_clear_to_idle` handler.
    6. Prudent members join the fight (last) — full engagement.
    7. arrival stance is the most aggressive member's — full arrival.
    8. a Fury member makes the whole armada intercept — full arrival.
    9./9a. initiation order + flip, armada block pulled in first —
       full engagement, asserted through fight_callback order.

  Combat runs the *real* pipeline (`check_interception` →
  `Fight.start` → `Fight.Manager.fight` → per-player callbacks)
  against fakes for rand/galaxy/player/system; movement scenarios run
  the real `Jump.start`/`Jump.finish` hooks with real Character.Agents
  and a real per-instance Spatial tree.

  Armies are shipless throughout (the harness cannot build real ship
  structs); shipless-vs-shipless battles resolve deterministically as
  a mutual-annihilation draw — no victor, every combatant :dead (see
  `Fight.Manager.do_check_outcome`'s both-defeated branch) — which is
  enough to assert participation and join order, the properties the
  armada rules are about. Assertions therefore pin fight_callback IDS
  and their order, never survival.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Armada
  alias Instance.Character.Actions.Fight
  alias Instance.Character.Actions.Jump
  alias Instance.Player.ArmadaImpl
  alias Instance.Player.Player
  alias Test.FleetScenario

  @arrival_reactions_default [:attack_enemies, :attack_everyone]
  @siege_reactions [:defend, :attack_enemies, :attack_everyone]

  defp base_setup(opts \\ []) do
    iid = FleetScenario.unique_instance_id()
    :ok = FleetScenario.load_game_data(iid)
    FleetScenario.spawn_instance_supervisor(self(), instance_id: iid)

    rand_pid =
      FleetScenario.spawn_fake_rand(
        self(),
        Keyword.merge([instance_id: iid], Keyword.get(opts, :rand, []))
      )

    {_galaxy, _} =
      FleetScenario.spawn_fake_galaxy(
        self(),
        Keyword.merge([instance_id: iid], Keyword.get(opts, :galaxy, []))
      )

    {_p1, p1_pid} = FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 100, faction: :phoenix)
    {_p2, p2_pid} = FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 200, faction: :crow)

    %{iid: iid, rand: rand_pid, p1: p1_pid, p2: p2_pid}
  end

  defp system_chars(specs) do
    Enum.map(specs, fn {id, faction, owner_id} ->
      FleetScenario.build_system_character(character_id: id, faction: faction, owner_id: owner_id)
    end)
  end

  defp fake_char(iid, id, opts) do
    FleetScenario.spawn_fake_character(
      self(),
      Keyword.merge(
        [instance_id: iid, character_id: id, faction: :phoenix, owner_id: 100, system: 10, has_ships?: false],
        opts
      )
    )
  end

  defp real_char(iid, id, opts) do
    FleetScenario.spawn_real_character(
      self(),
      Keyword.merge(
        [
          instance_id: iid,
          character_id: id,
          faction: :phoenix,
          owner_id: 100,
          system: 10,
          has_ships?: false,
          virtual_position: 10
        ],
        opts
      )
    )
  end

  defp live(iid, id) do
    {:ok, character} = Game.call(iid, :character, id, :get_state)
    character
  end

  defp player_data(character_ids) do
    struct(Player, %{characters: Enum.map(character_ids, fn id -> %{id: id} end)})
  end

  defp callback_ids(player_pid) do
    player_pid
    |> FleetScenario.get_fight_callbacks()
    |> Enum.map(fn {_status, character} -> character.id end)
  end

  ## ---------------------------------------------------------------
  ## Class 1 — merging and splitting armadas
  ## ---------------------------------------------------------------

  describe "form/join/break (class 1)" do
    setup do
      ctx = base_setup()
      {_sys, _} = FleetScenario.spawn_fake_stellar_system(self(), instance_id: ctx.iid, system_id: 10)

      for id <- 1..4, do: real_char(ctx.iid, id, [])

      {:ok, Map.put(ctx, :data, player_data([1, 2, 3, 4]))}
    end

    test "forming sets the same named armada map on both members", ctx do
      assert :ok == ArmadaImpl.form(ctx.iid, ctx.data, 1, 2)

      a = live(ctx.iid, 1)
      b = live(ctx.iid, 2)

      assert %{id: 1, member_ids: [1, 2], name: name} = Armada.get(a)
      assert Armada.get(b) == Armada.get(a)
      # deterministic FakeRand take_random -> first pool entry
      assert name == "The Iron Concord"
    end

    test "an armada member cannot form a second armada", ctx do
      assert :ok == ArmadaImpl.form(ctx.iid, ctx.data, 1, 2)
      assert {:error, :armada_already_member} == ArmadaImpl.form(ctx.iid, ctx.data, 1, 3)
    end

    test "join grows to 3; a fourth Navarch is rejected with :armada_full", ctx do
      assert :ok == ArmadaImpl.form(ctx.iid, ctx.data, 1, 2)
      assert :ok == ArmadaImpl.join(ctx.iid, ctx.data, 3, 1)

      assert %{member_ids: [1, 2, 3]} = Armada.get(live(ctx.iid, 3))
      assert %{member_ids: [1, 2, 3]} = Armada.get(live(ctx.iid, 1))

      assert {:error, :armada_full} == ArmadaImpl.join(ctx.iid, ctx.data, 4, 1)
      assert Armada.get(live(ctx.iid, 4)) == nil
    end

    test "break detaches one member of three; break at two dissolves", ctx do
      assert :ok == ArmadaImpl.form(ctx.iid, ctx.data, 1, 2)
      assert :ok == ArmadaImpl.join(ctx.iid, ctx.data, 3, 1)

      assert :ok == ArmadaImpl.break(ctx.iid, ctx.data, 3)
      assert Armada.get(live(ctx.iid, 3)) == nil
      assert %{member_ids: [1, 2]} = Armada.get(live(ctx.iid, 1))

      assert :ok == ArmadaImpl.break(ctx.iid, ctx.data, 1)
      assert Armada.get(live(ctx.iid, 1)) == nil
      assert Armada.get(live(ctx.iid, 2)) == nil
    end

    test "cannot form with or break a character the player does not own", ctx do
      data = player_data([1])
      assert {:error, :character_not_found} == ArmadaImpl.form(ctx.iid, data, 1, 2)
      assert {:error, :character_not_found} == ArmadaImpl.break(ctx.iid, data, 2)
    end
  end

  ## ---------------------------------------------------------------
  ## Class 2 — losing Navarchs (death/removal) and fleets (sabotage)
  ## ---------------------------------------------------------------

  describe "member loss (class 2)" do
    setup do
      ctx = base_setup()
      {_sys, _} = FleetScenario.spawn_fake_stellar_system(self(), instance_id: ctx.iid, system_id: 10)
      {:ok, ctx}
    end

    test "detaching a dead member updates the survivors; below 2 dissolves", ctx do
      armada = Armada.new(1, "The Long Watch", [1, 2, 3])
      for id <- 1..3, do: real_char(ctx.iid, id, armada: armada)

      # member 2 died in battle: its agent may already be unreachable —
      # here it is alive, and gets cleared along with the survivors
      assert :ok == ArmadaImpl.detach_by_map(ctx.iid, armada, 2)
      assert Armada.get(live(ctx.iid, 2)) == nil
      assert %{member_ids: [1, 3]} = Armada.get(live(ctx.iid, 1))
      assert %{member_ids: [1, 3]} = Armada.get(live(ctx.iid, 3))

      # losing another member drops below min size -> full dissolve
      assert :ok == ArmadaImpl.detach_by_map(ctx.iid, %{armada | member_ids: [1, 3]}, 3)
      assert Armada.get(live(ctx.iid, 1)) == nil
      assert Armada.get(live(ctx.iid, 3)) == nil
    end

    test "detach tolerates a member whose agent is already gone", ctx do
      armada = Armada.new(5, nil, [5, 6, 7])
      # 7 is never spawned — its process died with the character
      for id <- [5, 6], do: real_char(ctx.iid, id, armada: armada)

      assert :ok == ArmadaImpl.detach_by_map(ctx.iid, armada, 7)
      assert %{member_ids: [5, 6]} = Armada.get(live(ctx.iid, 5))
      assert %{member_ids: [5, 6]} = Armada.get(live(ctx.iid, 6))
    end

    test "sabotage damages the fleet but leaves armada membership intact", ctx do
      armada = Armada.new(8, nil, [8, 9])
      {_c, _} = real_char(ctx.iid, 8, armada: armada, has_ships?: false)
      {_c, _} = real_char(ctx.iid, 9, armada: armada, has_ships?: false)

      {:ok, after_sabotage} = Game.call(ctx.iid, :character, 8, {:sabotage_army, 50})
      assert %{member_ids: [8, 9]} = Armada.get(after_sabotage)
    end
  end

  ## ---------------------------------------------------------------
  ## Class 3 — the Deserter stance is forbidden inside an armada
  ## ---------------------------------------------------------------

  describe "flee-stance ban (class 3)" do
    setup do
      ctx = base_setup()
      {_sys, _} = FleetScenario.spawn_fake_stellar_system(self(), instance_id: ctx.iid, system_id: 10)
      {:ok, ctx}
    end

    test "an armada member cannot switch to Deserter; a solo Navarch can", ctx do
      armada = Armada.new(1, nil, [1, 2])
      real_char(ctx.iid, 1, armada: armada)
      real_char(ctx.iid, 3, [])

      assert {:error, :armada_flee_stance_forbidden} == ArmadaImpl.check_reaction(ctx.iid, 1, :flee)
      assert :ok == ArmadaImpl.check_reaction(ctx.iid, 1, :fight_back)
      assert :ok == ArmadaImpl.check_reaction(ctx.iid, 3, :flee)
    end

    test "bankruptcy does not force Deserter onto an armada member", ctx do
      armada = Armada.new(1, nil, [1, 2])
      real_char(ctx.iid, 1, armada: armada, reaction: :defend)
      real_char(ctx.iid, 4, reaction: :defend)

      {:ok, member} = Game.call(ctx.iid, :character, 1, {:update_strike, true})
      assert member.on_strike
      assert member.army.reaction == :defend

      {:ok, solo} = Game.call(ctx.iid, :character, 4, {:update_strike, true})
      assert solo.army.reaction == :flee
    end
  end

  ## ---------------------------------------------------------------
  ## Class 4 — the lead rule
  ## ---------------------------------------------------------------

  describe "lead rule (class 4)" do
    setup do
      ctx = base_setup(galaxy: [edges: %{{10, 11} => 2}])
      {_sys, _} = FleetScenario.spawn_fake_stellar_system(self(), instance_id: ctx.iid, system_id: 10)

      armada = Armada.new(1, nil, [1, 2])
      real_char(ctx.iid, 1, armada: armada)
      real_char(ctx.iid, 2, armada: armada)

      {:ok, ctx}
    end

    test "once one member has orders, only that member may enqueue", ctx do
      jump = [%{"type" => "jump", "data" => %{"source" => 10, "target" => 11}}]

      # nobody busy: either member may enqueue
      assert :ok == ArmadaImpl.check_enqueue(ctx.iid, 1, jump)
      assert :ok == ArmadaImpl.check_enqueue(ctx.iid, 2, jump)

      # member 1 becomes the lead by actually enqueuing
      assert :ok == Game.call(ctx.iid, :character, 1, {:add_actions, jump})
      refute ActionQueue.empty?(live(ctx.iid, 1).actions)

      assert {:error, :armada_led_by_other} == ArmadaImpl.check_enqueue(ctx.iid, 2, jump)
      # the lead may keep appending
      assert :ok == ArmadaImpl.check_enqueue(ctx.iid, 1, jump)
    end

    test "a docking member blocks armada departures but not in-system orders", ctx do
      jump = [%{"type" => "jump", "data" => %{"source" => 10, "target" => 11}}]
      raid = [%{"type" => "raid", "data" => %{"target" => 10}}]

      # flip member 2 to docking (ship under construction) via the
      # agent's own state-replacement channel
      docking = %{live(ctx.iid, 2) | action_status: :docking}
      Game.cast(ctx.iid, :character, 2, {:update_state, docking})

      assert {:error, :armada_member_docking} == ArmadaImpl.check_enqueue(ctx.iid, 1, jump)
      # docking is in-system activity: it blocks departure, not orders
      assert :ok == ArmadaImpl.check_enqueue(ctx.iid, 1, raid)
    end
  end

  ## ---------------------------------------------------------------
  ## Class 5 — a beaten armada flees together
  ## ---------------------------------------------------------------

  describe "armada-wide retreat (class 5)" do
    setup do
      ctx =
        base_setup(galaxy: [edges: %{{10, 11} => 2}, closest_systems: %{10 => 11}])

      {_sys, _} = FleetScenario.spawn_fake_stellar_system(self(), instance_id: ctx.iid, system_id: 10)

      armada = Armada.new(1, nil, [1, 2, 3])
      for id <- 1..3, do: real_char(ctx.iid, id, armada: armada)

      {:ok, Map.put(ctx, :armada, armada)}
    end

    test "first losing member is the flee-lead; later ones follow; followers clear to idle", ctx do
      # nobody has fled yet -> member 1 is the flee-lead
      assert :lead == ArmadaImpl.armada_flee_role(ctx.iid, live(ctx.iid, 1), ctx.armada)

      # the flee-lead enqueues its retreat jump (real :flee handler,
      # closest system 11 via the fake galaxy)
      fled = Game.call(ctx.iid, :character, 1, :flee)
      refute ActionQueue.empty?(fled.actions)

      # members 2 and 3 now detect the pending retreat and follow
      assert :follower == ArmadaImpl.armada_flee_role(ctx.iid, live(ctx.iid, 2), ctx.armada)
      assert :follower == ArmadaImpl.armada_flee_role(ctx.iid, live(ctx.iid, 3), ctx.armada)

      # a follower drops its remaining orders and idles — the
      # flee-lead's Jump.start re-attaches it for the retreat
      {:ok, cleared} = Game.call(ctx.iid, :character, 2, :armada_clear_to_idle)
      assert ActionQueue.empty?(cleared.actions)
      assert cleared.action_status == :idle
    end
  end

  ## ---------------------------------------------------------------
  ## Classes 6 + 9 + 9a — engagement participation and join order
  ## ---------------------------------------------------------------

  describe "engagement order (classes 6, 9, 9a)" do
    setup do
      {:ok, base_setup()}
    end

    test "class 6: a Prudent armada member joins the fight — last of the three", ctx do
      armada = Armada.new(1, nil, [1, 2, 3])
      fake_char(ctx.iid, 1, reaction: :attack_everyone)
      fake_char(ctx.iid, 2, reaction: :defend)
      fake_char(ctx.iid, 3, reaction: :fight_back)

      # pre-set armada on the fakes (build_character has no armada opt)
      for id <- 1..3 do
        :ok = GenServer.call(Game.via_tuple({ctx.iid, :character, id}), {:update, &Map.put(&1, :armada, armada)})
      end

      {_sys, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 10,
          characters: system_chars([{1, :phoenix, 100}, {2, :phoenix, 100}, {3, :phoenix, 100}])
        )

      {raider, _} = fake_char(ctx.iid, 20, faction: :crow, owner_id: 200)

      raid = FleetScenario.build_action(:raid, %{"target" => 10})
      Fight.check_interception(raider, raid, @siege_reactions)

      # every member fought — including the Prudent one — in stance
      # order: Fury, Defender, Prudent
      assert callback_ids(ctx.p1) == [1, 2, 3]
      assert callback_ids(ctx.p2) == [20]
    end

    test "class 9/9a: initiation flip decides the target; the winner's armada joins first", ctx do
      # defending armada Alpha {A:fury, B:defend, C:defend} + solo
      # fleet Beta {fury}, all one player, at system 10
      armada = Armada.new(1, nil, [1, 2, 3])
      fake_char(ctx.iid, 1, reaction: :attack_everyone)
      fake_char(ctx.iid, 2, reaction: :defend)
      fake_char(ctx.iid, 3, reaction: :defend)
      fake_char(ctx.iid, 4, reaction: :attack_everyone)

      for id <- 1..3 do
        :ok = GenServer.call(Game.via_tuple({ctx.iid, :character, id}), {:update, &Map.put(&1, :armada, armada)})
      end

      {_sys, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 10,
          characters:
            system_chars([{1, :phoenix, 100}, {2, :phoenix, 100}, {3, :phoenix, 100}, {4, :phoenix, 100}])
        )

      {arriver, _} = fake_char(ctx.iid, 20, faction: :crow, owner_id: 200)

      jump = FleetScenario.build_action(:jump, %{"target" => 10})
      Fight.check_interception(arriver, jump, @arrival_reactions_default)

      # take_random preserves order -> A wins the Fury flip; the whole
      # Alpha block enters before Beta (9a)
      assert callback_ids(ctx.p1) == [1, 2, 3, 4]
    end

    test "class 9 flip, reversed: Beta wins the initiation and enters first", ctx do
      armada = Armada.new(1, nil, [1, 2, 3])
      fake_char(ctx.iid, 1, reaction: :attack_everyone)
      fake_char(ctx.iid, 2, reaction: :defend)
      fake_char(ctx.iid, 3, reaction: :defend)
      fake_char(ctx.iid, 4, reaction: :attack_everyone)

      for id <- 1..3 do
        :ok = GenServer.call(Game.via_tuple({ctx.iid, :character, id}), {:update, &Map.put(&1, :armada, armada)})
      end

      {_sys, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 10,
          characters:
            system_chars([{1, :phoenix, 100}, {2, :phoenix, 100}, {3, :phoenix, 100}, {4, :phoenix, 100}])
        )

      {arriver, _} = fake_char(ctx.iid, 20, faction: :crow, owner_id: 200)

      # flip the coin the other way
      GenServer.call(ctx.rand, {:set, :reverse_take_random, true})

      jump = FleetScenario.build_action(:jump, %{"target" => 10})
      Fight.check_interception(arriver, jump, @arrival_reactions_default)

      assert callback_ids(ctx.p1) == [4, 1, 2, 3]
    end
  end

  ## ---------------------------------------------------------------
  ## Classes 7 + 8 — Fury semantics for arriving/defending armadas
  ## ---------------------------------------------------------------

  describe "fury semantics (classes 7, 8)" do
    setup do
      {:ok, base_setup()}
    end

    test "class 7: a Fury escort makes a Prudent lead's arrival engage passive sitters", ctx do
      # solo Prudent arriver: a :defend sitter is NOT engaged
      {_sitter, _} = fake_char(ctx.iid, 1, reaction: :defend)

      {_sys, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 10,
          characters: system_chars([{1, :phoenix, 100}])
        )

      armada = Armada.new(20, nil, [20, 21])
      {lead, _} = fake_char(ctx.iid, 20, faction: :crow, owner_id: 200, reaction: :fight_back)
      {escort, _} = fake_char(ctx.iid, 21, faction: :crow, owner_id: 200, reaction: :attack_everyone)

      for id <- [20, 21] do
        :ok = GenServer.call(Game.via_tuple({ctx.iid, :character, id}), {:update, &Map.put(&1, :armada, armada)})
      end

      lead = Map.put(lead, :armada, armada)
      escort = Map.put(escort, :armada, armada)

      jump = FleetScenario.build_action(:jump, %{"target" => 10})

      # without the escort's stance, no engagement happens
      {_, _, engaged?} = Jump.arrival_interception(lead, jump)
      refute engaged?
      assert callback_ids(ctx.p1) == []

      # with the Fury escort as companion, the armada arrives Fury:
      # the :defend sitter is engaged and the whole armada fights
      Jump.arrival_interception(lead, jump, [escort])

      assert callback_ids(ctx.p1) == [1]
      assert Enum.sort(callback_ids(ctx.p2)) == [20, 21]
    end

    test "class 8: one Fury member makes the whole defending armada intercept", ctx do
      # defending armada {A:defend, B:fury}; a plain :defend defender
      # would NOT intercept a non-Fury arrival
      armada = Armada.new(1, nil, [1, 2])
      fake_char(ctx.iid, 1, reaction: :defend)
      fake_char(ctx.iid, 2, reaction: :attack_everyone)

      for id <- [1, 2] do
        :ok = GenServer.call(Game.via_tuple({ctx.iid, :character, id}), {:update, &Map.put(&1, :armada, armada)})
      end

      {_sys, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 10,
          characters: system_chars([{1, :phoenix, 100}, {2, :phoenix, 100}])
        )

      {arriver, _} = fake_char(ctx.iid, 20, faction: :crow, owner_id: 200, reaction: :defend)

      jump = FleetScenario.build_action(:jump, %{"target" => 10})
      {_, hostiles} = Fight.find_hostiles(arriver, jump, @arrival_reactions_default)

      # both members are interceptors (effective stance = Fury), so the
      # incoming Navarch is engaged even though it has queued actions
      assert Enum.sort(Enum.map(hostiles, & &1.id)) == [1, 2]

      Fight.check_interception(arriver, jump, @arrival_reactions_default)
      assert Enum.sort(callback_ids(ctx.p1)) == [1, 2]
      assert callback_ids(ctx.p2) == [20]
    end

    test "class 8 control: without the Fury member, a :defend armada does not intercept", ctx do
      armada = Armada.new(1, nil, [1, 2])
      fake_char(ctx.iid, 1, reaction: :defend)
      fake_char(ctx.iid, 2, reaction: :defend)

      for id <- [1, 2] do
        :ok = GenServer.call(Game.via_tuple({ctx.iid, :character, id}), {:update, &Map.put(&1, :armada, armada)})
      end

      {_sys, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 10,
          characters: system_chars([{1, :phoenix, 100}, {2, :phoenix, 100}])
        )

      {arriver, _} = fake_char(ctx.iid, 20, faction: :crow, owner_id: 200, reaction: :defend)

      jump = FleetScenario.build_action(:jump, %{"target" => 10})
      {_, hostiles} = Fight.find_hostiles(arriver, jump, @arrival_reactions_default)

      assert hostiles == []
    end
  end

  ## ---------------------------------------------------------------
  ## Attached transit — the movement machinery under classes 5 and 7
  ## ---------------------------------------------------------------

  describe "attached transit (Jump.start/finish fan-outs)" do
    setup do
      ctx = base_setup(galaxy: [edges: %{{10, 11} => 2}])
      FleetScenario.spawn_spatial(self(), instance_id: ctx.iid)
      FleetScenario.spawn_fake_faction(self(), instance_id: ctx.iid, faction_id: 1)

      {:ok, ctx}
    end

    defp jump_action do
      %Action{
        type: :jump,
        data: %{
          "source" => 10,
          "target" => 11,
          "source_position" => %Spatial.Position{x: 10.0, y: 0.0},
          "target_position" => %Spatial.Position{x: 11.0, y: 0.0}
        },
        total_time: 5,
        remaining_time: 5,
        started_at: nil,
        cumulated_pauses: nil
      }
    end

    test "departure attaches members; arrival materializes them", ctx do
      armada = Armada.new(1, "The Iron Tide", [1, 2])
      {lead, _} = real_char(ctx.iid, 1, armada: armada)
      real_char(ctx.iid, 2, armada: armada)

      {_s10, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 10,
          characters: system_chars([{1, :phoenix, 100}, {2, :phoenix, 100}])
        )

      {_s11, s11_pid} = FleetScenario.spawn_fake_stellar_system(self(), instance_id: ctx.iid, system_id: 11)

      # departure: the lead's Jump.start pulls member 2 out of S10
      {_, _, lead} = Jump.start(lead, jump_action())

      member = live(ctx.iid, 2)
      assert member.action_status == :attached
      assert member.system == nil
      assert ActionQueue.empty?(member.actions)

      # arrival: the lead's Jump.finish materializes member 2 into S11
      {_, _, lead} = Jump.finish(lead, jump_action())
      assert lead.system == 11

      member = live(ctx.iid, 2)
      assert member.action_status == :idle
      assert member.system == 11
      assert member.actions.virtual_position == 11

      {:ok, s11} = GenServer.call(s11_pid, :get_state)
      assert Enum.sort(Enum.map(s11.characters, & &1.id)) == [1, 2]
    end

    test "an armada arrival fights the picket as one battle, all members in", ctx do
      armada = Armada.new(1, nil, [1, 2])
      {lead, _} = real_char(ctx.iid, 1, armada: armada, reaction: :defend)
      real_char(ctx.iid, 2, armada: armada, reaction: :fight_back)

      {_s10, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 10,
          characters: system_chars([{1, :phoenix, 100}, {2, :phoenix, 100}])
        )

      # an Interdiction picket waits at S11
      fake_char(ctx.iid, 30, faction: :crow, owner_id: 200, system: 11, reaction: :attack_enemies)

      {_s11, _} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: ctx.iid,
          system_id: 11,
          characters: system_chars([{30, :crow, 200}])
        )

      {_, _, lead} = Jump.start(lead, jump_action())
      Jump.finish(lead, jump_action())

      # one battle, both armada members in it (the Prudent member too —
      # it was pulled in by armada expansion, not by its stance)
      assert Enum.sort(callback_ids(ctx.p1)) == [1, 2]
      assert callback_ids(ctx.p2) == [30]
    end
  end
end
