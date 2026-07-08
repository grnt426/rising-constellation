defmodule Instance.Character.Actions.MakeDominion do
  @moduledoc """
  Implementations of all `Instance.Character` action
  """
  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Character
  alias Instance.Character.Speaker
  alias Instance.Player.Player

  def pre_validate(character, %{"data" => data}) do
    unless Map.has_key?(data, "target"), do: throw(:bad_data)

    if character.type != :speaker, do: throw(:invalid_character_type)
    if Speaker.locked?(character.speaker), do: throw(:locked_character)
    if character.actions.virtual_position != data["target"], do: throw(:invalid_position)
    if Queue.any?(character.actions.queue, fn a -> a.type == :make_dominion end), do: throw(:no_multiple_dominionage)

    ActionQueue.add(character.actions, {:make_dominion, data, :unknown_yet}, data["target"])
  end

  def start(%Character{} = character, %Action{} = action) do
    iid = character.instance_id
    c = Data.Querier.one(Data.Game.Constant, iid, :main)

    {:ok, player} = Game.call(iid, :player, character.owner.id, :get_state)
    {:ok, system} = Game.call(iid, :stellar_system, character.system, :get_state)

    {:ok, takeability} =
      Game.call(iid, :galaxy, :master, {:check_system_takeability, character.system, character.owner.faction})

    notif = Notification.Text.new(:make_dominion_cancelled, system.id, %{speaker: character.name, system: system.name})

    if Speaker.locked?(character.speaker), do: throw({:locked_character, [notif]})
    if not Player.available_dominion_slot?(player), do: throw({:no_available_dominion_slot, [notif]})
    if system.owner != nil and system.owner.id == player.id, do: throw({:no_dominion_on_yourself, [notif]})
    if takeability == :untakeable, do: throw({:system_not_takeable, [notif]})

    if system.status not in [:inhabited_neutral, :inhabited_dominion],
      do: throw({:system_not_dominionable, [notif]})

    # start making dominion
    actions =
      character.actions
      |> ActionQueue.map(fn a ->
        # `action` already has `started_at` and `cumulated_pauses` while `a` doesn't
        if Map.drop(a, [:started_at, :cumulated_pauses]) == Map.drop(action, [:started_at, :cumulated_pauses]),
          do: Action.reset_time(a, c.make_dominion_time),
          else: a
      end)

    character =
      %{character | actions: actions}
      |> Character.start_action(:make_dominion)

    # Flag the dominion as under attack on its owner's player state so the
    # FE can render a pulse on the dominion entry. Only meaningful when the
    # system has an owner (neutral systems have no one to notify).
    if system.owner != nil do
      Game.cast(iid, :player, system.owner.id, {:mark_dominion_under_attack, system.id})
    end

    notif = Notification.Text.new(:make_dominion_started, system.id, %{speaker: character.name, system: system.name})

    {MapSet.new([:player_update]), [notif], character}
  end

  @doc """
  Lift the under-attack mark if `character` is dropped mid-conquest.

  `start/2` marks the target dominion's owner and `finish/2` unmarks —
  but an in-progress make_dominion can also end without finishing: the
  owner clears the Siderian's action queue, or the Siderian is
  assassinated/converted mid-action. Those paths used to leave the
  owner's dominion pulsing "under attack" forever (Preid, instance 49).
  Call this from any abort path; it no-ops unless the character's
  current action is a started make_dominion. The queue peek comes first
  so the common case costs no Game.call.
  """
  def unmark_if_interrupted(%Character{} = character) do
    # `actions` can be nil on some live characters (governors, older
    # snapshots) — this helper runs inside player-agent handlers, where a
    # crash means a state reset, so every step must be a soft match.
    with %{queue: queue} <- character.actions,
         %Action{type: :make_dominion, started_at: started_at} when not is_nil(started_at) <-
           Queue.peek(queue),
         system_id when not is_nil(system_id) <- character.system,
         {:ok, system} <- Game.call(character.instance_id, :stellar_system, system_id, :get_state),
         %{owner: %{id: owner_id}} <- system do
      Game.cast(character.instance_id, :player, owner_id, {:unmark_dominion_under_attack, system_id})
    else
      _ -> :ok
    end
  end

  def finish(%Character{} = character, %Action{} = _action) do
    iid = character.instance_id
    prev_character = character

    c = Data.Querier.one(Data.Game.Constant, iid, :main)

    {:ok, player} = Game.call(iid, :player, character.owner.id, :get_state)
    {:ok, system} = Game.call(iid, :stellar_system, character.system, :get_state)

    {:ok, takeability} =
      Game.call(iid, :galaxy, :master, {:check_system_takeability, character.system, character.owner.faction})

    is_speaker_free = not Speaker.locked?(character.speaker)
    has_dominion_slot = Player.available_dominion_slot?(player)
    is_target_free = system.status in [:inhabited_neutral, :inhabited_dominion]
    is_not_own_system = system.owner == nil or system.owner.id != player.id

    # compute result
    attack = character.speaker.make_dominion_coef.value
    defense = Enum.max([system.happiness.value, 0])
    {result, {ratio, min, max, value}} = Core.Dice.roll(iid, attack, character.level, defense)

    {cooldown_duration, dominion_taken?, xp_factor} =
      case result do
        :critical_failure -> {200, false, 0.1}
        :normal_failure -> {140, false, 0.3}
        :normal_success -> {80, true, 1}
        :critical_success -> {60, true, 1.2}
      end

    # The mark added in start/2 must come off no matter how this finishes:
    # successful takeover, failed roll, or the late-validity check below. We
    # use the system owner captured before any :lose_dominion cast, so the
    # unmark hits the player whose state was actually marked.
    if system.owner != nil do
      Game.cast(iid, :player, system.owner.id, {:unmark_dominion_under_attack, system.id})
    end

    if takeability == :takeable and is_speaker_free and has_dominion_slot and is_target_free and is_not_own_system do
      if dominion_taken? do
        # remove previous owner
        if system.owner != nil do
          Game.cast(iid, :player, system.owner.id, {:lose_dominion, system.id})
        end

        # claim dominion
        Game.cast(iid, :player, character.owner.id, {:claim_dominion, system.id})
      end

      # compute earned experience
      xp = c.character_base_action_xp * xp_factor
      {_, _, character} = Character.add_experience(character, xp)

      # set cooldown
      character = Character.set_cooldown(character, cooldown_duration)

      # finish action
      character = Character.finish_action(character)

      # create notifs
      bop = %{attack: attack, defense: defense, ratio: ratio, result: value, min: min, max: max}
      {attacker_notif, defender_notif} = create_notifs({prev_character, character}, system, bop, result)

      if defender_notif do
        Game.cast(iid, :player, system.owner.id, {:push_notifs, defender_notif})
      end

      {MapSet.new([:player_update]), [attacker_notif], character}
    else
      notif =
        Notification.Text.new(:make_dominion_cancelled, system.id, %{speaker: character.name, system: system.name})

      {MapSet.new([:player_update]), [notif], Character.finish_action(character)}
    end
  end

  defp create_notifs({prev_attacker, attacker}, system, bop, result) do
    notif_system = Notification.System.convert(system)
    # Stage 8 F4/F8 — owner-view at vis=5 with faction key.
    attacker_diff = Notification.Character.diff(prev_attacker, attacker, 5, attacker.owner.faction)
    # Stage 8 F2 — defender sees the attacker at vis=3.
    defender_attacker_diff = Notification.Character.diff(prev_attacker, attacker, 3)

    attacker_data = %{
      system: notif_system,
      side: :attacker,
      balance_of_power: bop,
      outcome: result,
      speaker: attacker_diff
    }

    attacker_notif = Notification.Box.new(:make_dominion, system.id, attacker_data)

    defender_notif =
      if system.owner != nil do
        defender_data = %{
          system: notif_system,
          side: :defender,
          balance_of_power: bop,
          outcome: Core.Dice.reverse_result(result),
          speaker: defender_attacker_diff
        }

        Notification.Box.new(:make_dominion, system.id, defender_data)
      end

    {attacker_notif, defender_notif}
  end
end
