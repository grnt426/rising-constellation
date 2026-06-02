defmodule Character.FleetEngagementScenariosTest do
  @moduledoc """
  Phase-1 end-to-end engagement scenarios. Drives
  `Instance.Character.Actions.Fight.check_interception/3` through the
  *full* engagement pipeline — `find_hostiles/3` → `Fight.start/2` →
  `Fight.Manager.fight/2` → per-player `fight_callback` → notif
  broadcast → optional `kill_character` — against fakes for every
  external dependency (stellar_system, character, rand, galaxy,
  player) plus a real-but-empty instance supervisor for the kill path.

  ## What this isolates

  The `find_hostiles` predicate test
  (`fleet_interception_scenarios_test.exs`) already pinned that the
  filter selects the right defenders. The unknown from the original
  Bug 1 report ("queued bombard against G:defend produced no combat")
  is "what happens AFTER selection." Phase 1 closes the gap:

    * If a scenario here passes (engagement runs, fight_callback
      fires, notifs go out), the Bug-1 production path can't be the
      check_interception → Fight.start sequence. The bug must live
      upstream — orchestrator dispatch, action queue lock/unlock
      timing, or stale state between the tick that fires
      orchestrate(:start) and the tick that re-reads after :done.

    * If a scenario fails (engagement crashes silently because
      Fight.start raises and the orchestrator's rescue swallows it),
      we've reproduced the bug deterministically and can debug from
      a tight repro instead of production logs.

  ## Status: scenarios currently PASS

  None of the engagements below reproduce a "no combat" outcome under
  the harness — the fight_callbacks fire on both sides, the notifs go
  out, kill_character runs without crashing. That's a useful negative
  result: the live Bug-1 trigger is NOT something
  check_interception/Fight.start does wrong with default-shaped state.
  Worth keeping these as regressions while we keep digging upstream.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Actions.Fight
  alias Test.FleetScenario

  ## Original Bug-1 scenario at the engagement level

  describe "engagement: G:defend at S1, T queues raid" do
    setup do
      iid = FleetScenario.unique_instance_id()
      :ok = FleetScenario.load_game_data(iid)
      _supervisor = FleetScenario.spawn_instance_supervisor(self(), instance_id: iid)
      _rand = FleetScenario.spawn_fake_rand(self(), instance_id: iid)
      {_galaxy, _g_pid} = FleetScenario.spawn_fake_galaxy(self(), instance_id: iid)

      # Two players, two factions. G (phoenix) is the defender; T
      # (crow) is the incoming raider.
      {_g_player, g_player_pid} =
        FleetScenario.spawn_fake_player(self(),
          instance_id: iid,
          player_id: 100,
          faction: :phoenix
        )

      {_t_player, t_player_pid} =
        FleetScenario.spawn_fake_player(self(),
          instance_id: iid,
          player_id: 200,
          faction: :crow
        )

      {:ok, iid: iid, g_player_pid: g_player_pid, t_player_pid: t_player_pid}
    end

    test "Fight.start runs end-to-end and fight_callback fires on both player processes", ctx do
      iid = ctx.iid

      # G is parked over S1 with default :defend, no orders.
      g_summary =
        FleetScenario.build_system_character(character_id: 1, faction: :phoenix, owner_id: 100)

      {_system, _sys_pid} =
        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: iid,
          system_id: 10,
          characters: [g_summary]
        )

      {_g, _g_pid} =
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

      # T has just arrived at S1 (Jump.finish ran enter_system, so
      # T.system = 10) and is about to start a raid against S1. The
      # raid's reactions list includes :defend, so check_interception
      # should select G and Fight.start should run.
      {t, _t_pid} =
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 2,
          faction: :crow,
          owner_id: 200,
          system: 10,
          reaction: :defend,
          action_status: :idle,
          has_ships?: false
        )

      raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

      {_post_character, _notifs, fleeing_or_dead?} =
        Fight.check_interception(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      # Both players received exactly one fight_callback — proves
      # Fight.start ran to completion (it loops over every combatant's
      # owner). If the engagement had silently crashed at any point
      # between find_hostiles and fight_callback, we'd see empty
      # lists here.
      g_callbacks = FleetScenario.get_fight_callbacks(ctx.g_player_pid)
      t_callbacks = FleetScenario.get_fight_callbacks(ctx.t_player_pid)

      assert length(g_callbacks) == 1,
             "G's player must receive a fight_callback — proves engagement reached the post-fight stage"

      assert length(t_callbacks) == 1,
             "T's player must receive a fight_callback — proves attacker side also processed"

      # Status — `Fight.Manager.do_check_outcome` iterates
      # `[:left, :right]` and writes `battle.victory = reverse(side)`
      # the first time it sees a side with no ships and no
      # reinforcement. With both sides shipless from turn 1, the
      # :left pass sets victory = :right, then the :right pass
      # overwrites with victory = :left. T (attacker, :left) is
      # therefore declared :victorious and G (:right) is :dead —
      # a quirk of the edge case, but the contract our test pins.
      [{g_status, _}] = g_callbacks
      [{t_status, _}] = t_callbacks

      assert t_status == :victorious,
             "attacker side (:left) wins the shipless-vs-shipless tie via do_check_outcome's iteration order"

      assert g_status == :dead,
             "defender side (:right) is :dead — no ships, not the declared victor"

      # Notifs — Fight.start's send_notifs_and_report broadcasts one
      # :fight Notification.Box per recipient. With two players we
      # expect at least one each.
      g_notifs = FleetScenario.get_notifs(ctx.g_player_pid)
      t_notifs = FleetScenario.get_notifs(ctx.t_player_pid)

      assert length(g_notifs) >= 1, "G's player should receive at least one notif"
      assert length(t_notifs) >= 1, "T's player should receive at least one notif"

      # T survived as :victorious, so the raid does NOT abort —
      # `fleeing_or_dead?` is false. (The fact that G died is on G's
      # side of the ledger; the boolean here governs whether T
      # continues with the queued bombard.)
      refute fleeing_or_dead?,
             "T :victorious → raid continues; only T's flee/death would abort the queued bombard"
    end

    test "engagement does NOT run when G has :fight_back (passive reaction sanity check)", ctx do
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
        reaction: :fight_back,
        action_status: :idle,
        has_ships?: false
      )

      {t, _} =
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 2,
          faction: :crow,
          owner_id: 200,
          system: 10,
          reaction: :defend,
          action_status: :idle,
          has_ships?: false
        )

      raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

      {_post_character, _notifs, fleeing_or_dead?} =
        Fight.check_interception(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      # No engagement, no callbacks, no notifs.
      assert FleetScenario.get_fight_callbacks(ctx.g_player_pid) == []
      assert FleetScenario.get_fight_callbacks(ctx.t_player_pid) == []
      assert FleetScenario.get_notifs(ctx.g_player_pid) == []
      assert FleetScenario.get_notifs(ctx.t_player_pid) == []

      refute fleeing_or_dead?,
             "with :fight_back defender excluded by the filter, no fight runs and T is unmolested"
    end
  end

  ## Flee branch — T has :flee reaction, rolls succeed

  describe "engagement: T has :flee reaction" do
    test "T with :flee reaction triggers the flee branch and never reaches Fight.start" do
      iid = FleetScenario.unique_instance_id()
      :ok = FleetScenario.load_game_data(iid)
      FleetScenario.spawn_instance_supervisor(self(), instance_id: iid)

      # uniform_value < fleeing_chance forces the flee branch to win
      # its roll. fleeing_chance in fast/dev metadata is some float;
      # 0.0 is unambiguously less than any positive chance.
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.0)

      # The flee branch calls Galaxy {:get_closest_system, ...} for
      # the destination AND {:check_jump, source, target} when adding
      # the flee jump via Jump.pre_validate. Map S10's closest to S11
      # and edge S10↔S11 with a weight of 1.
      FleetScenario.spawn_fake_galaxy(self(),
        instance_id: iid,
        closest_systems: %{10 => 11},
        edges: %{{10, 11} => 1, {11, 10} => 1}
      )

      {_g_player, g_player_pid} =
        FleetScenario.spawn_fake_player(self(),
          instance_id: iid,
          player_id: 100,
          faction: :phoenix
        )

      {_t_player, t_player_pid} =
        FleetScenario.spawn_fake_player(self(),
          instance_id: iid,
          player_id: 200,
          faction: :crow
        )

      g_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix, owner_id: 100)

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
        action_status: :idle,
        has_ships?: false
      )

      # T's army.reaction is :flee. With uniform_value=0.0 the roll
      # against fleeing_chance succeeds and T flees instead of engaging.
      {t, _} =
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 2,
          faction: :crow,
          owner_id: 200,
          system: 10,
          reaction: :flee,
          action_status: :idle,
          has_ships?: false
        )

      raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

      {_post_character, notifs, fleeing_or_dead?} =
        Fight.check_interception(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      # No fight ran — no fight_callbacks on either side.
      assert FleetScenario.get_fight_callbacks(g_player_pid) == [],
             "flee path bypasses Fight.start entirely; G's fight_callback must not fire"

      assert FleetScenario.get_fight_callbacks(t_player_pid) == [],
             "ditto for T"

      # The flee branch generates one :interception_and_flight text
      # notif and returns it in the notifs accumulator (not via player
      # cast — the caller forwards it). Notification.Text.new sets
      # `type: :text` and stores the specific event under `key`.
      assert length(notifs) == 1, "exactly one flight notif"
      assert hd(notifs).type == :text
      assert hd(notifs).key == :interception_and_flight

      assert fleeing_or_dead?,
             "flee branch sets fleeing_or_dead? = true so the outer raid.start aborts the bombard"
    end
  end

  ## Cold-war sanity check at the engagement level

  describe "engagement: cold-war scenario (Jump.finish reactions list)" do
    test "G:defend and Jump.finish reactions list — no engagement runs (no Fight.start)" do
      iid = FleetScenario.unique_instance_id()
      :ok = FleetScenario.load_game_data(iid)
      FleetScenario.spawn_instance_supervisor(self(), instance_id: iid)
      FleetScenario.spawn_fake_rand(self(), instance_id: iid)
      FleetScenario.spawn_fake_galaxy(self(), instance_id: iid)

      {_g_player, g_player_pid} =
        FleetScenario.spawn_fake_player(self(),
          instance_id: iid,
          player_id: 100,
          faction: :phoenix
        )

      {_t_player, t_player_pid} =
        FleetScenario.spawn_fake_player(self(),
          instance_id: iid,
          player_id: 200,
          faction: :crow
        )

      g_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix, owner_id: 100)

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
        action_status: :idle,
        has_ships?: false
      )

      {t, _} =
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 2,
          faction: :crow,
          owner_id: 200,
          system: 10,
          reaction: :defend,
          action_status: :idle,
          has_ships?: false
        )

      jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

      {_post_character, _notifs, fleeing_or_dead?} =
        Fight.check_interception(t, jump_action, [:attack_enemies, :attack_everyone])

      assert FleetScenario.get_fight_callbacks(g_player_pid) == []
      assert FleetScenario.get_fight_callbacks(t_player_pid) == []

      refute fleeing_or_dead?,
             "G:defend doesn't appear on Jump.finish's list — engagement is bypassed cleanly"
    end
  end
end
