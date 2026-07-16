defmodule Instance.Character.Actions.Assassination do
  @moduledoc """
  Implementations of all `Instance.Character` action
  """
  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character

  def pre_validate(character, %{"data" => data}) do
    unless Map.has_key?(data, "target"), do: throw(:bad_data)
    unless Map.has_key?(data, "target_character"), do: throw(:bad_data)

    if character.type != :spy, do: throw(:invalid_character_type)
    if character.actions.virtual_position != data["target"], do: throw(:invalid_position)
    if Queue.any?(character.actions.queue, fn a -> a.type == :assassination end), do: throw(:no_similar_action)

    ActionQueue.add(character.actions, {:assassination, data, 0}, data["target"])
  end

  def start(%Character{} = character, %Action{} = action) do
    instance_id = character.instance_id
    prev_character = character
    c = Data.Querier.one(Data.Game.Constant, instance_id, :main)

    target =
      case Game.call(instance_id, :character, action.data["target_character"], :get_state) do
        {:ok, target} ->
          if target.system != action.data["target"], do: throw({:character_not_reachable, []})
          if target.owner.id == character.owner.id, do: throw({:cannot_attack_itself, []})

          target

        _ ->
          throw({:character_target_does_not_exist, []})
      end

    # get action system location
    {:ok, system} = Game.call(instance_id, :stellar_system, target.system, :get_state)

    # if target is from the same faction than the system, give half of ci for bonus
    defense =
      if not is_nil(system.owner) and system.owner.faction_id == target.owner.faction_id,
        do: target.protection + system.counter_intelligence.value,
        else: target.protection

    attack = character.spy.assassination_coef.value
    {result, {ratio, min, max, value}} = Core.Dice.roll(instance_id, attack, character.level, defense)

    {success?, lost_cover, xp_factor} =
      case result do
        :critical_failure -> {false, 50..80, 0.25}
        :normal_failure -> {false, 30..50, 0.8}
        :normal_success -> {true, 20..30, 1.2}
        :critical_success -> {true, 10..20, 1.5}
      end

    # compute lost cover
    lost_cover = Game.call(instance_id, :rand, :master, {:random, lost_cover})

    # compute earned experience
    xp = c.character_base_action_xp * xp_factor
    {_, _, character} = Character.add_experience(character, xp)

    # kill the target
    if success? do
      :ok = Game.call(instance_id, :player, target.owner.id, {:assassinate_character, target.id})
    end

    # diplomacy: removing a seated governor is a tension kind (war:
    # frenzy); removing a field Navarch/Erased feeds war momentum
    diplomacy_kind =
      cond do
        target.status == :governor -> :removal
        target.type in [:admiral, :spy] -> :agent_removal
        true -> nil
      end

    if diplomacy_kind do
      Instance.Diplomacy.Diplomacy.report(
        instance_id,
        diplomacy_kind,
        character.owner.faction_id,
        target.owner.faction_id,
        success?
      )
    end

    # lose cover
    {character, became_discovered?} = Character.lose_cover(character, lost_cover)

    # if character become discovered, update stellar_system
    if became_discovered? do
      Game.cast(instance_id, :stellar_system, character.system, {:update_character, character})

      # send notification to owner of system
      if system.owner != nil do
        notif = Notification.Text.new(:foreign_spy_discovered, system.id, %{spy: character.name, system: system.name})
        Game.cast(instance_id, :player, system.owner.id, {:push_notifs, notif})
      end
    end

    # create notifs
    bop = %{attack: attack, defense: defense, ratio: ratio, result: value, min: min, max: max}
    # Stage 8 F3 — undercover branch now uses vis=1 (anonymous tier
    # introduced in Instance.Faction.Character.obfuscate). vis=2
    # previously still leaked id, name, illustration, level, and the
    # attacker player's id+name+faction, defeating the whole point of
    # `became_discovered? == false` (the locale strings deliberately
    # imply the spy stayed unidentified). vis=1 fills only [:type,
    # :level] — enough for the UI to render "an enemy spy of level N
    # attacked you" without revealing identity.
    defender_vis = if became_discovered?, do: 6, else: 1

    {attacker_notif, defender_notif} =
      create_notifs({prev_character, character}, target, system, bop, result, defender_vis)

    Game.cast(instance_id, :player, target.owner.id, {:push_notifs, defender_notif})
    {MapSet.new([:player_update]), [attacker_notif], character}
  end

  def finish(%Character{} = character, %Action{} = _action) do
    {MapSet.new([:player_update]), [], Character.finish_action(character)}
  end

  defp create_notifs({prev_attacker, attacker}, target, system, bop, result, defender_vis) do
    notif_system = Notification.System.convert(system)
    # Stage 8 F4/F8 — split the target view: defender sees their OWN
    # character at vis=5 (full struct), attacker sees the target at
    # vis=3 (no skills/doctrine details).
    target_for_defender = Notification.Character.convert(target, 5, target.owner.faction)
    target_for_attacker = Notification.Character.convert(target, 3)

    attacker_data = %{
      system: notif_system,
      side: :attacker,
      balance_of_power: bop,
      outcome: result,
      # Stage 8 F4/F8 — attacker views their own spy; pass viewer key
      # so doctrine/patent .details on spy substruct stay intact.
      spy: Notification.Character.diff(prev_attacker, attacker, 6, attacker.owner.faction),
      target: target_for_attacker
    }

    defender_data = %{
      system: notif_system,
      side: :defender,
      balance_of_power: bop,
      outcome: Core.Dice.reverse_result(result),
      # No viewer_faction_key — defender is non-own-faction for the
      # attacker spy. At vis=1 (undercover) only [:type, :level]
      # reach the wire; at vis=6 (discovered) the defender sees the
      # spy struct but with details stripped.
      spy: Notification.Character.diff(prev_attacker, attacker, defender_vis),
      target: target_for_defender
    }

    attacker_notif = Notification.Box.new(:assassination, system.id, attacker_data)
    defender_notif = Notification.Box.new(:assassination, system.id, defender_data)

    {attacker_notif, defender_notif}
  end
end
