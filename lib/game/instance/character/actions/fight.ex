defmodule Instance.Character.Actions.Fight do
  @moduledoc """
  Implementations of all `Instance.Character` action
  """
  require Logger

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Armada
  alias Instance.Character.Character

  def pre_validate(character, %{"data" => data}) do
    unless Map.has_key?(data, "target"), do: throw(:bad_data)
    unless Map.has_key?(data, "target_character"), do: throw(:bad_data)

    if character.type != :admiral, do: throw(:invalid_character_type)
    if character.actions.virtual_position != data["target"], do: throw(:invalid_position)

    ActionQueue.add(character.actions, {:fight, data, 0}, data["target"])
  end

  def start(%Character{} = character, %Action{} = action) do
    instance_id = character.instance_id

    {:ok, system} = Game.call(instance_id, :stellar_system, character.system, :get_state)

    # A queued attack order is resolved against the target's position
    # AT ARRIVAL. If the Navarch the player pointed at has left (or
    # died) in the meantime, the order is skipped with a text notif
    # and the queue moves on — a `{reason, notifs}` throw is the clean
    # abort path in ActionImpl.on_start (abort_action + notifs), not a
    # crash. The same throws are also reached from check_interception's
    # inline Fight.start, where the catch-all discards the notif.
    target =
      case Game.call(instance_id, :character, action.data["target_character"], :get_state) do
        {:ok, target} ->
          if target.type != :admiral, do: throw({:character_type_not_valid, []})

          if target.system != action.data["target"],
            do: throw({:character_not_reachable, [target_gone_notif(character, system)]})

          if target.owner.id == character.owner.id, do: throw({:cannot_attack_itself, []})

          target

        _ ->
          throw({:character_target_does_not_exist, [target_gone_notif(character, system)]})
      end

    # fetch friends for fight
    # TODO: when implemented, check ennemies or allies
    # and make distinction between :attack_ennemies and :attack_everyone
    reactions = [:defend, :attack_enemies, :attack_everyone]

    attackers =
      case character.owner.faction != target.owner.faction do
        true -> fetch_admirals_in_system(system, character, reactions)
        _ -> []
      end

    defenders =
      case character.owner.faction != target.owner.faction do
        true -> fetch_admirals_in_system(system, target, reactions)
        _ -> []
      end

    # assemble admirals — an armada fights as one: every member of any
    # armada represented on a side joins that side whatever its own
    # stance; stance only decides its join order (Fight.Manager assigns
    # the reinforcement delay by side order). The initiator's/target's
    # armada block always enters first (test classes 6, 9, 9a).
    i_attackers =
      [character | attackers]
      |> expand_with_armada_members(system, instance_id)
      |> Armada.order_battle_side(character.id)

    i_defenders =
      [target | defenders]
      |> expand_with_armada_members(system, instance_id)
      |> Armada.order_battle_side(target.id)

    i_all = i_attackers ++ i_defenders

    # execute fight
    {{f_attackers, f_defenders}, logs, metadata, victory} = Fight.Manager.fight(i_attackers, i_defenders)

    f_all = f_attackers ++ f_defenders

    # handle target
    # {updated_defender, should_die?}
    u_defenders =
      Enum.map(f_defenders, fn {status, _side, defender} ->
        Game.call(instance_id, :player, defender.owner.id, {:fight_callback, status, defender})
      end)

    # handle attacker
    # {updated_attacker, should_die?}
    u_attackers =
      Enum.map(f_attackers, fn {status, _side, attacker} ->
        Game.call(instance_id, :player, attacker.owner.id, {:fight_callback, status, attacker})
      end)

    u_all = u_attackers ++ u_defenders

    # diplomacy: every destroyed fleet feeds the destroyer's war
    # momentum (same-faction skirmishes are dropped by report/5)
    report_fleet_kills(instance_id, u_defenders, character.owner.faction_id)
    report_fleet_kills(instance_id, u_attackers, target.owner.faction_id)

    # prepare report
    # TODO: compute "result" of the fight
    # it should be something like "huge defeat" or "brilliant victory"
    #  - ratio lost/killed
    #  - défaite, défaite de justesse, victoire à l'arrachée, victoire, ...

    report_data = {
      %{attackers: i_attackers, defenders: i_defenders},
      logs,
      Map.put(metadata, :system_name, system.name)
    }

    # send notifs to each players
    send_notifs_and_report(i_all, f_all, u_all, victory, system, report_data, instance_id)

    # News-ticker hook: fleet engagements make the wire. The web
    # surfaces dedup per-sector; the Discord relay rolls battles up
    # into an edited tally, so it also gets the players involved.
    # Fight.Manager sides: :left = attackers, :right = defenders.
    {winning_chars, losing_chars} =
      case victory do
        :left -> {i_attackers, i_defenders}
        :right -> {i_defenders, i_attackers}
        _ -> {[], []}
      end

    to_players = fn chars ->
      chars
      |> Enum.map(fn c -> %{name: c.owner.name, faction: Atom.to_string(c.owner.faction)} end)
      |> Enum.uniq()
    end

    Game.News.emit(instance_id, "battle.fought", %{
      attacker_faction: Atom.to_string(character.owner.faction),
      defender_faction: Atom.to_string(target.owner.faction),
      winner:
        case victory do
          :left -> "attackers"
          :right -> "defenders"
          _ -> "draw"
        end,
      winners: to_players.(winning_chars),
      losers: to_players.(losing_chars),
      system_name: system.name,
      system_id: system.id,
      sector_id: system.sector_id,
      fleet_count: length(i_all)
    })

    # remove characters_to_kill
    # sort the current character to last to kill it last
    u_all
    |> Enum.sort(fn {%Character{id: id}, _}, {_, _} -> id != character.id end)
    |> Enum.each(&kill_character/1)

    {attacker, _} =
      u_attackers
      |> Enum.find(fn {%Character{id: id}, _} -> id == character.id end)

    {attacker_status, _, _} =
      f_attackers
      |> Enum.find(fn {_, _, attacker} -> attacker.id == character.id end)

    {MapSet.new([:player_update, attacker_status]), [], attacker}
  end

  def finish(%Character{} = character, %Action{} = _action) do
    character = Character.finish_action(character)
    {MapSet.new([:player_update]), [], character}
  end

  @doc """
  Interception is a two-pass check (docs/armadas.md §3.4 for armadas):

    1. `engagement` — the ACTING fleet's own stance decides whom it
       engages among the cross-faction admirals already on the target
       system. `:all` (Fury arrival) engages every fleet physically
       present, whatever it is doing; `:busy` (Defender arrival)
       engages only fleets in the middle of an in-system action
       (pillage, bombard, conquest, colonization, dominion); `:none`
       engages nobody on its own initiative.
    2. `reactions` — every present fleet whose stance is in this list
       intercepts the actor. Only idle or docking fleets intercept: a
       fleet busy with its own action never breaks off to react.

  The two passes feed one deduplicated hostile list; a fleet that is
  both engaged by the actor and intercepting it fights once.
  """
  def check_interception(character, action, reactions, engagement \\ :none)

  def check_interception(%Character{type: :admiral} = character, %Action{} = action, reactions, engagement) do
    instance_id = character.instance_id
    constant = Data.Querier.one(Data.Game.Constant, instance_id, :main)

    {system, hostiles} = find_hostiles(character, action, reactions, engagement)

    # Initiation order (test class 9): Fury → Interdiction → Defender →
    # Prudent → Deserter; equal stances flip on a seeded random shuffle.
    # The first hostile is the initiation winner — Fight.start pulls its
    # whole armada into the battle ahead of every other defender.
    hostiles = order_hostiles(hostiles, instance_id)

    # fight hostiles — one battle per group. Fight.start pulls the
    # target's present faction-mates (and armada) in as joiners, so the
    # escort scenario (Fury screen in front of a Defender conquest
    # fleet) resolves as ONE battle initiated against the screen, with
    # the conquest fleet joining. Hostiles that joined an earlier
    # battle are skipped, or a beaten-and-fleeing joiner would be
    # engaged a second time on its own.
    if not Enum.empty?(hostiles) do
      {character, notifs, fleeing_or_dead?, _fought} =
        Enum.reduce(hostiles, {character, [], false, MapSet.new()}, fn c,
                                                                       {character, notifs, fleeing_or_dead?, fought} ->
          {character, notifs, fleeing_or_dead?} =
            if MapSet.member?(fought, c.id),
              do: {character, notifs, fleeing_or_dead?},
              else: engage_hostile(character, c, system, constant, notifs, fleeing_or_dead?)

          fought = fought |> MapSet.put(c.id) |> MapSet.union(MapSet.new(joined_with(c, hostiles), & &1.id))
          {character, notifs, fleeing_or_dead?, fought}
        end)

      {character, notifs, fleeing_or_dead?}
    else
      {character, [], false}
    end
  end

  def check_interception(%Character{} = character, %Action{} = _action, _reactions, _engagement),
    do: {character, [], false}

  @joiner_reactions [:defend, :attack_enemies, :attack_everyone]

  @doc """
  Hostiles that `Fight.start` pulls into a battle initiated against
  `target`: its armada co-members (any stance) and its present
  faction-mates whose stance joins for an ally (`fetch_admirals_in_system`
  rules — Prudent/Deserter and docking fleets stay out). Public so the
  one-battle-per-group rule can be pinned without running a battle.
  """
  def joined_with(%Character{} = target, hostiles) do
    armada_ids = Armada.other_member_ids(target)

    Enum.filter(hostiles, fn c ->
      c.id != target.id and
        (c.id in armada_ids or
           (c.owner.faction == target.owner.faction and c.action_status != :docking and
              c.army.reaction in @joiner_reactions))
    end)
  end

  defp engage_hostile(character, c, system, constant, notifs, fleeing_or_dead?) do
    instance_id = character.instance_id

    unless fleeing_or_dead? do
      # if character wants to flee, try fleeing
      flee? =
        if character.army.reaction == :flee,
          do: Game.call(instance_id, :rand, :master, {:uniform}) < constant.fleeing_chance,
          else: false

      if flee? do
        # character is fleeing, reseting its actions
        target_id = Game.call(instance_id, :galaxy, :master, {:get_closest_system, character.system})

        character =
          character
          |> Character.flee(target_id)
          |> Character.cancel_all_ships()

        data = %{admiral: character.name, system: system.name}
        notif = Notification.Text.new(:interception_and_flight, system.id, data)

        # apply to system...
        Game.cast(instance_id, :stellar_system, character.system, {:cancel_ordered_ships, character.id})

        {character, [notif | notifs], true}
      else
        # character is facing interpectors
        data = %{"target" => character.system, "target_character" => c.id}
        action = Action.new({:fight, data, 0})

        {changes, _, character} =
          try do
            Instance.Character.Actions.Fight.start(character, action)
          catch
            _ -> {MapSet.new(), [], character}
          end

        fleeing_or_dead? = character.status == :dead or MapSet.member?(changes, :fleeing)
        {character, notifs, fleeing_or_dead?}
      end
    else
      {character, notifs, fleeing_or_dead?}
    end
  end

  @doc """
  Identify the admirals on the action's target system the actor ends
  up fighting. Extracted from `check_interception/4` so the predicate
  can be exercised in isolation by integration tests without having to
  spin up the rand/galaxy/fight pipeline behind the actual engagement.

  Returns `{system, hostiles}`:

    * `system` — the full `Instance.StellarSystem.StellarSystem` state
      read from the agent.
    * `hostiles` — the cross-faction admirals on that system that
      either intercept the actor (idle/docking AND `army.reaction` in
      `reactions`, armada-aware) or are engaged by the actor's own
      stance (`engagement`: `:all` = every fleet physically present,
      `:busy` = only fleets mid-action, `:none` = nobody). Fleets in
      transit (`:moving`/`:attached`) or already inside a battle
      (`:fight`) are never candidates.

  Also emits the structured `check_interception` log line when
  `RC.DebugFlags.fleet_interception?/0` is on.
  """
  def find_hostiles(character, action, reactions, engagement \\ :none)

  def find_hostiles(%Character{} = character, %Action{} = action, reactions, engagement) do
    instance_id = character.instance_id

    # check if hostiles
    {:ok, system} = Game.call(instance_id, :stellar_system, action.data["target"], :get_state)

    # TODO: when implemented, check ennemies or allies
    # and make distinction between :attack_ennemies and :attack_everyone
    same_system_admirals =
      Enum.filter(system.characters, fn c ->
        c.type == :admiral and c.owner.faction != character.owner.faction
      end)

    candidates =
      Enum.map(same_system_admirals, fn c ->
        case Game.call(instance_id, :character, c.id, :get_state) do
          {:ok, resp} -> resp
          _ -> nil
        end
      end)

    # Pass 2 — sitters intercepting the actor. A defending armada
    # intercepts with its most aggressive member's stance (test class
    # 8): one Fury member makes every idle member of that armada an
    # interceptor. Members are co-located by invariant, so an armada's
    # members are all present in `candidates`.
    #
    # Pass 1 — sitters the actor engages on its own initiative
    # (`engagement`). This is what lets a Fury or Defender fleet
    # arriving on a pillaging enemy actually fight it: the pillager is
    # busy, so it can never intercept, but it is present and can be
    # attacked.
    hostiles =
      Enum.filter(candidates, fn c ->
        c != nil and present?(c) and
          (intercepts?(c, candidates, reactions) or engaged?(c, engagement))
      end)

    log_interception(character, action, system, same_system_admirals, candidates, hostiles, reactions, engagement)

    {system, hostiles}
  end

  # Physically in the system and not already inside a battle. `:moving`
  # admirals have left the system; `:attached` armada members travel
  # with their lead and carry no position of their own.
  @in_transit [:moving, :attached, :fight]
  defp present?(c), do: c.action_status not in @in_transit

  # Free to react: idle, or docking (ships under construction).
  defp idle?(c), do: c.action_status in [:idle, :docking]

  defp intercepts?(c, candidates, reactions),
    do: idle?(c) and Enum.member?(reactions, candidate_effective_reaction(c, candidates))

  defp engaged?(_c, :none), do: false
  defp engaged?(_c, :all), do: true
  defp engaged?(c, :busy), do: not idle?(c)

  # When RC.DebugFlags.fleet_interception?/0 is on, emit a structured
  # snapshot of every step the filter pipeline went through, so a
  # "no combat happened where I expected one" report can be traced to
  # the exact predicate that rejected the defender.
  #
  # We log:
  #   * `caller` — the admiral whose action triggered the check, plus
  #     the action type, target system, and the reactions list this
  #     check is gated on.
  #   * `same_system_admirals` — every cross-faction admiral the
  #     stellar_system thinks is on the system (before we even fetched
  #     their individual state). If a defender you expected is missing
  #     here, the bug is in push/remove_character, not interception.
  #   * `candidates` — the per-admiral live state after `:get_state`.
  #     A `nil` means the character process was unreachable; a stale
  #     `action_status` or `army.reaction` here pinpoints a state-sync
  #     race.
  #   * `hostiles` — the candidates that survived the
  #     `action_status in [:idle, :docking] AND reaction in reactions`
  #     filter. Empty hostiles == no fight.
  defp log_interception(character, action, system, same_system_admirals, candidates, hostiles, reactions, engagement) do
    if RC.DebugFlags.fleet_interception?() do
      Logger.info("check_interception",
        instance_id: character.instance_id,
        caller: %{
          id: character.id,
          faction: character.owner.faction,
          system: character.system,
          action_status: character.action_status,
          army_reaction: character.army && character.army.reaction
        },
        action: %{
          type: action.type,
          target_system: action.data["target"]
        },
        reactions_allowed: reactions,
        engagement: engagement,
        target_system_id: system.id,
        same_system_admirals:
          Enum.map(same_system_admirals, fn c ->
            %{id: c.id, faction: c.owner.faction, type: c.type}
          end),
        candidates:
          Enum.map(candidates, fn
            nil ->
              %{state: :unreachable}

            c ->
              %{
                id: c.id,
                faction: c.owner.faction,
                action_status: c.action_status,
                reaction: c.army && c.army.reaction,
                has_ships: c.army && Instance.Character.Army.has_ship?(c.army)
              }
          end),
        hostiles: Enum.map(hostiles, fn c -> %{id: c.id, reaction: c.army.reaction} end),
        decision: if(Enum.empty?(hostiles), do: :no_fight, else: :engage)
      )
    end
  end

  defp report_fleet_kills(instance_id, updated_characters, killer_faction_id) do
    Enum.each(updated_characters, fn {%Character{} = c, died?} ->
      if died? do
        Instance.Diplomacy.Diplomacy.report(instance_id, :fleet_destroyed, killer_faction_id, c.owner.faction_id)
      end
    end)
  end

  defp kill_character({%Character{} = _character, false}),
    do: nil

  defp kill_character({%Character{} = character, true}) do
    # a character dying mid-conquest never reaches MakeDominion.finish —
    # lift the target owner's under-attack mark (no-op for everyone else);
    # a traveler dying mid-charge must free its faction's gateway lock
    Instance.Character.Actions.MakeDominion.unmark_if_interrupted(character)
    Instance.Character.Actions.Gateway.release_if_interrupted(character)

    # clean dead character...
    {:ok, _system} =
      Game.call(character.instance_id, :stellar_system, character.system, {:remove_character, character, :on_board})

    # ... and terminate process
    Instance.Manager.kill_child(character.instance_id, {character.instance_id, :character, character.id})
  end

  # Pull the missing armada members of every character already on a
  # side into that side. Members must be live, on board, and standing
  # in the fight's system (an attached or detached-elsewhere member is
  # skipped — the detach paths own that cleanup).
  defp expand_with_armada_members(side_characters, system, instance_id) do
    present = MapSet.new(side_characters, & &1.id)

    members =
      side_characters
      |> Enum.flat_map(&Armada.other_member_ids/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(present, &1))
      |> Enum.map(fn id ->
        case Game.call(instance_id, :character, id, :get_state) do
          {:ok, member} -> member
          _ -> nil
        end
      end)
      |> Enum.filter(fn c ->
        c != nil and c.type == :admiral and c.status == :on_board and c.system == system.id
      end)

    side_characters ++ members
  end

  defp candidate_effective_reaction(c, candidates) do
    case Armada.get(c) do
      nil ->
        c.army.reaction

      %{member_ids: member_ids} ->
        candidates
        |> Enum.filter(fn other -> other != nil and other.id in member_ids and other.army != nil end)
        |> case do
          [] -> c.army.reaction
          group -> Armada.effective_reaction(group)
        end
    end
  end

  @doc """
  Initiation order: the arriver engages the most hostile stance first
  (Fury → Interdiction → Defender → Prudent → Deserter); equal stances
  flip on the seeded shuffle. This is what makes an escort work — a
  Fury screen is engaged ahead of the Defender conquest fleet it
  protects, and the conquest fleet joins that battle instead of being
  picked off first.
  """
  def order_hostiles(hostiles, instance_id)
  def order_hostiles([], _instance_id), do: []
  def order_hostiles([single], _instance_id), do: [single]

  def order_hostiles(hostiles, instance_id) do
    instance_id
    |> Game.call(:rand, :master, {:take_random, hostiles, length(hostiles)})
    |> Enum.sort_by(fn c -> Armada.stance_priority(c.army.reaction) end)
  end

  # Faction-mates that join a side. Any fleet physically present joins,
  # including one busy with its own action (a pillager whose escort is
  # attacked breaks off to fight); stance still decides participation
  # (Prudent/Deserter never intervene for an ally). A docking fleet
  # (ships under construction) is left out as before — it may have no
  # hull to fight with and would only die.
  defp fetch_admirals_in_system(system, character, reactions) do
    system.characters
    |> Enum.filter(fn c ->
      c.id != character.id and c.type == :admiral and c.owner.faction == character.owner.faction
    end)
    |> Enum.map(fn c ->
      case Game.call(character.instance_id, :character, c.id, :get_state) do
        {:ok, resp} -> resp
        _ -> nil
      end
    end)
    |> Enum.filter(fn c ->
      c != nil and present?(c) and c.action_status != :docking and Enum.member?(reactions, c.army.reaction)
    end)
  end

  defp target_gone_notif(%Character{} = character, system),
    do: Notification.Text.new(:fight_target_gone, system.id, %{admiral: character.name, system: system.name})

  defp send_notifs_and_report(i_all, f_all, u_all, victory, system, report_data, instance_id) do
    {initials, logs, metadata} = report_data
    {:ok, galaxy} = Game.call(instance_id, :galaxy, :master, :get_state)

    notif_system = Notification.System.convert(system)

    # Stage 8 F2/F4/F8 — the fight notif used to build `notif_characters`
    # ONCE at default vis=5 and ship the same struct to every involved
    # player. That meant every defender saw every attacker's full skill
    # tree, action_status, on_strike, and doctrine/patent .details (and
    # vice versa). We now build the per-character struct per recipient:
    # the recipient's OWN characters render at vis=5 with viewer_faction_key
    # (full struct, .details intact), and cross-faction characters render
    # at vis=3 (id+name+illustration+owner+gender, no doctrine details).

    # Pre-resolve the per-character tuple (status, side, updated,
    # has_died) once, then materialise the obfuscated `previous`/
    # `current` per recipient.
    pre_obfuscation_rows =
      Enum.map(i_all, fn initial ->
        {status, side, _} = Enum.find(f_all, fn {_, _, final} -> final.id == initial.id end)
        {updated, has_to_die?} = Enum.find(u_all, fn {updated, _} -> updated.id == initial.id end)

        %{
          initial: initial,
          updated: updated,
          status: status,
          side: side,
          has_died: has_to_die?
        }
      end)

    pre_obfuscation_rows
    |> Enum.group_by(fn row -> row.initial.owner.id end)
    |> Enum.each(fn {player_id, [first_row | _rest_rows]} ->
      # fetch player data
      {:ok, player} = Game.call(instance_id, :player, player_id, :get_state)

      outcome =
        if first_row.side == victory,
          do: :victory,
          else: :defeat

      # Build the per-recipient admirals list. Every participant in a
      # fight is shown at vis=5 — fighting an admiral is the strongest
      # possible "contact" event, and the battle log itself already
      # records each ship class, its damage in/out, and whether it died.
      # Treating cross-faction participants as vis=3 here (the earlier
      # Stage 8 default) stripped the ship composition and stats from
      # the post-battle status report even though the same admirals
      # appear ship-by-ship in the battle log on the next tab — see
      # `Tile.obfuscate` (ships go `:hidden` below vis=4) and
      # `Ship.obfuscate` (full struct at vis=5).
      #
      # `viewer_key` still narrows for the OWNER's view only — so
      # `is_own_faction` is true only for one's own admirals. Stage 8
      # F8 still drops :action_status for cross-faction viewers, and
      # F4 (`strip_value_details`) still hides Core.Value `.details`
      # breakdowns. So the enemy's mid-cast attack intent and their
      # per-doctrine value composition stay private; their ship list,
      # stats, and skills do not.
      admirals =
        Enum.map(pre_obfuscation_rows, fn row ->
          viewer_key =
            if row.initial.owner.faction == player.faction, do: player.faction, else: nil

          %{
            status: row.status,
            side: row.side,
            has_died: row.has_died,
            previous: Notification.Character.convert(row.initial, 5, viewer_key),
            current: Notification.Character.convert(row.updated, 5, viewer_key)
          }
        end)

      # save report
      metadata_report = %{
        system: notif_system.name,
        scale: metadata.fight_scale,
        result: first_row.status
      }

      report_id =
        if Instance.Galaxy.Galaxy.is_tutorial(galaxy) do
          nil
        else
          {:ok, report} =
            %{
              type: "fight",
              metadata: Jason.encode!(metadata_report),
              report: Jason.encode!(%{initial: initials, battle: logs}),
              registration_id: player.registration_id
            }
            |> RC.PlayerReports.create()

          report.id
        end

      # send notif
      notif_data = %{
        system: notif_system,
        scale: metadata.fight_scale,
        report_id: report_id,
        outcome: outcome,
        admirals: admirals
      }

      notif = Notification.Box.new(:fight, system.id, notif_data)
      Game.cast(instance_id, :player, player_id, {:push_notifs, notif})
    end)
  end
end
