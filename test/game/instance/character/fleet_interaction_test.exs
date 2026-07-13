defmodule Character.FleetInteractionTest do
  @moduledoc """
  Tests for the fleet interaction reaction model and the
  `Character.flee` queued-path bug.

  ## Reaction-model contract

  Five reactions exist (see `Instance.Character.Army`):

    * `:attack_everyone` (Fury) — aggressive in BOTH directions:
      engages any cross-faction admiral that enters this fleet's
      system AND any cross-faction admiral already present when this
      fleet arrives. Fury is the only stance whose arrival side
      triggers an engagement against passive sitters.
    * `:attack_enemies` (Interdiction) — aggressive on the
      defender side only: intercepts cross-faction admirals that
      ARRIVE at this fleet's system, but does NOT pick a fight when
      it is itself the arriving fleet. This is what keeps
      Interdiction distinct from Fury and lets two cooperating
      factions both run Interdiction over the same system without
      firing on each other in transit.
    * `:defend` (Defender) — *armed-neutrality*: does NOT intercept
      bare arrivals or pass-throughs. Only engages cross-faction
      admirals that perform a hostile *in-system* action (raid, loot,
      conquest, colonization). This lets two `:defend` fleets from
      different factions occupy or pass through the same system without
      firing — the "cold war" use case.
    * `:fight_back` (Prudent) — passive: never intercepts on its
      own. A Fury arriver can still engage it; once attacked it
      fights normally.
    * `:flee` (Deserter) — passive: never intercepts on its own. A
      Fury arriver can still engage it; once attacked it tries to
      escape.

  The split is enforced in code by which reactions appear in each
  action's `check_interception` call:

    * `Jump.finish` → `Jump.interception_reactions(arriver.reaction)`:
      for non-Fury arrivers this is `[:attack_enemies, :attack_everyone]`
      (arrival only catches the aggressive stances); for a Fury
      arriver this is the full list `[:flee, :fight_back, :defend,
      :attack_enemies, :attack_everyone]` (Fury's third trigger).
    * `Raid.start`, `Loot.start`, `Conquest.start`,
      `Colonization.start` → `[:defend, :attack_enemies,
      :attack_everyone]` (these are the hostile in-system actions
      defenders are supposed to intercept).

  ## Character.flee bug

  `ActionQueue.set_virtual_position_and_clear/1` pops the front action
  and sets `virtual_position` to **that action's target**. That fits
  the spy `lose_cover/2` path (a mid-jump spy is committed to its
  destination), but breaks `Character.flee/2` when the character is
  standing on `state.system` with a multi-hop queue: the popped
  action's target is one hop *ahead* of the character, so the flee
  jump's `source = state.system` no longer matches `virtual_position`.
  `Jump.pre_validate` throws `:invalid_position`, `pre_validate_action`
  swallows the throw, and the flee jump silently never enters the
  queue. `Character.flee/2` was rewritten to clear the queue and pin
  `virtual_position` to the character's actual system before adding the
  flee jump.
  """
  use ExUnit.Case, async: true

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Actions.Jump
  alias Instance.Character.Character

  describe "reaction model — arrival vs hostile-action interception" do
    test "Jump.finish only intercepts AGGRESSIVE reactions for non-Fury arrivers, NOT :defend" do
      # Arrival interception for a non-Fury arriver fires only for
      # `:attack_enemies` and `:attack_everyone`. `:defend` is
      # deliberately excluded — a defender's job is to intervene
      # against hostile in-system actions (raid/loot/conquest/
      # colonization), not against the bare fact that a cross-faction
      # admiral entered the system. Including `:defend` here would
      # break the armed-neutrality contract: two `:defend` fleets from
      # opposing factions could no longer coexist in the same system.
      #
      # Fury (`:attack_everyone`) is the documented exception — its
      # arrival list is broadened to ALL stances so a Fury arriver
      # engages anything cross-faction it lands on. That's covered by
      # the next test.
      for arriver_reaction <- [:defend, :attack_enemies, :fight_back, :flee] do
        assert Jump.interception_reactions(arriver_reaction) ==
                 [:attack_enemies, :attack_everyone],
               """
               Jump.interception_reactions(#{inspect(arriver_reaction)}) must
               return exactly [:attack_enemies, :attack_everyone]. Including
               :defend would make Interdiction (:attack_enemies) and Fury
               (:attack_everyone) behaviorally identical on arrival and
               break the armed-neutrality contract for :defend arrivers.
               """

        refute :defend in Jump.interception_reactions(arriver_reaction),
               "non-Fury arriver (#{inspect(arriver_reaction)}) must NOT trigger engagement against :defend sitters — see armed-neutrality rationale above"
      end
    end

    test "Fury (:attack_everyone) arriver broadens the Jump.finish list to ALL stances" do
      # Fury's third trigger: when the Fury fleet IS the arriver, it
      # engages every cross-faction admiral on the destination
      # system regardless of their stance — including the passive
      # ones (:flee / :fight_back) and the cold-war :defend. This is
      # the only place in the engagement model where a defender's
      # own stance is overridden.
      reactions = Jump.interception_reactions(:attack_everyone)

      for required <- [:flee, :fight_back, :defend, :attack_enemies, :attack_everyone] do
        assert required in reactions,
               """
               Fury arriver's interception list must include
               #{inspect(required)} — Fury's contract is "attack any
               unallied admiral within range," and that includes
               unallied admirals already sitting in the destination
               system, regardless of their own stance.
               """
      end
    end

    test "hostile in-system actions include :defend in their interception lists" do
      # These are the action-types defenders ARE supposed to intercept:
      # raid (bombard), loot (pillage), conquest, colonization. Each
      # one's `start/2` calls check_interception with :defend in the
      # reactions list. Together with the Jump.finish behavior above,
      # this gives :defend its "intervene against hostile actions, not
      # against arrivals" contract.
      for path <- [
            "lib/game/instance/character/actions/raid.ex",
            "lib/game/instance/character/actions/loot.ex",
            "lib/game/instance/character/actions/conquest.ex",
            "lib/game/instance/character/actions/colonization.ex"
          ] do
        src = File.read!(path)

        assert src =~ ~r/check_interception\(character,\s*action,\s*\[:defend,/,
               "#{path}: check_interception must include :defend — defenders intercept this hostile in-system action by contract"
      end
    end

    test ":fight_back and :flee are excluded from every interception list" do
      # The two passive reactions never intercept anyone. :fight_back
      # ("no reaction unless directly attacked") and :flee ("tries to
      # flee when attacked") only react to a direct attack, never to a
      # cross-faction arrival or a hostile action against the system.
      for path <- [
            "lib/game/instance/character/actions/jump.ex",
            "lib/game/instance/character/actions/raid.ex",
            "lib/game/instance/character/actions/loot.ex",
            "lib/game/instance/character/actions/conquest.ex",
            "lib/game/instance/character/actions/colonization.ex"
          ] do
        src = File.read!(path)

        refute src =~ ~r/check_interception\([^)]*:fight_back/,
               "#{path}: :fight_back must NOT appear in any check_interception reactions list — passive reactions only fire when directly attacked"

        refute src =~ ~r/check_interception\([^)]*\[:flee/,
               "#{path}: :flee must NOT appear in any check_interception reactions list — fleeing admirals never intercept"
      end
    end

    test "the reactions lists are EXACTLY as the contract specifies" do
      # Pin the exact reactions list each action uses, so a refactor
      # that adds or drops a reaction in any of them has to come
      # through this test.
      #
      # Arrival (Jump.finish): a non-Fury arriver gets
      # [:attack_enemies, :attack_everyone] (aggressives only). A Fury
      # arriver gets the full list (the third Fury trigger). Pinned
      # via the public helper so the source shape of Jump.finish is
      # free to change as long as the matrix stays the same.
      assert Jump.interception_reactions(:defend) == [:attack_enemies, :attack_everyone]
      assert Jump.interception_reactions(:attack_enemies) == [:attack_enemies, :attack_everyone]
      assert Jump.interception_reactions(:fight_back) == [:attack_enemies, :attack_everyone]
      assert Jump.interception_reactions(:flee) == [:attack_enemies, :attack_everyone]

      assert Jump.interception_reactions(:attack_everyone) ==
               [:flee, :fight_back, :defend, :attack_enemies, :attack_everyone]

      # Hostile in-system actions: source-grep guard for the
      # `[:defend, :attack_enemies, :attack_everyone]` list. These
      # four sites haven't been refactored to use a helper, so the
      # literal-regex check still applies.
      hostile_action_reactions =
        ~r/check_interception\(character,\s*action,\s*\[:defend,\s*:attack_enemies,\s*:attack_everyone\]\)/

      for path <- [
            "lib/game/instance/character/actions/raid.ex",
            "lib/game/instance/character/actions/loot.ex",
            "lib/game/instance/character/actions/conquest.ex",
            "lib/game/instance/character/actions/colonization.ex"
          ] do
        assert File.read!(path) =~ hostile_action_reactions,
               "#{path}: must call check_interception with exactly [:defend, :attack_enemies, :attack_everyone]"
      end
    end
  end

  describe "Character.flee — queued-path flee no longer dropped" do
    test "ActionQueue.set_virtual_position_and_clear pops the front action's target — the misbehavior flee used to inherit" do
      # This documents the underlying semantics of
      # set_virtual_position_and_clear that broke flee. The function
      # pops the *front* action and uses ITS target as the new
      # virtual_position. For a character mid-flight (e.g. a spy who
      # lost cover) this is correct — they will land on that target. For
      # a character standing on state.system with a queued path, the
      # front action has not started yet, so virtual_position ends up
      # ONE HOP AHEAD of where the character actually is.
      queue = [
        jump_action(source: 3, target: 4),
        jump_action(source: 4, target: 5)
      ]

      actions = %ActionQueue{
        queue: Queue.new(queue),
        virtual_position: 5
      }

      result = ActionQueue.set_virtual_position_and_clear(actions)

      assert result.virtual_position == 4,
             "set_virtual_position_and_clear pops the front action (S3→S4) and sets virtual_position to its target (S4)"

      assert ActionQueue.empty?(result),
             "the queue is emptied — both Jump 3→4 and Jump 4→5 are discarded"
    end

    test "the new flee pattern: clear queue + pin virtual_position to current system" do
      # The fix is to use clear_actions + set_virtual_position(state.system)
      # so that virtual_position matches the source of the flee jump
      # we're about to add. With virtual_position == state.system, the
      # flee jump's `source = state.system` passes the
      # `virtual_position != source` guard in Jump.pre_validate and the
      # jump is queued.
      character = build_character_with_queued_path(system: 3, queue_targets: [4, 5])

      assert character.system == 3

      assert character.actions.virtual_position == 5,
             "before flee: the queued path has the character ending at S5"

      cleared =
        character
        |> Character.clear_actions()
        |> Character.set_virtual_position(character.system)

      assert ActionQueue.empty?(cleared.actions),
             "clear_actions empties the queue (Jump 3→4 and Jump 4→5 discarded — fleeing abandons the path)"

      assert cleared.actions.virtual_position == 3,
             "set_virtual_position(state.system) pins virtual_position to S3 so the flee jump (source=S3) will pass pre_validate"
    end

    test "the OLD flee pattern fails the Jump.pre_validate guard when there's a queued path" do
      # Reproduces the exact failure that hid the flee jump in production:
      # after set_virtual_position_and_clear with a queued path,
      # virtual_position is one hop ahead of state.system. The flee
      # jump's source = state.system, so the guard
      # `virtual_position != source, do: throw(:invalid_position)`
      # fires.
      character = build_character_with_queued_path(system: 3, queue_targets: [4, 5])

      # Reproduce the OLD body of Character.flee/2 (without actually
      # adding the jump — we just want to show the virtual_position
      # produced by the old pattern conflicts with the flee jump's
      # source). The set_virtual_position_and_clear call here returns
      # the actions state with virtual_position = 4 (Jump 3→4's target),
      # NOT state.system (3).
      after_old_clear = ActionQueue.set_virtual_position_and_clear(character.actions)

      flee_jump_source = character.system

      assert after_old_clear.virtual_position == 4,
             "OLD bug: virtual_position is set to the popped action's target (S4), not the character's location"

      assert after_old_clear.virtual_position != flee_jump_source,
             """
             OLD bug: virtual_position (S4) != flee jump's source (S3).
             This is exactly the mismatch that made
             Jump.pre_validate throw :invalid_position, which
             pre_validate_action silently swallowed, dropping the flee
             jump and leaving the character with an empty queue and a
             stale virtual_position.
             """
    end

    test "Character.flee/2 source contains the fixed clear_actions + set_virtual_position pattern" do
      # Belt-and-suspenders source check: if a refactor reintroduces
      # set_virtual_position_and_clear inside flee, this test fires.
      src = File.read!("lib/game/instance/character/character.ex")

      # `\bend\b` requires a word boundary so the non-greedy match
      # doesn't stop at "end" inside words like "ends", "depends", etc.
      # that may appear in the function's docstring/comments.
      flee_body =
        Regex.run(
          ~r/def flee\(%Character\.Character\{type: :admiral\} = state, target_id\) do\s+.*?\bend\b/s,
          src
        )
        |> List.first()

      assert flee_body =~ "clear_actions()",
             "Character.flee must clear the queue with clear_actions/1"

      assert flee_body =~ "set_virtual_position(state.system)",
             "Character.flee must pin virtual_position to state.system before adding the flee jump"

      # The OLD body called `|> set_virtual_position_and_clear()` in the
      # pipeline. The comment above the new body still mentions the
      # helper to explain *why* we don't use it, so we look for the
      # pipe-call shape specifically, not the bare identifier.
      refute flee_body =~ ~r/\|>\s*set_virtual_position_and_clear\(/,
             """
             Character.flee must NOT call set_virtual_position_and_clear:
             that helper pops the front action and sets virtual_position
             to its target, leaving virtual_position one hop ahead of
             the character. The flee jump's source = state.system then
             fails Jump.pre_validate's `virtual_position != source`
             guard and the flee jump is silently dropped.
             """
    end

    test "flee from an empty-queue character still produces the correct virtual_position" do
      # Defensive case: a character whose queue is already empty (e.g.
      # fleeing while idle) still needs virtual_position == state.system
      # so the flee jump's pre_validate passes.
      character = build_idle_character(system: 7)

      assert character.system == 7
      assert ActionQueue.empty?(character.actions)

      cleared =
        character
        |> Character.clear_actions()
        |> Character.set_virtual_position(character.system)

      assert cleared.actions.virtual_position == 7
      assert ActionQueue.empty?(cleared.actions)
    end
  end

  ## Helpers

  defp jump_action(opts) do
    source = Keyword.fetch!(opts, :source)
    target = Keyword.fetch!(opts, :target)

    %Action{
      type: :jump,
      data: %{
        "source" => source,
        "target" => target,
        "source_position" => %Spatial.Position{x: source * 1.0, y: 0.0},
        "target_position" => %Spatial.Position{x: target * 1.0, y: 0.0}
      },
      total_time: 5,
      remaining_time: 5,
      started_at: nil,
      cumulated_pauses: nil
    }
  end

  # Builds a Character struct representing a fleet that just landed on
  # `system` with a queue of further jumps still ahead — i.e. the state
  # `Character.flee/2` was failing on in Bug 2.
  defp build_character_with_queued_path(opts) do
    system = Keyword.fetch!(opts, :system)
    targets = Keyword.fetch!(opts, :queue_targets)

    # Build the chain: state.system → targets[0] → targets[1] → ...
    {jumps, _} =
      Enum.map_reduce(targets, system, fn target, source ->
        {jump_action(source: source, target: target), target}
      end)

    final_target = List.last(targets)

    actions = %ActionQueue{
      queue: Queue.new(jumps),
      virtual_position: final_target
    }

    # We use struct/2 (which bypasses @enforce_keys) so the test doesn't
    # have to thread the ~20 other fields of Instance.Character.Character.
    struct(Character, %{
      id: 1,
      instance_id: 1,
      type: :admiral,
      status: :on_board,
      system: system,
      action_status: :idle,
      actions: actions,
      owner: %Instance.Character.Player{id: 1, name: "Test", faction: :phoenix, faction_id: 1},
      army: minimal_army()
    })
  end

  defp build_idle_character(opts) do
    system = Keyword.fetch!(opts, :system)

    actions = %ActionQueue{
      queue: Queue.new(),
      virtual_position: system
    }

    struct(Character, %{
      id: 1,
      instance_id: 1,
      type: :admiral,
      status: :on_board,
      system: system,
      action_status: :idle,
      actions: actions,
      owner: %Instance.Character.Player{id: 1, name: "Test", faction: :phoenix, faction_id: 1},
      army: minimal_army()
    })
  end

  defp minimal_army do
    %Instance.Character.Army{
      tiles: [],
      reaction: :defend,
      maintenance: Core.Value.new(),
      repair_coef: Core.Value.new(),
      invasion_coef: Core.Value.new(),
      raid_coef: Core.Value.new()
    }
  end
end
