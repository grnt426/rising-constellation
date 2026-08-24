defmodule Instance.Player.ArmadaImpl do
  @moduledoc """
  Player-side armada orchestration. The owning `Player.Agent` is the
  armada's single writer — every membership change (form, join, break,
  detach-on-death/deactivation) and every armada gate (the lead rule,
  the Deserter-stance ban) runs through here, called from the agent's
  handlers so all mutations are serialized per player.

  Membership is applied to the live character agents via
  `{:update_armada, map | nil}`; that handler refreshes the player's
  character cache through the standard `{:update_character}` cast, so
  nothing here touches `Player` internals beyond `own_character?/2`. A
  member whose agent is unreachable (dead, being killed) is skipped —
  the detach paths own that cleanup.
  """

  require Logger

  alias Instance.Character.ActionQueue
  alias Instance.Character.Armada
  alias Instance.Player.Player

  ## Commands (channel-driven)

  @doc "Form a new 2-Navarch armada from two live, idle, co-located admirals."
  def form(instance_id, %Player{} = data, character_id, other_id) do
    with {:own, true} <-
           {:own, Player.own_character?(data, character_id) and Player.own_character?(data, other_id)},
         {:ok, a} <- get_live(instance_id, character_id),
         {:ok, b} <- get_live(instance_id, other_id),
         :ok <- Armada.validate_formation(a, b) do
      armada = Armada.new(a.id, pick_name(instance_id), [a.id, b.id])
      apply_membership(instance_id, armada.member_ids, armada)
    else
      {:own, false} -> {:error, :character_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :character_not_found}
    end
  end

  @doc """
  Join `character_id` to the armada `armada_member_id` belongs to. A
  fourth member is rejected with `:armada_full`.
  """
  def join(instance_id, %Player{} = data, character_id, armada_member_id) do
    with {:own, true} <-
           {:own, Player.own_character?(data, character_id) and Player.own_character?(data, armada_member_id)},
         {:ok, joiner} <- get_live(instance_id, character_id),
         {:ok, target} <- get_live(instance_id, armada_member_id),
         {:armada, %{} = armada} <- {:armada, Armada.get(target)},
         members <- fetch_states(instance_id, Map.get(armada, :member_ids, [])),
         :ok <- Armada.validate_join(joiner, members) do
      armada = %{armada | member_ids: Enum.sort([character_id | armada.member_ids])}
      apply_membership(instance_id, armada.member_ids, armada)
    else
      {:own, false} -> {:error, :character_not_found}
      {:armada, nil} -> {:error, :armada_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :character_not_found}
    end
  end

  @doc """
  Break `character_id` out of its armada. Only allowed while the
  armada is at rest (nobody busy, not in transit). Falling below 2
  members dissolves the armada entirely.
  """
  def break(instance_id, %Player{} = data, character_id) do
    with {:own, true} <- {:own, Player.own_character?(data, character_id)},
         {:ok, character} <- get_live(instance_id, character_id),
         {:armada, %{} = armada} <- {:armada, Armada.get(character)},
         members <- fetch_states(instance_id, Map.get(armada, :member_ids, [])),
         :ok <- Armada.validate_break(members) do
      detach_by_map(instance_id, armada, character_id)
    else
      {:own, false} -> {:error, :character_not_found}
      {:armada, nil} -> {:error, :armada_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :character_not_found}
    end
  end

  ## Gates

  @doc """
  The lead rule (test class 4): once any Navarch of an armada has
  orders underway, that Navarch is the armada's lead and no other
  member may enqueue anything until the armada is idle again. Also
  blocks departures while any member is building ships (a docking
  member cannot leave with the armada).
  """
  def check_enqueue(instance_id, character_id, actions) do
    case get_live(instance_id, character_id) do
      {:ok, character} ->
        case Armada.get(character) do
          nil -> :ok
          armada -> do_check_enqueue(instance_id, character, armada, actions)
        end

      # let the normal add_actions path surface unreachable characters
      _ ->
        :ok
    end
  end

  @doc "The Deserter stance cannot be used inside an armada (test class 3)."
  def check_reaction(instance_id, character_id, reaction) do
    if reaction == :flee do
      case get_live(instance_id, character_id) do
        {:ok, character} ->
          if Armada.member?(character),
            do: {:error, :armada_flee_stance_forbidden},
            else: :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  ## Detach paths

  @doc """
  Remove `character_id` from `armada`, dissolving the armada when
  fewer than 2 members remain. Safe when the leaving character's agent
  is already dead (its `{:update_armada, nil}` is skipped).
  """
  def detach_by_map(instance_id, armada, character_id) do
    remaining = Map.get(armada, :member_ids, []) -- [character_id]

    if length(remaining) < Armada.min_size() do
      apply_membership(instance_id, Map.get(armada, :member_ids, []), nil)
    else
      :ok = apply_membership(instance_id, remaining, %{armada | member_ids: remaining})
      apply_membership(instance_id, [character_id], nil)
    end
  end

  @doc """
  Detach applied to a character struct (nil-armada safe) — the common
  entry for death/deactivation call sites.
  """
  def detach(instance_id, character) do
    case Map.get(character, :armada) do
      nil -> :ok
      armada -> detach_by_map(instance_id, armada, character.id)
    end
  end

  ## Armada-wide retreat (test class 5)

  @doc """
  Decide this losing member's role in the armada's retreat. The first
  member of a beaten armada to reach its `fight_callback(:fleeing)`
  becomes the flee-lead — it enqueues the (single) retreat jump; every
  later member is a follower — it clears its remaining orders and
  idles, and the flee-lead's `Jump.start` re-attaches it for the
  retreat. Detection is stateless: the flee-lead is recognizable as
  the member whose queue is exactly one pending jump.
  """
  def armada_flee_role(instance_id, character, armada) do
    already_fleeing? =
      instance_id
      |> fetch_states(Map.get(armada, :member_ids, []) -- [character.id])
      |> Enum.any?(&flee_pending?/1)

    if already_fleeing?, do: :follower, else: :lead
  end

  ## Private

  defp do_check_enqueue(instance_id, character, armada, actions) do
    others = fetch_states(instance_id, Map.get(armada, :member_ids, []) -- [character.id])

    cond do
      # gateway travel is a separate action chain with no attach
      # fan-out — an armada lead using it would leave its members
      # behind and break co-location. Unsupported inside armadas (v1).
      has_gateway?(actions) ->
        {:error, :armada_no_gateway}

      Enum.any?(others, &Armada.busy?/1) ->
        {:error, :armada_led_by_other}

      has_jump?(actions) and Enum.any?([character | others], &departure_blocked?/1) ->
        {:error, :armada_member_docking}

      true ->
        :ok
    end
  end

  defp has_jump?(actions),
    do: Enum.any?(actions, fn action -> action["type"] == "jump" end)

  defp has_gateway?(actions),
    do: Enum.any?(actions, fn action -> action["type"] in ["gateway_charge", "gateway_jump", "gateway_fatigue"] end)

  defp departure_blocked?(character) do
    character.action_status == :docking or
      (character.army != nil and Instance.Character.Army.has_planned_ship?(character.army))
  end

  defp flee_pending?(character) do
    with false <- character.actions == nil,
         actions <- ActionQueue.skip_initial_lock(character.actions),
         [%{type: :jump}] <- Queue.to_list(actions.queue) do
      true
    else
      _ -> false
    end
  end

  defp apply_membership(instance_id, member_ids, armada) do
    Enum.each(member_ids, fn id ->
      case Game.call(instance_id, :character, id, {:update_armada, armada}) do
        {:ok, _character} ->
          :ok

        other ->
          # dead/unreachable members are expected on the detach paths;
          # logged so operators can correlate with player reports
          Logger.warning("[armada] membership update skipped unreachable member",
            instance_id: instance_id,
            character_id: id,
            result: inspect(other)
          )
      end
    end)

    :ok
  end

  defp get_live(instance_id, character_id) do
    case Game.call(instance_id, :character, character_id, :get_state) do
      {:ok, character} -> {:ok, character}
      _ -> {:error, :character_not_found}
    end
  end

  defp fetch_states(instance_id, ids) do
    ids
    |> Enum.map(fn id ->
      case Game.call(instance_id, :character, id, :get_state) do
        {:ok, character} -> character
        _ -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  # With-replacement draw from the armada name pool, matching the
  # capital-ship naming precedent. nil (unnamed) when the pool or the
  # rand agent is unavailable — never fail a formation over a name.
  defp pick_name(instance_id) do
    Data.Picker.random("armada", instance_id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
