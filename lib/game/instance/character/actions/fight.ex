defmodule Instance.Character.Actions.Fight do
  @moduledoc """
  Implementations of all `Instance.Character` action
  """
  require Logger

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
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

    target =
      case Game.call(instance_id, :character, action.data["target_character"], :get_state) do
        {:ok, target} ->
          if target.type != :admiral, do: throw({:character_type_not_valid, []})
          if target.system != action.data["target"], do: throw({:character_not_reachable, []})
          if target.owner.id == character.owner.id, do: throw({:cannot_attack_itself, []})

          target

        _ ->
          throw({:character_target_does_not_exist, []})
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

    # assemble admirals
    i_attackers = [character | attackers]
    i_defenders = [target | defenders]
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

  def check_interception(%Character{type: :admiral} = character, %Action{} = action, reactions) do
    instance_id = character.instance_id
    constant = Data.Querier.one(Data.Game.Constant, instance_id, :main)

    {system, hostiles} = find_hostiles(character, action, reactions)

    # fight hostiles
    if not Enum.empty?(hostiles) do
      Enum.reduce(hostiles, {character, [], false}, fn c, {character, notifs, fleeing_or_dead?} ->
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
      end)
    else
      {character, [], false}
    end
  end

  def check_interception(%Character{} = character, %Action{} = _action, _reactions),
    do: {character, [], false}

  @doc """
  Identify the admirals on the action's target system who match the
  given reactions list. Extracted from `check_interception/3` so the
  predicate can be exercised in isolation by integration tests without
  having to spin up the rand/galaxy/fight pipeline behind the actual
  engagement.

  Returns `{system, hostiles}`:

    * `system` — the full `Instance.StellarSystem.StellarSystem` state
      read from the agent.
    * `hostiles` — the post-filter list of cross-faction admirals on
      that system whose `action_status` is `:idle`/`:docking` and whose
      `army.reaction` is in `reactions`.

  Also emits the structured `check_interception` log line when
  `RC.DebugFlags.fleet_interception?/0` is on.
  """
  def find_hostiles(%Character{} = character, %Action{} = action, reactions) do
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

    hostiles =
      Enum.filter(candidates, fn c ->
        c != nil and c.action_status in [:idle, :docking] and Enum.member?(reactions, c.army.reaction)
      end)

    log_interception(character, action, system, same_system_admirals, candidates, hostiles, reactions)

    {system, hostiles}
  end

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
  defp log_interception(character, action, system, same_system_admirals, candidates, hostiles, reactions) do
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

  defp kill_character({%Character{} = _character, false}),
    do: nil

  defp kill_character({%Character{} = character, true}) do
    # a character dying mid-conquest never reaches MakeDominion.finish —
    # lift the target owner's under-attack mark (no-op for everyone else)
    Instance.Character.Actions.MakeDominion.unmark_if_interrupted(character)

    # clean dead character...
    {:ok, _system} =
      Game.call(character.instance_id, :stellar_system, character.system, {:remove_character, character, :on_board})

    # ... and terminate process
    Instance.Manager.kill_child(character.instance_id, {character.instance_id, :character, character.id})
  end

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
      c != nil and c.action_status == :idle and Enum.member?(reactions, c.army.reaction)
    end)
  end

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
