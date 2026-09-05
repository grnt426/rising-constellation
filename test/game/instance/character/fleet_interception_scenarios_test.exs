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
      `:raid`, `:loot`) never INTERCEPTS, even with the right
      reaction. Only `:idle` and `:docking` intercept. It can still be
      ENGAGED by an arriving Fury or Defender fleet (pass 1 of the
      two-pass arrival check, `Jump.arrival_engagement/1`) — a fleet
      in transit (`:moving`/`:attached`) or already in a battle
      (`:fight`) is the only thing that is never a candidate.
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
  alias Instance.Character.Actions.Jump
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

  ## Two-pass arrival check — pass 1 is the ARRIVER's own stance

  describe "Jump.arrival_engagement/1 — what the arriver engages on its own initiative" do
    test "Fury (:attack_everyone) engages every fleet present, busy or not" do
      assert Jump.arrival_engagement(:attack_everyone) == :all,
             "Fury's contract is 'attack any unallied admiral within range' — including a sitter mid-pillage that could never intercept on its own (instance 121, Benkad/Adenarjah, 2026-09-05)"
    end

    test "Defender (:defend) engages only fleets busy with a hostile action" do
      assert Jump.arrival_engagement(:defend) == :busy,
             "a Defender arriving on a pillaging enemy fights it; idle enemies are left alone so factions under a non-aggression pact can share systems"
    end

    for arriver_reaction <- [:attack_enemies, :fight_back, :flee] do
      @arriver_reaction arriver_reaction

      test ":#{@arriver_reaction} arriver engages nobody on its own initiative" do
        assert Jump.arrival_engagement(@arriver_reaction) == :none,
               "Interdiction watches the door but does not pick fights when it is itself the arrival; the passive stances never initiate"
      end
    end

    test "the sitter side of an arrival (pass 2) is always Interdiction + Fury" do
      assert Jump.arrival_reactions() == [:attack_enemies, :attack_everyone],
             ":defend sitters do not intercept bare arrivals (armed neutrality); the passive stances never intercept"
    end
  end

  describe "Fury arriver — engages every present sitter" do
    for {sitter_reaction, sitter_label} <- [
          {:defend, "Defender"},
          {:fight_back, "Prudent"},
          {:flee, "Deserter"},
          {:attack_enemies, "Interdiction"},
          {:attack_everyone, "Fury"}
        ] do
      @sitter_reaction sitter_reaction
      @sitter_label sitter_label

      test "Fury arriver vs idle G:#{@sitter_reaction} (#{@sitter_label}) sitter — engages exactly once" do
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
          reaction: @sitter_reaction,
          action_status: :idle
        )

        t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
        jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(:attack_everyone))

        # An Interdiction/Fury sitter matches BOTH passes — it must still
        # appear once, or the engagement loop would fight it twice.
        assert length(hostiles) == 1,
               "Fury arriver MUST engage a :#{@sitter_reaction} sitter exactly once — the long-standing 'Fury fleet ignores enemy at destination' bug"

        [g_hostile] = hostiles
        assert g_hostile.id == 1
        assert g_hostile.army.reaction == @sitter_reaction
      end
    end

    for status <- [:loot, :raid, :conquest, :colonization, :make_dominion, :docking] do
      @status status

      test "Fury arriver vs G:defend sitter with action_status=#{@status} — engages (busy sitters are attackable)" do
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
        jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(:attack_everyone))

        assert length(hostiles) == 1,
               "a sitter busy with action_status=#{@status} cannot intercept, but a Fury arriver engages it anyway — instance 121: Séliane Beketh pillaging Benkad, Bralie de Belmezir colonizing Adenarjah"
      end
    end

    for status <- [:moving, :attached, :fight] do
      @status status

      test "Fury arriver vs G with action_status=#{@status} — NOT engaged (not physically present)" do
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
          reaction: :attack_everyone,
          action_status: @status
        )

        t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
        jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(:attack_everyone))

        assert hostiles == [],
               "action_status=#{@status} means in transit or already inside a battle — never a combat candidate, even for Fury"
      end
    end
  end

  describe "Defender arriver — engages only busy sitters" do
    for status <- [:loot, :raid, :conquest, :colonization, :make_dominion],
        sitter_reaction <- [:defend, :flee] do
      @status status
      @sitter_reaction sitter_reaction

      test "Defender arriver vs G:#{@sitter_reaction} sitter with action_status=#{@status} — engages" do
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
          reaction: @sitter_reaction,
          action_status: @status
        )

        t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
        jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(:defend))

        assert length(hostiles) == 1,
               "a Defender arriving on an enemy mid-#{@status} engages it whatever the enemy's own stance — Defender's purpose is to stop hostile acts"
      end
    end

    for status <- [:idle, :docking] do
      @status status

      test "Defender arriver vs G:defend sitter with action_status=#{@status} — cold war, no engagement" do
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
        jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(:defend))

        assert hostiles == [],
               "an idle or ship-building enemy is not a hostile act — :defend arriver vs :defend sitter stays the armed-neutrality case, which is what keeps Defender distinct from Fury"
      end
    end

    test "Defender arriver vs idle Interdiction sitter — the SITTER intercepts (pass 2)" do
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

      {_system, hostiles} =
        Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(:defend))

      assert length(hostiles) == 1, "Interdiction's whole job is to catch arrivals, whatever the arriver's stance"
    end
  end

  describe "Interdiction and passive arrivers — pass 2 only" do
    for arriver_reaction <- [:attack_enemies, :fight_back, :flee] do
      @arriver_reaction arriver_reaction

      test ":#{@arriver_reaction} arriver vs busy G:attack_everyone sitter — no engagement (busy sitters never intercept)" do
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
          reaction: :attack_everyone,
          action_status: :loot
        )

        t = FleetScenario.build_character(instance_id: iid, character_id: 2, faction: :crow, system: 10)
        jump_action = FleetScenario.build_action(:jump, %{"target" => 10})

        {_system, hostiles} =
          Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(@arriver_reaction))

        assert hostiles == [],
               "even a Fury sitter does not break off its pillage to intercept, and a :#{@arriver_reaction} arriver engages nobody on its own"
      end
    end

    test "Interdiction (:attack_enemies) arriver vs idle :defend sitter still does NOT engage" do
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

      {_system, hostiles} =
        Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(:attack_enemies))

      assert hostiles == [],
             "Interdiction's contract is 'intercept incoming' only — when Interdiction IS the incoming, a :defend sitter stays peaceful"
    end

    test "Interdiction arriver vs idle Interdiction sitter — the sitter intercepts (the documented asymmetry)" do
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

      {_system, hostiles} =
        Fight.find_hostiles(t, jump_action, Jump.arrival_reactions(), Jump.arrival_engagement(:attack_enemies))

      assert length(hostiles) == 1,
             "two Interdiction fleets only leave each other alone once they already share a system; the sitter always catches the arrival"
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

  ## action_status filter — applies to INTERCEPTORS (pass 2) only

  describe "action_status filter on interceptors" do
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

    for status <- [:moving, :attached, :raid, :loot, :conquest, :colonization, :make_dominion, :fight] do
      @status status

      test "G:defend with action_status=#{@status} does NOT intercept a hostile action — already busy" do
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
               "an admiral already executing action_status=#{@status} never breaks off to intercept (it can still be ENGAGED by an arriving Fury/Defender — see the arrival describes above)"
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
