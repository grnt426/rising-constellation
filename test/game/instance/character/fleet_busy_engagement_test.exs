defmodule Character.FleetBusyEngagementTest do
  @moduledoc """
  End-to-end scenarios for the 2026-09-05 interception contract change
  (instance 121, Benkad + Adenarjah): a fleet busy with an in-system
  action can no longer hide from an arriving Fury or Defender fleet,
  a busy faction-mate joins a battle that breaks out in its system,
  and a queued attack whose target has left is skipped cleanly with a
  text notification instead of a crash-recovery abort.

  Drives `Fight.check_interception/4` and `Fight.start/2` through the
  full engagement pipeline against the `Test.FleetScenario` fakes,
  exactly like `fleet_engagement_scenarios_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.ActionImpl
  alias Instance.Character.ActionQueue
  alias Instance.Character.Actions.Fight
  alias Instance.Character.Actions.Jump
  alias Test.FleetScenario

  describe "arrival engagement of a busy sitter" do
    setup do
      iid = FleetScenario.unique_instance_id()
      :ok = FleetScenario.load_game_data(iid)
      _supervisor = FleetScenario.spawn_instance_supervisor(self(), instance_id: iid)
      _rand = FleetScenario.spawn_fake_rand(self(), instance_id: iid)
      {_galaxy, _g_pid} = FleetScenario.spawn_fake_galaxy(self(), instance_id: iid)

      {_g_player, g_player_pid} =
        FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 100, faction: :phoenix)

      {_t_player, t_player_pid} =
        FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 200, faction: :crow)

      {:ok, iid: iid, g_player_pid: g_player_pid, t_player_pid: t_player_pid}
    end

    # G (phoenix) sits at S10 mid-action; T (crow) has just arrived
    # (Jump.finish ran enter_system, so T.system = 10) with the given
    # stance. Returns the fight_callback counts seen by each player.
    defp arrive(ctx, sitter_status, arriver_reaction) do
      iid = ctx.iid

      g_summary =
        FleetScenario.build_system_character(character_id: 1, faction: :phoenix, owner_id: 100)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [g_summary]
      )

      FleetScenario.spawn_fake_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :phoenix,
        owner_id: 100,
        system: 10,
        reaction: :defend,
        action_status: sitter_status,
        has_ships?: false
      )

      {t, _t_pid} =
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 2,
          faction: :crow,
          owner_id: 200,
          system: 10,
          reaction: arriver_reaction,
          action_status: :idle,
          has_ships?: false
        )

      jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

      {_post, _notifs, _fleeing_or_dead?} =
        Fight.check_interception(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(arriver_reaction))

      {length(FleetScenario.get_fight_callbacks(ctx.g_player_pid)),
       length(FleetScenario.get_fight_callbacks(ctx.t_player_pid))}
    end

    test "Fury arriver engages a sitter mid-pillage end-to-end (Benkad)", ctx do
      assert arrive(ctx, :loot, :attack_everyone) == {1, 1},
             "both players must receive a fight_callback — the pillager could not intercept, but it was engaged"
    end

    test "Fury arriver engages a sitter mid-colonization end-to-end (Adenarjah)", ctx do
      assert arrive(ctx, :colonization, :attack_everyone) == {1, 1}
    end

    test "Defender arriver engages a sitter mid-bombard end-to-end", ctx do
      assert arrive(ctx, :raid, :defend) == {1, 1},
             "Defender's purpose is to stop hostile acts — a bombarding enemy is engaged on arrival"
    end

    test "Defender arriver leaves an idle sitter alone (armed neutrality)", ctx do
      assert arrive(ctx, :idle, :defend) == {0, 0},
             "an idle enemy is not a hostile act; :defend vs :defend stays peaceful"
    end

    test "Interdiction arriver does not engage a busy sitter", ctx do
      assert arrive(ctx, :loot, :attack_enemies) == {0, 0},
             "Interdiction engages nobody on arrival, and a busy sitter never intercepts"
    end
  end

  describe "busy faction-mates join a battle in their system" do
    setup do
      iid = FleetScenario.unique_instance_id()
      :ok = FleetScenario.load_game_data(iid)
      _supervisor = FleetScenario.spawn_instance_supervisor(self(), instance_id: iid)
      _rand = FleetScenario.spawn_fake_rand(self(), instance_id: iid)
      {_galaxy, _g_pid} = FleetScenario.spawn_fake_galaxy(self(), instance_id: iid)

      {_g_player, g_player_pid} =
        FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 100, faction: :phoenix)

      {_t_player, t_player_pid} =
        FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: 200, faction: :crow)

      {:ok, iid: iid, g_player_pid: g_player_pid, t_player_pid: t_player_pid}
    end

    test "a pillaging Defender faction-mate of the target is pulled into the fight", ctx do
      iid = ctx.iid

      g1_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix, owner_id: 100)
      g2_summary = FleetScenario.build_system_character(character_id: 3, faction: :phoenix, owner_id: 100)
      t_summary = FleetScenario.build_system_character(character_id: 2, faction: :crow, owner_id: 200)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [g1_summary, g2_summary, t_summary]
      )

      # G1 idle (the target), G2 busy looting (the joiner).
      for {id, status} <- [{1, :idle}, {3, :loot}] do
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: id,
          faction: :phoenix,
          owner_id: 100,
          system: 10,
          reaction: :defend,
          action_status: status,
          has_ships?: false
        )
      end

      {t, _t_pid} =
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 2,
          faction: :crow,
          owner_id: 200,
          system: 10,
          reaction: :attack_everyone,
          action_status: :idle,
          has_ships?: false
        )

      fight_action = FleetScenario.build_action(:fight, %{"target" => 10, "target_character" => 1})
      Fight.start(t, fight_action)

      g_callbacks = FleetScenario.get_fight_callbacks(ctx.g_player_pid)

      assert Enum.sort(Enum.map(g_callbacks, fn {_status, c} -> c.id end)) == [1, 3],
             "G2 was mid-loot but physically present: it joins the defenders instead of watching its faction-mate die"

      assert length(FleetScenario.get_fight_callbacks(ctx.t_player_pid)) == 1
    end

    test "a Prudent faction-mate still stays out of it", ctx do
      iid = ctx.iid

      g1_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix, owner_id: 100)
      g2_summary = FleetScenario.build_system_character(character_id: 3, faction: :phoenix, owner_id: 100)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [g1_summary, g2_summary]
      )

      FleetScenario.spawn_fake_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :phoenix,
        owner_id: 100,
        system: 10,
        reaction: :defend,
        action_status: :idle,
        has_ships?: false
      )

      FleetScenario.spawn_fake_character(self(),
        instance_id: iid,
        character_id: 3,
        faction: :phoenix,
        owner_id: 100,
        system: 10,
        reaction: :fight_back,
        action_status: :loot,
        has_ships?: false
      )

      {t, _t_pid} =
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 2,
          faction: :crow,
          owner_id: 200,
          system: 10,
          reaction: :attack_everyone,
          action_status: :idle,
          has_ships?: false
        )

      fight_action = FleetScenario.build_action(:fight, %{"target" => 10, "target_character" => 1})
      Fight.start(t, fight_action)

      assert Enum.map(FleetScenario.get_fight_callbacks(ctx.g_player_pid), fn {_s, c} -> c.id end) == [1],
             "stance still decides participation — Prudent never intervenes for an ally, busy or not"
    end
  end

  describe "escort: one battle per group, most hostile stance first" do
    setup do
      iid = FleetScenario.unique_instance_id()
      {:ok, iid: iid}
    end

    defp escort_pair(iid, screen_reaction, opts \\ []) do
      # G-screen idle at S10 in front of G-conquest (busy :conquest).
      screen =
        FleetScenario.build_character(
          instance_id: iid,
          character_id: 1,
          faction: :phoenix,
          system: 10,
          reaction: screen_reaction,
          action_status: :idle
        )

      conquest =
        FleetScenario.build_character(
          instance_id: iid,
          character_id: 3,
          faction: :phoenix,
          system: 10,
          reaction: Keyword.get(opts, :conquest_reaction, :defend),
          action_status: :conquest
        )

      {screen, conquest}
    end

    test "the Fury screen is engaged first whatever order the shuffle yields", ctx do
      # FakeRand reverses take_random, so the shuffle hands the conquest
      # fleet back first — the stance sort must still put the screen ahead.
      FleetScenario.spawn_fake_rand(self(), instance_id: ctx.iid, reverse_take_random: true)
      {screen, conquest} = escort_pair(ctx.iid, :attack_everyone)

      assert [%{id: 1}, %{id: 3}] = Fight.order_hostiles([screen, conquest], ctx.iid)
      assert [%{id: 1}, %{id: 3}] = Fight.order_hostiles([conquest, screen], ctx.iid)
    end

    test "Interdiction and Defender screens rank ahead of the conquest fleet too", ctx do
      FleetScenario.spawn_fake_rand(self(), instance_id: ctx.iid, reverse_take_random: true)

      for screen_reaction <- [:attack_enemies] do
        {screen, conquest} = escort_pair(ctx.iid, screen_reaction)
        assert [%{id: 1}, %{id: 3}] = Fight.order_hostiles([conquest, screen], ctx.iid)
      end
    end

    test "the conquest fleet joins the screen's battle and is not engaged again", ctx do
      {screen, conquest} = escort_pair(ctx.iid, :attack_everyone)

      assert Enum.map(Fight.joined_with(screen, [screen, conquest]), & &1.id) == [3],
             "a busy Defender faction-mate joins the battle initiated against the screen, so the loop must skip it afterwards"
    end

    test "a Prudent faction-mate does not join, so it gets its own engagement", ctx do
      {screen, prudent} = escort_pair(ctx.iid, :attack_everyone, conquest_reaction: :fight_back)

      assert Fight.joined_with(screen, [screen, prudent]) == [],
             "Prudent never intervenes for an ally — under a Fury arrival it is engaged on its own afterwards"
    end

    test "an enemy of another faction is not a joiner", ctx do
      {screen, _} = escort_pair(ctx.iid, :attack_everyone)
      other = FleetScenario.build_character(instance_id: ctx.iid, character_id: 9, faction: :crow, system: 10)

      assert Fight.joined_with(screen, [screen, other]) == []
    end
  end

  describe "queued attack order whose target is gone at arrival" do
    test "Fight.start throws the clean abort with a :fight_target_gone notif" do
      iid = FleetScenario.unique_instance_id()

      # S10 is empty; the target Navarch (id 1) moved on to S11.
      FleetScenario.spawn_fake_stellar_system(self(), instance_id: iid, system_id: 10, characters: [])

      FleetScenario.spawn_fake_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :phoenix,
        system: 11
      )

      t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
      fight_action = FleetScenario.build_action(:fight, %{"target" => 10, "target_character" => 1})

      assert {:character_not_reachable, [notif]} = catch_throw(Fight.start(t, fight_action))
      assert notif.type == :text
      assert notif.key == :fight_target_gone
      assert notif.system_id == 10
      assert notif.data.admiral == t.name
    end

    test "ActionImpl.on_start drops the fight and moves on, delivering the notif" do
      iid = FleetScenario.unique_instance_id()

      FleetScenario.spawn_fake_stellar_system(self(), instance_id: iid, system_id: 10, characters: [])
      FleetScenario.spawn_fake_character(self(), instance_id: iid, character_id: 1, faction: :phoenix, system: 11)

      t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
      data = %{"target" => 10, "target_character" => 1}

      # Queue: [fight G1 @ S10, jump S10 -> S12] — the player queued the
      # attack, then a follow-up move.
      actions =
        ActionQueue.new()
        |> ActionQueue.set_virtual_position(10)
        |> ActionQueue.add({:fight, data, 0}, 10)
        |> ActionQueue.add({:jump, %{"source" => 10, "target" => 12}, 5}, 12)

      t = %{t | actions: actions}
      fight_action = FleetScenario.build_action(:fight, data)

      {changes, notifs, t_after} = ActionImpl.on_start(t, fight_action)

      assert MapSet.member?(changes, :player_update)
      assert [%{key: :fight_target_gone}] = notifs

      # The fight was popped; the queued jump is now the head and will
      # start on the next orchestrator pass.
      assert [%{type: :jump}] = :queue.to_list(t_after.actions.queue.q)
    end
  end
end
