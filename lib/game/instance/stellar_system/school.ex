defmodule Instance.StellarSystem.School do
  @moduledoc """
  The schools of a stellar system (docs/agent-training.md): how many
  students its buildings can take, who may enrol or wait for a seat, and
  who has to leave when a building or the system itself is lost.

  A system has up to four schools: its Polytech (every agent type shares
  it) and one university per agent type. Seats come from the buildings
  standing in the system right now, and the whole faction shares them:

    * Polytech — one seat per Delta Polytech, whatever its level, for the
      system's owner alone;
    * university — one seat per level of each host building, for agents of
      `university_min_level` or more, the owner's own included.

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

  @doc "Students in class in `school`. The Polytech is one school for all types."
  def enrolled(students, :polytech, _type) do
    Enum.filter(students, fn s -> s.training.school == :polytech and Training.enrolled?(s.training) end)
  end

  def enrolled(students, :university, type) do
    Enum.filter(students, fn s ->
      s.training.school == :university and s.type == type and Training.enrolled?(s.training)
    end)
  end

  @doc "Queue entries of `school`, in order of arrival."
  def queued(queue, :polytech, _type), do: Enum.filter(queue, fn e -> e.school == :polytech end)
  def queued(queue, :university, type), do: Enum.filter(queue, fn e -> e.school == :university and e.type == type end)

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
        Enum.any?(students(system), fn s -> s.id == character.id end) -> {:error, :already_enrolled}
        Enum.any?(queue, fn e -> e.id == character.id end) -> {:error, :character_queued}
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

      school == :polytech and owner.id != character.owner.id ->
        {:error, :school_for_owner_only}

      # a university is for seasoned agents, its owner's included
      school == :university and character.level < constant.university_min_level ->
        {:error, :character_level_too_low}

      true ->
        :ok
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
        room = capacity(system, school, type) - length(enrolled(kept, school, type))
        {held, waiting} = Enum.split_with(group, fn e -> e.called end)

        # seats held that the school no longer has
        gone = Enum.drop(held, max(room, 0))
        free = room - length(held) + length(gone)

        # nobody walks into a siege: the seat waits for it to be lifted
        next =
          if system.siege == nil and free > 0,
            do: waiting |> Enum.sort_by(fn e -> if e.behind == leaver_id, do: 0, else: 1 end) |> Enum.take(free),
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

  # a school takes its owner's faction, and a Polytech its owner alone
  defp welcome?(nil, _school, _agent), do: false

  defp welcome?(owner, school, agent),
    do: agent.owner.faction_id == owner.faction_id and (school != :polytech or agent.owner.id == owner.id)

  defp school_key(:polytech, _type), do: {:polytech, nil}
  defp school_key(school, type), do: {school, type}

  @doc "Seats and seats taken per school, for the system view."
  def summary(system) do
    students = students(system)

    universities =
      Map.new(Training.types(), fn type ->
        {type, %{slots: capacity(system, :university, type), used: length(enrolled(students, :university, type))}}
      end)

    Map.put(universities, :polytech, %{
      slots: capacity(system, :polytech, nil),
      used: length(enrolled(students, :polytech, nil))
    })
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
