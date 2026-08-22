defmodule Instance.Character.Armada do
  @moduledoc """
  Pure armada logic: membership-map helpers, formation/join/break
  validation, stance priorities, and battle-side ordering.

  The armada itself is NOT a process. Its state is a plain map —
  `%{id: integer, name: String.t() | nil, member_ids: [integer]}` —
  duplicated on every member's `%Character{}` under the `:armada` key
  and kept in sync by the owning `Player.Agent` (single writer; see
  `Instance.Player.ArmadaImpl`). Reads go through `Map.get` and writes
  through `Map.put` so pre-feature snapshots (whose Character maps lack
  the key) stay restorable — see docs/armadas.md §3.1.

  Combat semantics implemented here:

    * `stance_priority/1` — battle initiation/join order:
      Fury → Interdiction → Defender → Prudent → Deserter.
    * `effective_reaction/1` — an armada acts (arrival interception,
      defensive interception) with its most aggressive member's stance.
    * `order_battle_side/2` — an armada fights as one block: the
      initiation winner's armada is pulled into the battle ahead of
      every other joiner on its side; within a block members join in
      stance-priority order (a Prudent member joins last — but joins).
  """

  alias Instance.Character.ActionQueue

  @min_size 2
  @max_size 3

  # Lower = more aggressive = joins first. Fight.Manager assigns the
  # per-side reinforcement delay by list order, so side order IS join
  # order.
  @stance_priority %{attack_everyone: 0, attack_enemies: 1, defend: 2, fight_back: 3, flee: 4}

  def min_size, do: @min_size
  def max_size, do: @max_size

  def new(id, name, member_ids),
    do: %{id: id, name: name, member_ids: Enum.sort(member_ids)}

  @doc "The armada map of a character, or nil. Snapshot-tolerant read."
  def get(character), do: Map.get(character, :armada)

  def member?(character), do: get(character) != nil

  def member_ids(character) do
    case get(character) do
      nil -> []
      armada -> Map.get(armada, :member_ids, [])
    end
  end

  def other_member_ids(character),
    do: member_ids(character) -- [character.id]

  def stance_priority(reaction), do: Map.get(@stance_priority, reaction, 99)

  @doc """
  Most aggressive reaction among the given characters (nil-army safe).
  """
  def effective_reaction(characters) when is_list(characters) do
    characters
    |> Enum.map(&reaction_of/1)
    |> Enum.min_by(&stance_priority/1, fn -> :defend end)
  end

  @doc """
  A character counts as "busy" for armada purposes when it has pending
  orders or is doing anything beyond sitting in a system (docking is
  not busy — ship construction is in-system activity). `:attached`
  members (riding an armada in transit) are busy by definition.

  This predicate backs the lead rule (test class 4): once any member
  is busy, that member is the armada's lead and nobody else may
  enqueue.
  """
  def busy?(character) do
    character.actions == nil or
      not ActionQueue.empty?(character.actions) or
      character.action_status not in [:idle, :docking]
  end

  @doc "Validate one character as a (potential) armada member."
  def validate_member_candidate(character) do
    cond do
      character.type != :admiral -> {:error, :armada_admirals_only}
      character.status != :on_board -> {:error, :armada_character_not_on_board}
      Map.get(character, :on_sold, false) -> {:error, :armada_character_on_sold}
      character.on_strike -> {:error, :armada_character_on_strike}
      reaction_of(character) == :flee -> {:error, :armada_flee_stance_forbidden}
      busy?(character) -> {:error, :armada_character_busy}
      true -> :ok
    end
  end

  @doc """
  Validate forming a new armada from two live characters. Same player
  only, co-located, both idle and unaffiliated.
  """
  def validate_formation(a, b) do
    cond do
      a.id == b.id ->
        {:error, :armada_needs_two_characters}

      a.owner == nil or b.owner == nil or a.owner.id != b.owner.id ->
        {:error, :armada_same_player_only}

      member?(a) or member?(b) ->
        {:error, :armada_already_member}

      a.system == nil or a.system != b.system ->
        {:error, :armada_not_colocated}

      true ->
        with :ok <- validate_member_candidate(a),
             :ok <- validate_member_candidate(b) do
          :ok
        end
    end
  end

  @doc """
  Validate `joiner` joining the armada whose current live members are
  `members`. A fourth member is rejected with `:armada_full` (the UI
  greys the button with this reason).
  """
  def validate_join(joiner, members) do
    cond do
      member?(joiner) ->
        {:error, :armada_already_member}

      members == [] ->
        {:error, :armada_not_found}

      length(members) >= @max_size ->
        {:error, :armada_full}

      joiner.owner == nil or Enum.any?(members, fn m -> m.owner == nil or m.owner.id != joiner.owner.id end) ->
        {:error, :armada_same_player_only}

      Enum.any?(members, fn m -> m.system == nil or m.system != joiner.system end) ->
        {:error, :armada_not_colocated}

      Enum.any?(members, &busy?/1) ->
        {:error, :armada_busy}

      true ->
        validate_member_candidate(joiner)
    end
  end

  @doc """
  Break is only allowed while the armada is at rest: no member with
  orders underway, none mid-siege, not in transit.
  """
  def validate_break(members) do
    if Enum.any?(members, &busy?/1),
      do: {:error, :armada_busy},
      else: :ok
  end

  @doc """
  Order one battle side (test classes 6, 9, 9a).

  `primary_id` is the seed of the side: the initiator on the attacker
  side, the initiation-flip winner on the defender side. Rules:

    * The primary's block (its armada, or itself when solo) goes first.
    * Every other block follows, ranked by its best member's
      `{stance_priority, -experience}`; armada members always stay
      adjacent (a block enters the battle together, in order).
    * Within a block, members are ordered by stance priority, the
      primary winning ties at equal stance, experience as tiebreak. A
      Prudent member of an armada therefore joins last of its block —
      but it does join.

  Pure: takes full `%Character{}` structs, returns them reordered.
  """
  def order_battle_side(characters, primary_id) do
    primary = Enum.find(characters, &(&1.id == primary_id))
    primary_key = if primary != nil, do: block_key(primary)

    characters
    |> Enum.group_by(&block_key/1)
    |> Enum.map(fn {key, members} ->
      {key, Enum.sort_by(members, &member_rank(&1, primary_id))}
    end)
    |> Enum.sort_by(fn {key, [best | _]} ->
      {if(key == primary_key, do: 0, else: 1), member_rank(best, primary_id)}
    end)
    |> Enum.flat_map(fn {_key, members} -> members end)
  end

  ## Private

  defp reaction_of(character) do
    case character.army do
      nil -> :defend
      army -> army.reaction
    end
  end

  defp block_key(character) do
    case get(character) do
      nil -> {:solo, character.id}
      armada -> {:armada, armada.id}
    end
  end

  defp member_rank(character, primary_id) do
    {
      stance_priority(reaction_of(character)),
      if(character.id == primary_id, do: 0, else: 1),
      -experience_of(character),
      character.id
    }
  end

  defp experience_of(character) do
    case Map.get(character, :experience) do
      %{value: value} -> value
      _ -> 0.0
    end
  end
end
