defmodule Instance.StellarSystem.School do
  @moduledoc """
  The schools of a stellar system (docs/agent-training.md): how many
  students its buildings can take, who may enrol or wait for a seat, and
  who has to leave when a building or the system itself is lost.

  A system has up to six schools: its Polytech, its Citadel and its
  Holodome (every agent type shares each of them) and one university per
  agent type. Seats come from the buildings standing in the system right
  now, and the whole faction shares them:

    * Polytech, Citadel and Holodome — one seat per Delta Polytech, one per
      Citadel and one per Holodome, whatever their level, for the system's
      owner alone;
    * university — one seat per level of each host building, for agents of
      `university_min_level` or more, the owner's own included. A player
      holds one seat per building, whatever its level (`player_seats/3`):
      the seats of a high building are for many players, the owner of the
      system like any other. The limit is asked of whoever comes in:
      `settle/2` turns nobody out for it, so a player seated twice before it
      existed keeps both seats.

  Students are `Instance.StellarSystem.Character` entries carrying their
  `training` map.

  ## The queue

  One agent may wait behind each seated student (`system.school_queue`). It
  stays in its owner's deck; the entry here is only its place in line:

      %{id, name, type, level, owner, school,
        behind: id of the student it waits for,
        called: true once a seat is held for it}

  When a seat comes free it goes to the agent waiting behind the student
  who left, or failing that to the first one waiting in that school. The
  entry is then `called`: the seat is held, and the owner's player agent is
  told to send the agent in (`{:school_seat_ready, ...}`). Nobody is called
  while the system is under siege; the seat is held until it is lifted. An
  agent waiting behind a student whose seat is lost with it (building
  damaged or demolished, system changed hands) loses its place.

  ## Conditions

  The system's buildings also set the conditions of every course in it
  (`conditions/3`, and `Instance.Character.Training`, "Conditions"): the
  experience its Delta Polytechs add (`system.training_xp`), the rewire
  time its Citadels take off (`system.reallocation_time`) and the share of
  the fee its Holodomes take off (`system.training_cost`), all three summed
  over every building of the system by the bonus pipeline, and the level of
  a university, which is part of its fee. `outdated/1` names the students whose course still runs
  under other conditions, for the system to tell them.

  The queue is how a player lines up a second agent for a university
  building it already sits in: behind its own student, whose seat it takes
  over. Behind another player's student it would end up with a second seat,
  so that place is refused, and `settle/2` calls no agent whose owner holds
  every seat it may.
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
  Seats one player may hold in `school`: one per building at a university,
  and no limit (nil) at a Polytech, which seats one agent per building and
  its owner alone.
  """
  def player_seats(system, :university, type), do: system |> host_tiles(:university, type) |> length()
  def player_seats(_system, _school, _type), do: nil

  @doc """
  Seats `player_id` holds in `school`: its students in class and the seats
  held for its agents the queue has called, the agent `except_id` left out.
  """
  def seats_held(system, school, type, player_id, except_id \\ nil) do
    mine = fn list -> Enum.count(list, fn a -> a.owner.id == player_id and a.id != except_id end) end
    called = system |> queue() |> queued(school, type) |> Enum.filter(fn e -> e.called end)

    mine.(enrolled(students(system), school, type)) + mine.(called)
  end

  @doc "Students in class in `school`. A Polytech, a Citadel or a Holodome is one school for all types."
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
        seats_taken?(system, character, school) -> {:error, :one_agent_per_building}
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

  A player holding every seat it may in a university waits behind its own
  student and nobody else's, whether the school is full or not: none of the
  free seats is for a second agent of that player.
  """
  def check_queue(system, character, school, behind_id, constant) do
    type = character.type
    queue = queue(system)
    seated = enrolled(students(system), school, type)
    taken = MapSet.new(queue, fn e -> e.behind end)
    own? = fn agent -> agent.owner.id == character.owner.id end
    seats_taken? = seats_taken?(system, character, school)

    ahead =
      cond do
        behind_id != nil -> Enum.find(seated, fn s -> s.id == behind_id end)
        seats_taken? -> Enum.find(seated, fn s -> own?.(s) and not MapSet.member?(taken, s.id) end)
        true -> Enum.find(seated, fn s -> not MapSet.member?(taken, s.id) end)
      end

    with :ok <- check_access(system, character, school, constant) do
      cond do
        Enum.any?(students(system), fn s -> s.id == character.id end) -> {:error, :already_enrolled}
        Enum.any?(queue, fn e -> e.id == character.id end) -> {:error, :character_queued}
        not seats_taken? and free_seats(system, school, type) > 0 -> {:error, :school_has_free_seat}
        is_nil(ahead) and is_nil(behind_id) -> {:error, :queue_taken}
        is_nil(ahead) -> {:error, :student_not_found}
        MapSet.member?(taken, ahead.id) -> {:error, :queue_taken}
        own?.(ahead) -> {:ok, entry(character, school, ahead.id), ahead}
        seats_wanted?(system, character, school) -> {:error, :one_agent_per_building}
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

  # Whether the owner of `character` already holds every seat it may in
  # `school`. The seat held for the agent itself, once the queue has called
  # it, is not held against it.
  defp seats_taken?(system, character, school) do
    case player_seats(system, school, character.type) do
      nil -> false
      limit -> seats_held(system, school, character.type, character.owner.id, character.id) >= limit
    end
  end

  # Whether the owner of `character` holds or waits for every seat it may in
  # `school`: its seats, and its agents in line behind other players'
  # students, each of which is after a seat of its own. An agent behind its
  # owner's student only takes that seat over.
  defp seats_wanted?(system, character, school) do
    type = character.type
    player_id = character.owner.id
    own_students = system |> students() |> enrolled(school, type) |> Enum.filter(fn s -> s.owner.id == player_id end)
    own_ids = MapSet.new(own_students, fn s -> s.id end)

    waiting =
      system
      |> queue()
      |> queued(school, type)
      |> Enum.count(fn e -> e.owner.id == player_id and not e.called and not MapSet.member?(own_ids, e.behind) end)

    case player_seats(system, school, type) do
      nil -> false
      limit -> seats_held(system, school, type, player_id) + waiting >= limit
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
      longer use the school, the student they waited for was evicted, or
      the seat held for them is gone;
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
        welcome?(owner, e.school, e) and not MapSet.member?(evicted_ids, e.behind) and
          capacity(system, e.school, e.type) > 0
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
              |> call(free, player_seats(system, school, type), taken),
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
  # take, `taken` being the seats each player holds. An agent behind its
  # owner's student is passed over until that student leaves.
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

  # a school takes its owner's faction, and a Polytech, a Citadel or a Holodome its owner alone
  defp welcome?(nil, _school, _agent), do: false

  defp welcome?(owner, school, agent),
    do: agent.owner.faction_id == owner.faction_id and (not Training.passive?(school) or agent.owner.id == owner.id)

  defp school_key(:university, type), do: {:university, type}
  defp school_key(school, _type), do: {school, nil}

  @doc """
  Seats, seats taken and the seats one player may hold (nil: no limit) per
  school (`:polytech`, `:citadel`, `:holodome`, and a university under its
  agent type), for the system view.
  """
  def summary(system) do
    students = students(system)

    universities =
      Map.new(Training.types(), fn type ->
        {type,
         %{
           slots: capacity(system, :university, type),
           used: length(enrolled(students, :university, type)),
           per_player: player_seats(system, :university, type)
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

  # a rewire never takes less than this share of its time, and a course
  # never costs less than this share of its fee, whatever is built
  @min_time_factor 0.25
  @min_cost_factor 0.25

  @doc """
  The conditions a course of `school` runs under in this system right now,
  for agents of `type`: the map `Training.set_conditions/2` takes.

  `training_xp`, `reallocation_time` and `training_cost` are percentages
  summed by the bonus pipeline over the system's buildings (+3 per level of
  a Delta Polytech, -1.5 per level of a Citadel, -4 per level of a
  Holodome). They postdate the first snapshots: Map.get only.
  """
  def conditions(system, school, type) do
    %{
      xp_bonus: Float.round(max(bonus(system, :training_xp), 0.0), 4),
      time_factor: factor(bonus(system, :reallocation_time), @min_time_factor),
      cost_factor: factor(bonus(system, :training_cost), @min_cost_factor),
      school_level: school_level(system, school, type)
    }
  end

  # a percentage taken off (never added), as the multiplier it leaves
  defp factor(percent, floor), do: Float.round(max(1 + min(percent, 0.0) / 100, floor), 4)

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
