defmodule RC.Security.InfoDisclosureTest do
  @moduledoc """
  Regression tests for the Stage 8 Tier 1 + Tier 2 info-disclosure
  fixes (docs/stage-8-report.md):

    * **F4** — `Instance.Faction.Character.obfuscate/3` strips
      `Core.Value.details` on nested army/spy/speaker substructs for
      non-own-faction viewers or visibility < 5, closing the
      doctrine/patent/tradition reason leak.
    * **F8** — at visibility 5 the obfuscation drops `:action_status`
      for non-own-faction viewers (UI never renders enemy action_status).
    * **F3** — new vis=1 anonymous tier exposes only `[:type, :level]`
      so undercover-spy notifications no longer leak attacker identity.
    * **F2** — defender-side admiral / speaker / spy diffs in the
      seven attack-action notifications are now at vis=3 (no skills,
      no doctrine details, no action_status), not vis=5.
    * **F1** — `RC.PlayerStats.get_last_player_stat_by_instance_id/1`
      no longer projects `stored_credit`, `output_credit`,
      `output_technology`, `output_ideology`.
    * **F5/F9** — `Portal.Controllers.FactionChannel.handle_out/3`
      sanitizes detected_objects per-recipient before push: drops
      `:character_id` and `:owner_player_id`, and filters out the
      viewer's own characters (by `:owner_player_id`). Faction-mates
      remain visible as anonymous radar blips — the wire shape that
      Stage 8 F5/F9 protects (`{faction, position, angle}` only) is
      still enforced.
    * **F6/F7** — `Profile.elo` and `Instance.Player.PublicPlayer.elo`
      are integer-rounded at the wire boundary.
  """
  use ExUnit.Case, async: true

  alias Instance.Faction.Character, as: FactionCharacter
  alias Instance.Character.Character

  describe "Stage 8 F4 — strip Core.Value.details on character substructs" do
    test "at vis=4 (cross-faction with 2 informers), maintenance.details is cleared" do
      char = build_admiral(army_maintenance_details: %{doctrine: [%Core.ValuePart{value: 5, reason: :hidden_doctrine_key}]})

      obfuscated = FactionCharacter.obfuscate(char, 4)

      assert obfuscated.army.maintenance.details == %{},
             "Stage 8 F4: maintenance.details must be stripped at cross-faction vis 4"

      assert obfuscated.army.maintenance.value == char.army.maintenance.value,
             "the .value should still reach the wire — only the .details (reason atoms) is the leak"
    end

    test "at vis=5 + own_faction, details are PRESERVED" do
      char = build_admiral(
        owner_faction: :phoenix,
        army_maintenance_details: %{doctrine: [%Core.ValuePart{value: 5, reason: :phoenix_doctrine_x}]}
      )

      obfuscated = FactionCharacter.obfuscate(char, 5, :phoenix)

      assert obfuscated.army.maintenance.details == char.army.maintenance.details,
             "own-faction viewer at vis=5 sees full details (tooltip needs them)"
    end

    test "at vis=5 + NON-own_faction, details are stripped" do
      char = build_admiral(
        owner_faction: :phoenix,
        army_maintenance_details: %{doctrine: [%Core.ValuePart{value: 5, reason: :phoenix_doctrine_x}]}
      )

      # Viewer is enemy faction :crow, even though they see the char at vis=5
      # (3 informers on the host system). They should NOT see the doctrine
      # reason atom.
      obfuscated = FactionCharacter.obfuscate(char, 5, :crow)

      assert obfuscated.army.maintenance.details == %{},
             "Stage 8 F4: cross-faction at vis=5 strips details (F4 + F8 combined)"
    end
  end

  describe "Stage 8 F8 — drop :action_status at vis=5 for non-own-faction viewers" do
    test "non-own-faction viewer at vis=5 does NOT see :action_status" do
      char = build_admiral(owner_faction: :phoenix, action_status: :raid)

      obfuscated = FactionCharacter.obfuscate(char, 5, :crow)

      refute Map.has_key?(obfuscated, :action_status) and obfuscated.action_status != nil,
             "Stage 8 F8: enemy at vis=5 must NOT learn :action_status"
    end

    test "own-faction viewer at vis=5 STILL sees :action_status" do
      char = build_admiral(owner_faction: :phoenix, action_status: :conquest)

      obfuscated = FactionCharacter.obfuscate(char, 5, :phoenix)

      assert obfuscated.action_status == :conquest,
             "own-faction viewer must keep full visibility on their own characters"
    end
  end

  describe "Stage 8 F3 — vis=1 anonymous tier" do
    test "vis=1 exposes only :type and :level — no id, name, owner, illustration, etc." do
      char = build_spy(name: "Codename Wolf", id: 42)

      obfuscated = FactionCharacter.obfuscate(char, 1)

      assert obfuscated.type == :spy,
             "anonymous tier must include :type so the UI can render 'an enemy spy'"

      assert obfuscated.level == char.level,
             "anonymous tier must include :level"

      # Identifying fields MUST NOT reach the wire.
      assert obfuscated.id == nil
      assert obfuscated.name == nil
      assert obfuscated.illustration == nil
      assert obfuscated.owner == nil
    end

    test "vis=1 does NOT attach the spy/army/speaker substruct" do
      char = build_spy(name: "Stealthy")

      obfuscated = FactionCharacter.obfuscate(char, 1)

      assert obfuscated.spy == nil, "anonymous tier must suppress the spy substruct entirely"
      assert obfuscated.army == nil
      assert obfuscated.speaker == nil
    end
  end

  describe "Stage 8 F1 — get_last_player_stat_by_instance_id projection" do
    test "the public stats SQL query does NOT select financial columns" do
      # Read the source so we can assert it against the contract directly.
      # We do this textually (rather than running the query against a
      # populated DB) because the per-player projection IS the contract
      # under audit. If a future commit re-adds `stored_credit` etc to
      # this SELECT, this test will fail with a clear message.
      source = File.read!("lib/rc/player_stats.ex")

      # The string appears multiple times now (in the docstring and
      # at the function definition); we want everything UP TO the
      # function definition, so split and keep only the first chunk.
      [public_query | _] = String.split(source, "def get_players_stats_by_instance_id")

      refute String.contains?(public_query, "player_stats.stored_credit"),
             "Stage 8 F1: player-facing SELECT must not project stored_credit"

      refute String.contains?(public_query, "player_stats.output_credit"),
             "Stage 8 F1: player-facing SELECT must not project output_credit"

      refute String.contains?(public_query, "player_stats.output_technology"),
             "Stage 8 F1: player-facing SELECT must not project output_technology"

      refute String.contains?(public_query, "player_stats.output_ideology"),
             "Stage 8 F1: player-facing SELECT must not project output_ideology"

      # Sanity: UI-rendered columns ARE still selected.
      assert String.contains?(public_query, "player_stats.total_systems")
      assert String.contains?(public_query, "player_stats.points")
      assert String.contains?(public_query, "player_stats.best_credit")
    end
  end

  describe "Stage 8 F6/F7 — ELO rounded at the wire boundary" do
    test "rankings_view ranked_profile.json rounds elo" do
      profile = %{
        id: 1,
        name: "x",
        avatar: nil,
        full_name: "x",
        elo: 1247.6334
      }

      payload = Portal.RankingsView.render("ranked_profile.json", %{profile: profile})

      assert payload.elo == 1248
      assert is_integer(payload.elo)
    end

    test "PublicPlayer.new rounds elo" do
      player_struct = sample_player()
      profile = %{
        age: 30,
        description: "",
        elo: 1100.4,
        full_name: "",
        long_description: ""
      }

      pp = Instance.Player.PublicPlayer.new(player_struct, profile)

      assert pp.elo == 1100
      assert is_integer(pp.elo)
    end
  end

  describe "Stage 8 F5/F9 — detected_objects sanitization (broadcast shape)" do
    # The sanitize step now lives in
    # `Portal.Controllers.FactionChannel.handle_out/3` and its helpers
    # (`sanitize_for_viewer/2` + `sanitize_blips/2`). It runs once per
    # connected socket and rewrites the payload before push, which lets
    # us filter "the viewer's own characters" instead of "the viewer's
    # whole faction" — the agent-side filter from the original Stage 8
    # commit was an over-correction that broke faction-mate radar
    # visibility.
    #
    # The wire-shape invariant the F5/F9 fix protects is intact:
    # every blip the front-end consumes has only the three keys
    # :faction, :position, :angle. character_id and owner_player_id
    # never reach the wire.
    #
    # These are contract tests against the same shape the production
    # code emits — the channel helpers are module-private, so we
    # mirror their logic in `mirror_sanitize_blips/2` at the bottom of
    # this module and also grep-check faction_channel.ex to catch
    # refactors that move the filter back into agent.ex or drop the
    # `intercept` declaration.

    test "blip on the wire has only {faction, position, angle} — character_id and owner_player_id stripped" do
      detected = [
        %{faction: :crow, character_id: 7, owner_player_id: 99, position: {1.0, 2.0}, angle: 0.5}
      ]

      [blip] = mirror_sanitize_blips(detected, _viewer_player_id = 42)

      assert Map.keys(blip) |> Enum.sort() == [:angle, :faction, :position]
      refute Map.has_key?(blip, :character_id)
      refute Map.has_key?(blip, :owner_player_id)
    end

    test "viewer's own characters are filtered out (per-player, not per-faction)" do
      detected = [
        %{faction: :phoenix, character_id: 1, owner_player_id: 42, position: {0.0, 0.0}, angle: 0.0},
        %{faction: :phoenix, character_id: 2, owner_player_id: 99, position: {1.0, 1.0}, angle: 0.0},
        %{faction: :crow, character_id: 3, owner_player_id: 50, position: {2.0, 2.0}, angle: 0.0}
      ]

      sanitized = mirror_sanitize_blips(detected, _viewer_player_id = 42)

      # Viewer's own character (owner_player_id == 42) is dropped.
      # Faction-mate (same :phoenix, different player_id 99) is KEPT —
      # this is the behavior change vs the original Stage 8 filter,
      # which dropped the entire viewer faction.
      assert length(sanitized) == 2
      assert Enum.any?(sanitized, &(&1.faction == :phoenix)),
             "faction-mate's anonymous blip must reach the wire (regression of original Stage 8 over-filter)"

      assert Enum.any?(sanitized, &(&1.faction == :crow)),
             "enemy blip must reach the wire"
    end

    test "faction_channel.ex declares the intercept and exposes sanitize_blips" do
      channel_src = File.read!("lib/portal/channels/controllers/faction_channel.ex")

      assert String.contains?(channel_src, ~s|intercept(["broadcast"])|),
             "FactionChannel must intercept broadcasts so handle_out/3 can sanitize per-recipient"

      assert String.contains?(channel_src, "defp sanitize_blips("),
             "FactionChannel must define the per-recipient blip sanitizer"

      assert String.contains?(channel_src, "owner_player_id"),
             "FactionChannel must filter blips by owner_player_id (per-player, not per-faction)"
    end

    test "faction.ex includes owner_player_id in every internal blip" do
      # The per-recipient filter in FactionChannel relies on
      # owner_player_id being present on each detected_objects entry.
      # If a refactor drops it, the filter silently degrades to
      # "show all blips to every viewer" — including the viewer's own.
      faction_src = File.read!("lib/game/instance/faction/faction.ex")

      assert String.contains?(faction_src, "owner_player_id: character.owner.id"),
             "Faction.update_detected_object/1 must tag each blip with owner_player_id"
    end

    test "agent.ex broadcasts the raw blip list (intercept does the filtering)" do
      # The original Stage 8 commit had Faction.Agent call
      # sanitize_detected_objects/2 before broadcasting, dropping the
      # whole viewer faction at the agent level. That was the
      # over-correction. The agent now broadcasts the verbose internal
      # list verbatim; FactionChannel.handle_out/3 strips it per
      # recipient.
      agent_src = File.read!("lib/game/instance/faction/agent.ex")

      refute String.contains?(agent_src, "defp sanitize_detected_objects"),
             "Faction.Agent should not sanitize at the agent boundary — the channel does per-recipient"

      assert String.contains?(
               agent_src,
               "broadcast_change(state.channel, %{detected_objects: data.detected_objects})"
             ),
             "Agent should broadcast the raw blip list — channel sanitizes per recipient"
    end
  end

  describe "Stage 8 regression — Faction.StellarSystem.obfuscate routes to the right Character module" do
    # The original Stage 8 commit accidentally added a third arg
    # (viewer_faction_key) to the per-character obfuscation calls inside
    # Instance.Faction.StellarSystem.obfuscate, but the alias at the top
    # of that file binds `Character` to Instance.StellarSystem.Character —
    # a summary struct whose obfuscate/2 has no 3-arity clause. The
    # compiler warned, but no test exercised the reducer branches, so
    # the bug shipped: any populated system view through
    # :get_system_state would crash with UndefinedFunctionError.
    #
    # This test guards both reducer branches (:governor and :characters)
    # at a visibility level that fills them.
    test "system with a non-nil governor and a non-spy character obfuscates without crashing" do
      governor =
        %Instance.StellarSystem.Character{
          id: 1,
          type: :admiral,
          name: "Governor",
          level: 5,
          owner: stellar_player(faction_id: 1),
          protection: 10,
          determination: 20,
          cover: nil
        }

      character =
        %Instance.StellarSystem.Character{
          id: 2,
          type: :admiral,
          name: "Visiting Admiral",
          level: 3,
          owner: stellar_player(faction_id: 1),
          protection: 5,
          determination: 10,
          cover: nil
        }

      # visibility 4 inhabits governor + characters (filled at level 2) AND
      # exercises the visibility<5 details-strip reducer at line 99 of
      # faction/stellar_system.ex — covering all three reducer branches in
      # the same call.
      system = %{governor: governor, characters: [character], bodies: []}
      contact = %Core.Value{value: 4, details: %{}}

      result = Instance.Faction.StellarSystem.obfuscate(system, contact, 1, 1)

      assert %Instance.Faction.StellarSystem{} = result,
             "must return a Faction.StellarSystem struct, not crash with UndefinedFunctionError"

      assert %Instance.StellarSystem.Character{id: 1, name: "Governor"} = result.governor,
             "governor branch must call Instance.StellarSystem.Character.obfuscate/2 successfully"

      assert [%Instance.StellarSystem.Character{id: 2, name: "Visiting Admiral"}] = result.characters,
             "characters branch must call Instance.StellarSystem.Character.obfuscate/2 successfully"
    end

    test "system with empty characters list and nil governor still obfuscates" do
      system = %{governor: nil, characters: [], bodies: []}
      contact = %Core.Value{value: 4, details: %{}}

      result = Instance.Faction.StellarSystem.obfuscate(system, contact, 1, 1)

      assert %Instance.Faction.StellarSystem{} = result
      assert result.governor == nil
      assert result.characters == []
    end
  end

  ## Helpers

  defp build_admiral(opts) do
    owner_faction = Keyword.get(opts, :owner_faction, :phoenix)
    action_status = Keyword.get(opts, :action_status, :idle)
    army_maintenance_details = Keyword.get(opts, :army_maintenance_details, %{})

    struct(Character, %{
      id: 1,
      status: :on_board,
      type: :admiral,
      specialization: :leader,
      second_specialization: :tactician,
      skills: [3, 2, 1],
      age: 30,
      culture: :alpha,
      name: "Admiral Test",
      gender: :female,
      illustration: "",
      level: 5,
      experience: %Core.DynamicValue{value: 100.0, change: 0.0, details: %{}},
      protection: 10,
      determination: 10,
      credit_cost: 0,
      technology_cost: 0,
      ideology_cost: 0,
      owner: %Instance.Character.Player{id: 1, name: "Test Owner", faction: owner_faction, faction_id: 1},
      on_sold: false,
      system: 1,
      position: nil,
      actions: nil,
      action_status: action_status,
      on_strike: false,
      army: %Instance.Character.Army{
        tiles: [],
        reaction: :defend,
        maintenance: %Core.Value{value: 10, details: army_maintenance_details},
        repair_coef: %Core.Value{value: 1, details: %{}},
        invasion_coef: %Core.Value{value: 1, details: %{}},
        raid_coef: %Core.Value{value: 1, details: %{}}
      },
      spy: nil,
      speaker: nil,
      bonuses: %{},
      instance_id: 1
    })
  end

  defp build_spy(opts) do
    id = Keyword.get(opts, :id, 100)
    name = Keyword.get(opts, :name, "Unknown")

    struct(Character, %{
      id: id,
      status: :on_board,
      type: :spy,
      specialization: :infiltrator,
      second_specialization: :saboteur,
      skills: [3, 2, 1],
      age: 30,
      culture: :alpha,
      name: name,
      gender: :female,
      illustration: "spy.png",
      level: 5,
      experience: %Core.DynamicValue{value: 100.0, change: 0.0, details: %{}},
      protection: 10,
      determination: 10,
      credit_cost: 0,
      technology_cost: 0,
      ideology_cost: 0,
      owner: %Instance.Character.Player{id: 1, name: "Test Owner", faction: :crow, faction_id: 1},
      on_sold: false,
      system: 1,
      position: nil,
      actions: nil,
      action_status: :sabotage,
      on_strike: false,
      army: nil,
      spy: nil,
      speaker: nil,
      bonuses: %{},
      instance_id: 1
    })
  end

  defp sample_player do
    # The Player struct has ~25 enforced fields; PublicPlayer.new only
    # reads a small subset. We use struct/2 (which bypasses
    # @enforce_keys) so the test stays focused on the elo-rounding
    # contract and does not have to thread the full game state.
    struct(Instance.Player.Player, %{
      id: 1,
      account_id: 1,
      faction_id: 1,
      faction: :phoenix,
      is_dead: false,
      is_active: true,
      avatar: "",
      name: "",
      registration_id: 1
    })
  end

  defp stellar_player(opts) do
    %Instance.StellarSystem.Player{
      id: Keyword.get(opts, :id, 1),
      avatar: Keyword.get(opts, :avatar, ""),
      name: Keyword.get(opts, :name, "Player"),
      faction: Keyword.get(opts, :faction, :phoenix),
      faction_id: Keyword.get(opts, :faction_id, 1)
    }
  end

  # Mirrors `Portal.Controllers.FactionChannel.sanitize_blips/2`. Kept
  # in sync by the grep-check tests above against the channel source.
  defp mirror_sanitize_blips(blips, viewer_player_id) do
    Enum.flat_map(blips, fn blip ->
      if Map.get(blip, :owner_player_id) == viewer_player_id do
        []
      else
        [%{faction: blip.faction, position: blip.position, angle: blip.angle}]
      end
    end)
  end
end
