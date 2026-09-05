defmodule Instance.Character.Actions.Jump do
  @moduledoc """
  Implementations of all `Instance.Character` action
  """
  alias Instance.Character.Action
  alias Instance.Character.ActionQueue
  alias Instance.Character.Armada
  alias Instance.Character.Character
  alias Instance.Character.Actions.Fight
  alias Instance.Character.Spy
  alias Spatial

  def pre_validate(character, %{"data" => data}) do
    unless Map.has_key?(data, "source") and Map.has_key?(data, "target"),
      do: throw(:bad_data)

    if character.type == :spy and Spy.discovered?(character.spy.cover.value, character.instance_id),
      do: throw(:unable_to_move)

    if character.action_status == :docking, do: throw(:unable_to_move)
    if character.actions.virtual_position == data["target"], do: throw(:same_position)
    if character.actions.virtual_position != data["source"], do: throw(:invalid_position)

    case Game.call(character.instance_id, :galaxy, :master, {:check_jump, data["source"], data["target"]}) do
      :invalid_jump ->
        throw(:invalid_jump)

      %{s1: s1, s2: s2, weight: distance} ->
        c = Data.Querier.one(Data.Game.Constant, character.instance_id, :main)
        travel_time = distance * c.character_movement_factor

        data =
          data
          |> Map.put("source_position", s1.position)
          |> Map.put("target_position", s2.position)

        ActionQueue.add(character.actions, {:jump, data, travel_time}, data["target"])
    end
  end

  def start(%Character{instance_id: instance_id} = character, %Action{} = action) do
    {:ok, _system} =
      Game.call(instance_id, :stellar_system, action.data["source"], {:remove_character, character, :on_board})

    character = Character.leave_system(character)

    if character.type == :admiral do
      Spatial.update(character, action)
      attach_armada_members(character, action)
    end

    {MapSet.new([:player_update]), [], character}
  end

  # Attached transit (docs/armadas.md §3.3): the armada moves as one
  # body — the lead executes the jump, every other member leaves the
  # source system with it and carries no motion state (and no spatial
  # entry, hence no radar blip) until materialization. A member that
  # cannot attach (dead, detached in the meantime) is skipped here;
  # membership cleanup belongs to the Player.Agent detach paths.
  defp attach_armada_members(%Character{} = character, %Action{} = action) do
    Enum.each(Armada.other_member_ids(character), fn member_id ->
      Game.call(character.instance_id, :character, member_id, {:armada_attach, action.data["source"]})
    end)
  end

  def finish(%Character{} = character, %Action{} = action) do
    instance_id = character.instance_id
    c = Data.Querier.one(Data.Game.Constant, instance_id, :main)

    # enter system
    {:ok, system} =
      Game.call(instance_id, :stellar_system, action.data["target"], {:push_character, character, :on_board})

    character = Character.enter_system(character, action.data["target"], action.data["target_position"])

    # Attached transit arrival: every armada member materializes into
    # the destination BEFORE the interception pass, so the whole armada
    # fights the (single) arrival battle together — a picket can never
    # engage a partial armada (docs/armadas.md §3.4).
    companions = materialize_armada_members(character, action)

    # check interception — a two-pass check (Fight.check_interception/4):
    #
    #   1. The ARRIVER's stance decides whom it engages among the
    #      cross-faction admirals already on the system, busy or not
    #      (`arrival_engagement/1`):
    #        * `:attack_everyone` (Fury) — every fleet physically
    #          present. "Attack anything I see", including a sitter
    #          that is idle, docking, or mid-action.
    #        * `:defend` (Defender) — only fleets busy with an
    #          in-system action (pillage, bombard, conquest,
    #          colonization, dominion). Idle enemies are left alone,
    #          which is what keeps Defender distinct from Fury and lets
    #          factions under a non-aggression pact share systems.
    #        * `:attack_enemies` (Interdiction), `:fight_back`, `:flee`
    #          — nobody. Interdiction watches the door but does not
    #          pick fights when it is itself the arrival.
    #
    #   2. Every idle/docking SITTER whose stance is in
    #      `@arrival_reactions` intercepts the arriver — Interdiction
    #      and Fury catch arrivals, `:defend` does not (armed
    #      neutrality: two Defender factions can pass each other), and
    #      the passive stances never do. A sitter busy with its own
    #      action never intercepts, but pass 1 can still engage it.
    #
    # Note the asymmetry two Interdiction fleets produce: the sitter
    # intercepts the arriver even though the arriver would not have
    # engaged. Only two Interdiction fleets already sharing a system
    # leave each other alone.
    #
    # `:fight_back` and `:flee` never appear in any of the per-action
    # interception lists (raid/loot/conquest/colonization) on the
    # defender side either — by design they only react when *directly*
    # attacked. Fury overrides that on arrival because Fury's whole
    # point is to bypass any "wait to be attacked" hedging.
    # Interception-on-arrival is fleet combat — only admirals carry an army.
    # Accessing `character.army.reaction` for a spy/speaker (army == nil)
    # KeyErrors, and because that happens AFTER `enter_system` above, the
    # crash discards the entered character: the orchestrator's rescue then
    # delivers the PRE-finish character with system=nil, stranding every
    # spy/speaker jump-arrival (RCA 2026-06-17, confirmed in prod logs).
    # Gate the whole interception step on type via arrival_interception/2.
    {character, interception_notifs, leaving_or_dead?} =
      arrival_interception(character, action, companions)

    # drop explorer
    {character, exploration_notifs} =
      if leaving_or_dead?,
        do: {character, []},
        else: drop_explorer(character, action, c)

    # all characters (except admirals, undercover spies and own faction characters)
    # announce their arrival or passage
    unless character.type == :admiral or (character.type == :spy and Spy.undercover?(character.spy, instance_id)) or
             system.owner == nil or (system.owner != nil and character.owner.faction_id == system.owner.faction_id) do
      data = %{type: character.type, player: character.owner.name, system: system.name}

      notif =
        if Instance.Character.ActionQueue.empty?(character.actions),
          do: Notification.Text.new(:foreign_agent_stopped, system.id, data),
          else: Notification.Text.new(:foreign_agent_passed, system.id, data)

      Game.cast(instance_id, :player, system.owner.id, {:push_notifs, notif})
    end

    # assemble notifs
    notifs = interception_notifs ++ exploration_notifs

    {MapSet.new([:player_update]), notifs, character}
  end

  @doc """
  Arrival-interception decision for a jump finish.

  Only admirals carry an army and can be pulled into (or trigger) fleet
  combat on arrival. For spies/speakers (`army == nil`) this is a no-op —
  and gating here is what keeps `character.army.reaction` from KeyError-ing
  on non-admirals, the crash that stranded every spy/speaker jump-arrival at
  `system: nil` before 2026-06-17 (the interception-on-arrival feature
  accessed `army.reaction` unconditionally).
  """
  def arrival_interception(%Character{} = character, action),
    do: arrival_interception(character, action, [])

  # An arriving armada intercepts with its most aggressive member's
  # stance (test class 7): a Fury screen escorting a Prudent bomber
  # engages the sitters even when the bomber is the jump-executing
  # lead. `companions` are the freshly materialized co-members.
  def arrival_interception(%Character{type: :admiral} = character, action, companions) do
    effective_reaction = Armada.effective_reaction([character | companions])
    Fight.check_interception(character, action, arrival_reactions(), arrival_engagement(effective_reaction))
  end

  def arrival_interception(%Character{} = character, _action, _companions), do: {character, [], false}

  @arrival_reactions [:attack_enemies, :attack_everyone]

  @doc """
  The sitter stances that intercept an arriving fleet (pass 2). Fixed:
  Interdiction and Fury watch the door, Defender and the passive
  stances do not. See the block comment in `finish/2`.
  """
  def arrival_reactions, do: @arrival_reactions

  @doc """
  What the arriving fleet engages on its own initiative (pass 1), based
  on the arriver's own stance: `:all` for Fury, `:busy` (only enemies
  mid-action) for Defender, `:none` otherwise. Exposed so tests can pin
  the matrix without standing up the whole `Fight.check_interception`
  pipeline.
  """
  def arrival_engagement(:attack_everyone), do: :all
  def arrival_engagement(:defend), do: :busy
  def arrival_engagement(_other), do: :none

  # Flip every attached member into the destination system. Returns the
  # materialized member states so the interception pass can compute the
  # armada's effective stance. A member that cannot materialize (dead,
  # detached mid-flight) is skipped; detach paths own the cleanup.
  defp materialize_armada_members(%Character{type: :admiral} = character, %Action{} = action) do
    Enum.reduce(Armada.other_member_ids(character), [], fn member_id, acc ->
      call = {:armada_materialize, action.data["target"], action.data["target_position"]}

      case Game.call(character.instance_id, :character, member_id, call) do
        {:ok, member} -> [member | acc]
        _ -> acc
      end
    end)
  end

  defp materialize_armada_members(%Character{}, %Action{}), do: []

  defp drop_explorer(%Character{} = character, %Action{} = action, c) do
    call = {:drop_explorer, action.data["target"], character.owner.name}

    {character, notifs} =
      case Game.call(character.instance_id, :faction, character.owner.faction_id, call) do
        :dropped ->
          {_, notifs, character} = Character.add_experience(character, c.drop_explorer_xp)
          {character, notifs}

        :already_dropped ->
          {character, []}
      end

    {character, notifs}
  end
end
