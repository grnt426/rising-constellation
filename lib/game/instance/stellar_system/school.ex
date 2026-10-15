defmodule Instance.StellarSystem.School do
  @moduledoc """
  The schools of a stellar system (docs/agent-training.md): how many
  students its buildings can take, who may enrol or wait for a seat, and
  who has to leave when a building or the system itself is lost.

  A system has up to four schools: its Polytech (every agent type shares
  it) and one university per agent type. Seats come from the buildings
  standing in the system right now:

    * Polytech (basic training) — one seat per Delta Polytech, whatever its
      level, for the system's owner alone. No queue.
    * university (specialized training) — per building, one place at
      levels 1 and 2, two at 3 and 4, three at 5, shared by the faction,
      for agents of `university_min_level` or more, the owner's own
      included. A player holds one place per building, studying or waiting
      (`player_places/3`): the places of a high building are for many
      players, the owner of the system like any other. The limit is asked
      of whoever comes in: `settle/2` turns nobody out for it.

  Students are `Instance.StellarSystem.Character` entries carrying their
  `training` map.

  ## The queue

  At a university, one agent may wait behind each seated student
  (`system.school_queue`), when no seat is free. It stays in its owner's
  deck, holding an agent slot; the entry here is only its place in line:

      %{id, name, type, level, owner, school,
        behind: id of the student it waits for,
        called: true once a seat is held for it}

  When a seat comes free it goes to the agent waiting behind the student
  who left, or failing that to the first one waiting in that school. The
  entry is then `called`: the seat is held, and the owner's player agent is
  told to send the agent in (`{:school_seat_ready, ...}`). Nobody is called
  while the system is under siege; the seat is held until it is lifted. An
  agent waiting behind a student whose seat is lost with it (building
  damaged or demolished, system changed hands) loses its place, and so
  does an entry left at a Polytech by a game from before it lost its
  queue.

  ## Conditions

  The system's buildings also set the conditions of every course in it
  (`conditions/3`, and `Instance.Character.Training`, "Conditions"): the
  experience its Experiment Stations add (`system.training_xp`), the rewire
  time its Delta Polytechs take off (`system.reallocation_time`) and the
  share of the fee its Holodomes take off (`system.training_cost`), all
  three summed over every building of the system by the bonus pipeline, and
  the level of a university, which is part of its fee and sets how far its
  students' defence falls. `outdated/1` names the students whose course
  still runs under other conditions, for the system to tell them.
  """

  alias Instance.Character.Training

  def students(system), do: Map.get(system, :students, []) || []
  def queue(system), do: Map.get(system, :school_queue, []) || []

  @doc "Seats of `school` for agents of `type`."
  def capacity(system, school, type) do
    system
    |> host_tiles(school, type)
    |> Enum.reduce(0, fn tile, acc -> acc + Training.seats(school, tile.building_level) end)
  end

  @doc """
  Places one player may hold in `school`, a seat or a place in line: one per
  building at a university, and no limit (nil) at a Polytech, which seats
  one agent per building and its owner alone.
  """
  def player_places(system, :university, type), do: system |> host_tiles(:university, type) |> length()
  def player_places(_system, _school, _type), do: nil

  @doc """
  Places `player_id` holds in `school`: its students in class and its agents
  in line, called or not, the agent `except_id` left out.
  """
  def places_held(system, school, type, player_id, except_id \\ nil) do
    mine = fn list -> Enum.count(list, fn a -> a.owner.id == player_id and a.id != except_id end) end

    mine.(enrolled(students(system), school, type)) + mine.(queued(queue(system), school, type))
  end

  @doc "Students in class in `school`. The Polytech is one school for all types."
  def enrolled(students, :university, type) do
    Enum.filter(students, fn s ->
      s.training.school == :university and s.type == type and Training.enrolled?(s.training)
    end)
  end

  def enrolled(students, school, _type) do
    Enum.filter(students, fn s -> s.training.school == school and Training.enrolled?(s.training) end)
  end

  @doc "Queue entries of `school`, in order of arrival."
  def queued(queue, :university, type), do: Enum.filter(queue, fn e -> e.school == :university and e.type == type end)
  def queued(queue, school, _type), do: Enum.filter(queue, fn e -> e.school == school end)

  @doc "Seats neither taken nor held for a queued agent."
  def free_seats(system, school, type) do
    held = system |> queue() |> queued(school, type) |> Enum.count(fn e -> e.called end)
    capacity(system, school, type) - length(enrolled(students(system), school, type)) - held
  end

  @doc """
  Whether `character` (already activated as a :student) may take a seat.
  An agent the queue has called has its seat held. Returns `:ok` or
  `{:error, reason}`.
  """
  def check_enrollment(system, character, constant) do
    %{school: school} = character.training
    type = character.type
    called? = Enum.any?(queue(system), fn e -> e.id == character.id and e.called end)

    with :ok <- check_access(system, character, school, constant) do
      cond do
        Enum.any?(students(system), fn s -> s.id == character.id end) -> {:error, :already_enrolled}
        places_taken?(system, character, school) -> {:error, :one_agent_per_building}
        called? -> :ok
        free_seats(system, school, type) <= 0 -> {:error, :school_full}
        true -> :ok
      end
    end
  end

  @doc """
  Whether `character` (in its owner's deck) may wait behind the student
  `behind_id` of `school`, or behind the first student nobody waits for when
  `behind_id` is nil. Returns `{:ok, entry, ahead}` (the queue entry and the
  student it waits for) or `{:error, reason}`.

  Only a university has a queue. A player with an agent studying or waiting
  in a building has no second place there, its own student's included.
  """
  def check_queue(system, character, school, behind_id, constant) do
    type = character.type
    queue = queue(system)
    seated = enrolled(students(system), school, type)
    taken = MapSet.new(queue, fn e -> e.behind end)

    ahead =
      if is_nil(behind_id),
        do: Enum.find(seated, fn s -> not MapSet.member?(taken, s.id) end),
        else: Enum.find(seated, fn s -> s.id == behind_id end)

    with :ok <- check_access(system, character, school, constant) do
      cond do
        Training.passive?(school) -> {:error, :school_has_no_queue}
        Enum.any?(students(system), fn s -> s.id == character.id end) -> {:error, :already_enrolled}
        Enum.any?(queue, fn e -> e.id == character.id end) -> {:error, :character_queued}
        places_taken?(system, character, school) -> {:error, :one_agent_per_building}
        free_seats(system, school, type) > 0 -> {:error, :school_has_free_seat}
        is_nil(ahead) and is_nil(behind_id) -> {:error, :queue_taken}
        is_nil(ahead) -> {:error, :student_not_found}
        MapSet.member?(taken, ahead.id) -> {:error, :queue_taken}
        true -> {:ok, entry(character, school, ahead.id), ahead}
      end
    end
  end

  # what a school asks of anyone, seated or waiting
  defp check_access(system, character, school, constant) do
    owner = system.owner

    cond do
      system.status != :inhabited_player or is_nil(owner) ->
        {:error, :no_school}

      owner.faction_id != character.owner.faction_id ->
        {:error, :school_of_another_faction}

      system.siege != nil ->
        {:error, :no_character_activation_under_siege}

      capacity(system, school, character.type) == 0 ->
        {:error, :no_school}

      Training.passive?(school) and owner.id != character.owner.id ->
        {:error, :school_for_owner_only}

      # a university is for seasoned agents, its owner's included
      school == :university and character.level < constant.university_min_level ->
        {:error, :character_level_too_low}

      true ->
        :ok
    end
  end

  # Whether the owner of `character` already holds every place it may in
  # `school`, studying or waiting. The agent's own place in line is not held
  # against it: called to its seat, it trades one for the other.
  defp places_taken?(system, character, school) do
    case player_places(system, school, character.type) do
      nil -> false
      limit -> places_held(system, school, character.type, character.owner.id, character.id) >= limit
    end
  end

  defp entry(character, school, behind_id) do
    %{
      id: character.id,
      name: character.name,
      type: character.type,
      level: character.level,
      owner: character.owner,
      school: school,
      behind: behind_id,
      called: false
    }
  end

  @doc """
  Puts the schools in order after any change, `leaver_id` being the student
  who just left its seat, if one did. Returns a map:

    * `:students` — who stays;
    * `:evicted` — students who must leave: every one when the system is no
      longer a player's or changed faction, a Polytech student when the
      system changed owner, and the latest arrivals of a school that lost
      seats;
    * `:queue` — the queue that remains;
    * `:cleared` — queue entries that lost their place: their owner may no
      longer use the school, the student they waited for was evicted, the
      seat held for them is gone, or they wait at a Polytech, which has no
      queue any more;
    * `:called` — entries a seat is now held for.
  """
  def settle(system, leaver_id \\ nil) do
    owner = if system.status == :inhabited_player, do: system.owner, else: nil

    {allowed, turned_out} = Enum.split_with(students(system), fn s -> welcome?(owner, s.training.school, s) end)

    over =
      allowed
      |> Enum.filter(fn s -> Training.enrolled?(s.training) end)
      |> Enum.group_by(fn s -> school_key(s.training.school, s.type) end)
      |> Enum.flat_map(fn {{school, type}, group} -> Enum.drop(group, capacity(system, school, type)) end)
      |> MapSet.new(fn s -> s.id end)

    {kept, dropped} = Enum.split_with(allowed, fn s -> not MapSet.member?(over, s.id) end)
    evicted = turned_out ++ dropped
    evicted_ids = MapSet.new(evicted, fn s -> s.id end)

    {queue, cleared} =
      Enum.split_with(queue(system), fn e ->
        welcome?(owner, e.school, e) and not Training.passive?(e.school) and
          not MapSet.member?(evicted_ids, e.behind) and capacity(system, e.school, e.type) > 0
      end)

    {queue, lost, called} =
      queue
      |> Enum.group_by(fn e -> school_key(e.school, e.type) end)
      |> Enum.reduce({queue, [], []}, fn {{school, type}, group}, {queue, lost, called} ->
        seated = enrolled(kept, school, type)
        room = capacity(system, school, type) - length(seated)
        {held, waiting} = Enum.split_with(group, fn e -> e.called end)

        # seats held that the school no longer has
        gone = Enum.drop(held, max(room, 0))
        free = room - length(held) + length(gone)
        taken = Enum.frequencies_by(seated ++ (held -- gone), fn a -> a.owner.id end)

        # nobody walks into a siege: the seat waits for it to be lifted
        next =
          if system.siege == nil and free > 0,
            do:
              waiting
              |> Enum.sort_by(fn e -> if e.behind == leaver_id, do: 0, else: 1 end)
              |> call(free, player_places(system, school, type), taken),
            else: []

        gone_ids = MapSet.new(gone, fn e -> e.id end)
        next_ids = MapSet.new(next, fn e -> e.id end)

        queue =
          queue
          |> Enum.reject(fn e -> MapSet.member?(gone_ids, e.id) end)
          |> Enum.map(fn e -> if MapSet.member?(next_ids, e.id), do: %{e | called: true}, else: e end)

        {queue, lost ++ gone, called ++ next}
      end)

    %{students: kept, evicted: evicted, queue: queue, cleared: cleared ++ lost, called: called}
  end

  # The first `free` agents of `waiting` whose owner still has a seat to
  # take, `taken` being the seats each player holds: a player seated
  # before the limit existed is passed over until it is back under it.
  defp call(waiting, free, limit, taken) do
    {picked, _taken} =
      Enum.reduce(waiting, {[], taken}, fn e, {picked, taken} ->
        held = Map.get(taken, e.owner.id, 0)

        if length(picked) < free and (is_nil(limit) or held < limit),
          do: {[e | picked], Map.put(taken, e.owner.id, held + 1)},
          else: {picked, taken}
      end)

    Enum.reverse(picked)
  end

  # a school takes its owner's faction, and a Polytech its owner alone
  defp welcome?(nil, _school, _agent), do: false

  defp welcome?(owner, school, agent),
    do: agent.owner.faction_id == owner.faction_id and (not Training.passive?(school) or agent.owner.id == owner.id)

  defp school_key(:university, type), do: {:university, type}
  defp school_key(school, _type), do: {school, nil}

  @doc """
  Seats, seats taken and the seats one player may hold (nil: no limit) per
  school (`:polytech`, and a university under its agent type), for the
  system view.
  """
  def summary(system) do
    students = students(system)

    universities =
      Map.new(Training.types(), fn type ->
        {type,
         %{
           slots: capacity(system, :university, type),
           used: length(enrolled(students, :university, type)),
           per_player: player_places(system, :university, type)
         }}
      end)

    Enum.reduce(Training.passive_schools(), universities, fn school, acc ->
      Map.put(acc, school, %{
        slots: capacity(system, school, nil),
        used: length(enrolled(students, school, nil)),
        per_player: nil
      })
    end)
  end

  # The Holodomes of a system take at most 80% off the fee of a course. The
  # experience and the rewire time have no cap: a system only holds so
  # many buildings. The cut on the rewire time stops at 99% as a guard, not
  # a balance rule: six Delta Polytechs of level 5 take 45% off, and it
  # would take a system of a hundred and thirty of them to reach it.
  @max_fee_cut 80.0
  @max_time_cut 99.0

  @doc """
  The conditions a course of `school` runs under in this system right now,
  for agents of `type`: the map `Training.set_conditions/2` takes.

  `training_xp`, `reallocation_time` and `training_cost` are percentages
  summed by the bonus pipeline over the system's buildings. A building of
  level 1 to 5 gives 10, 25, 45, 70 and 100% of its level-5 effect: +15%
  experience for an Experiment Station, -7.5% rewire time for a Delta
  Polytech, -15% fee for a Holodome. They postdate the first snapshots:
  Map.get only.
  """
  def conditions(system, school, type) do
    %{
      xp_bonus: Float.round(max(bonus(system, :training_xp), 0.0), 4),
      time_bonus: cut(bonus(system, :reallocation_time), @max_time_cut),
      cost_bonus: cut(bonus(system, :training_cost), @max_fee_cut),
      school_level: school_level(system, school, type)
    }
  end

  # a percentage taken off, never added, and never more than `max`
  defp cut(percent, max), do: Float.round(max(min(percent, 0.0), -max), 4)

  @doc "The highest level among the buildings of a university, nil for any other school or with none standing."
  def school_level(system, :university, type) do
    case host_tiles(system, :university, type) do
      [] -> nil
      tiles -> tiles |> Enum.map(fn tile -> tile.building_level end) |> Enum.max()
    end
  end

  def school_level(_system, _school, _type), do: nil

  @doc """
  Students in class whose course runs under other conditions than the
  system now gives: `[{student, conditions}]`.
  """
  def outdated(system) do
    system
    |> students()
    |> Enum.filter(fn s -> Training.enrolled?(s.training) end)
    |> Enum.map(fn s -> {s, conditions(system, s.training.school, s.type)} end)
    |> Enum.reject(fn {s, conditions} -> Training.conditions(s.training) == conditions end)
  end

  defp bonus(system, key) do
    case Map.get(system, key) do
      %{value: value} when is_number(value) -> value * 1.0
      _ -> 0.0
    end
  end

  defp host_tiles(system, school, type) do
    key = Training.host_building(school, type)

    system.bodies
    |> flatten_bodies()
    |> Enum.flat_map(fn body -> body.tiles end)
    |> Enum.filter(fn tile -> tile.building_status == :built and tile.building_key == key end)
  end

  defp flatten_bodies(bodies) do
    Enum.flat_map(bodies, fn body -> [body | flatten_bodies(body.bodies)] end)
  end
end
