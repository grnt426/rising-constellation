defmodule Character.FleetInterceptionScenariosTest do
  @moduledoc """
  Scenario-driven tests over
  `Instance.Character.Actions.Fight.find_hostiles/3`. The predicate that
  decides "does this hostile-action call engage a defender?" lives
  there. This file boots one fake `StellarSystem` agent and N fake
  `Character` agents per test (see `Test.FleetScenario`) and asserts
  the contract for every reaction/status/faction combination that
  matters to the original Bug 1 ("queued bombard didn't trigger a
  fight") and to the armed-neutrality design.

  ## Coverage

  Each `describe` block pins one row of the design matrix:

    * Bug-1 happy path (`raid` reactions list includes `:defend`) — a
      `:defend` admiral on the target system IS in `hostiles`.
    * Cold-war (Jump.finish reactions list excludes `:defend`) — a
      `:defend` admiral is NOT in `hostiles`, so two `:defend` factions
      pass by each other peacefully.
    * The two passive reactions (`:fight_back`, `:flee`) — NEVER
      appear in `hostiles` regardless of which reactions list is in
      play.
    * `action_status` filter — a defender that's mid-action (e.g.
      `:raid`, `:moving`) is NOT a hostile candidate, even with the
      right reaction. Only `:idle` and `:docking` qualify.
    * Same-faction filter — own-faction admirals are NEVER in
      `hostiles`, even with aggressive reactions, no matter how many
      of them are on the system.
    * Race / stale state — when a defender's `:get_state` returns
      `nil` (unreachable / crashed), they're dropped from `hostiles`
      and the engagement proceeds without them.

  ## Why this exists

  The original Bug 1 report (`raid` from T against G:defend produces
  no combat) is unexplained by static reading of the code. These
  scenarios reproduce the production filter pipeline deterministically
  so any regression to the predicate logic — or a new edge case
  surfaces from a live repro — can be pinned with a single failing
  test rather than re-inferred from logs.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Actions.Fight
  alias Test.FleetScenario

  ## Bug-1 happy path: raid's interception list catches :defend

  describe "raid.start interception list ([:defend, :attack_enemies, :attack_everyone])" do
    test "G:defend on the target system IS in hostiles when T raids — the original Bug 1 scenario" do
      iid = FleetScenario.unique_instance_id()

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
          system: 10,
          reaction: :defend,
          action_status: :idle
        )

      t =
        FleetScenario.build_character(
          instance_id: iid,
          character_id: 2,
          faction: :crow,
          system: 10
        )

      raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

      {_system, hostiles} =
        Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      assert length(hostiles) == 1,
             "raid's reactions list (which includes :defend) MUST select G:defend as a hostile — this is the contract Bug 1 was reported against"

      [g_hostile] = hostiles
      assert g_hostile.id == 1
      assert g_hostile.army.reaction == :defend
    end
  end

  ## Cold-war: Jump.finish's interception list excludes :defend

  describe "Jump.finish interception list ([:attack_enemies, :attack_everyone])" do
    test "G:defend on the arrival system is NOT in hostiles — armed neutrality" do
      iid = FleetScenario.unique_instance_id()
      g_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [g_summary]
      )

      FleetScenario.spawn_fake_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :phoenix,
        system: 10,
        reaction: :defend,
        action_status: :idle
      )

      t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
      jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

      {_system, hostiles} = Fight.find_hostiles(t, jump_action, [:attack_enemies, :attack_everyone])

      assert hostiles == [],
             "Jump.finish must NOT engage :defend on arrival — that's the armed-neutrality contract"
    end

    test "G:attack_enemies on the arrival system IS in hostiles" do
      iid = FleetScenario.unique_instance_id()
      g_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [g_summary]
      )

      FleetScenario.spawn_fake_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :phoenix,
        system: 10,
        reaction: :attack_enemies,
        action_status: :idle
      )

      t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
      jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

      {_system, hostiles} = Fight.find_hostiles(t, jump_action, [:attack_enemies, :attack_everyone])

      assert length(hostiles) == 1, "aggressive reactions DO engage on arrival"
    end
  end

  ## Passive reactions never intercept

  describe "passive reactions" do
    for {reaction, description} <- [{:fight_back, "Prudent"}, {:flee, "Deserter"}] do
      @reaction reaction
      @description description

      test "G:#{@reaction} (#{@description}) is NOT in hostiles even with the full hostile-action reactions list" do
        iid = FleetScenario.unique_instance_id()
        g_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix)

        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: iid,
          system_id: 10,
          characters: [g_summary]
        )

        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 1,
          faction: :phoenix,
          system: 10,
          reaction: @reaction,
          action_status: :idle
        )

        t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
        raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

        assert hostiles == [],
               ":#{@reaction} is passive — never intercepts, even when its system is being raided"
      end
    end
  end

  ## action_status filter

  describe "action_status filter" do
    for status <- [:idle, :docking] do
      @status status

      test "G:defend with action_status=#{@status} IS in hostiles" do
        iid = FleetScenario.unique_instance_id()
        g_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix)

        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: iid,
          system_id: 10,
          characters: [g_summary]
        )

        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 1,
          faction: :phoenix,
          system: 10,
          reaction: :defend,
          action_status: @status
        )

        t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
        raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

        assert length(hostiles) == 1, "action_status=#{@status} is in the [:idle, :docking] allow-list"
      end
    end

    for status <- [:moving, :raid, :loot, :conquest, :fight] do
      @status status

      test "G:defend with action_status=#{@status} is NOT in hostiles — already busy" do
        iid = FleetScenario.unique_instance_id()
        g_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix)

        FleetScenario.spawn_fake_stellar_system(self(),
          instance_id: iid,
          system_id: 10,
          characters: [g_summary]
        )

        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 1,
          faction: :phoenix,
          system: 10,
          reaction: :defend,
          action_status: @status
        )

        t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
        raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

        assert hostiles == [],
               "an admiral already executing action_status=#{@status} cannot intercept — they're not idle"
      end
    end
  end

  ## Same-faction filter

  describe "same-faction filter" do
    test "an own-faction :attack_everyone admiral on the target system is NOT in hostiles" do
      iid = FleetScenario.unique_instance_id()
      ally_summary = FleetScenario.build_system_character(character_id: 1, faction: :crow)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [ally_summary]
      )

      FleetScenario.spawn_fake_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :crow,
        system: 10,
        reaction: :attack_everyone,
        action_status: :idle
      )

      t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
      raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

      {_system, hostiles} =
        Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      assert hostiles == [],
             "own-faction filter must run BEFORE the reaction filter — :attack_everyone never targets allies"
    end
  end

  ## Race: unreachable character agent

  describe "race / stale state" do
    test "a system.characters entry whose Character.Agent is unreachable is dropped from hostiles, not crashed on" do
      iid = FleetScenario.unique_instance_id()

      ghost_summary =
        FleetScenario.build_system_character(character_id: 999, faction: :phoenix)

      real_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [ghost_summary, real_summary]
      )

      # Spawn only the real one — character_id 999's process never
      # started (or was killed), simulating the post-crash race where
      # stellar_system still thinks an admiral is on board but the
      # character process is gone.
      FleetScenario.spawn_fake_character(self(),
        instance_id: iid,
        character_id: 1,
        faction: :phoenix,
        system: 10,
        reaction: :defend,
        action_status: :idle
      )

      t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
      raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

      {_system, hostiles} =
        Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      # The ghost is dropped (its :get_state returned :process_not_found
      # which the filter maps to nil), the real one remains.
      assert length(hostiles) == 1
      assert hd(hostiles).id == 1
    end

    test "post-fight state mutation: a defender flipped to :moving mid-test stops being a hostile" do
      iid = FleetScenario.unique_instance_id()
      g_summary = FleetScenario.build_system_character(character_id: 1, faction: :phoenix)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [g_summary]
      )

      {_g, g_pid} =
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 1,
          faction: :phoenix,
          system: 10,
          reaction: :defend,
          action_status: :idle
        )

      t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
      raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

      # Sanity: before the mutation, G is hostile.
      {_, hostiles_before} =
        Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      assert length(hostiles_before) == 1

      # Race simulation: G launches its own action between the
      # stellar_system snapshot and the character-state lookup, so
      # action_status flips off :idle. The filter must drop G now.
      :ok =
        GenServer.call(g_pid, {:update, fn c -> %{c | action_status: :moving} end})

      {_, hostiles_after} =
        Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      assert hostiles_after == [],
             "the filter re-reads action_status fresh from the character agent every call — a stale system.characters entry can't keep a busy defender in the hostiles list"
    end
  end

  ## Multiple hostiles

  describe "multiple hostiles" do
    test "two cross-faction defenders both qualify — engagement faces both" do
      iid = FleetScenario.unique_instance_id()

      g1 = FleetScenario.build_system_character(character_id: 1, faction: :phoenix)
      g2 = FleetScenario.build_system_character(character_id: 2, faction: :phoenix)

      FleetScenario.spawn_fake_stellar_system(self(),
        instance_id: iid,
        system_id: 10,
        characters: [g1, g2]
      )

      for {id, reaction} <- [{1, :defend}, {2, :attack_enemies}] do
        FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: id,
          faction: :phoenix,
          system: 10,
          reaction: reaction,
          action_status: :idle
        )
      end

      t = FleetScenario.build_character(instance_id: iid, character_id: 99, faction: :crow, system: 10)
      raid_action = FleetScenario.build_action(:raid, %{"target" => 10})

      {_system, hostiles} =
        Fight.find_hostiles(t, raid_action, [:defend, :attack_enemies, :attack_everyone])

      ids = hostiles |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == [1, 2], "both defenders match the raid reactions list, so both are in hostiles"
    end
  end
end
