defmodule Instance.StellarSystem.School do
  @moduledoc """
  The schools of a stellar system (docs/agent-training.md): how many
  students its buildings can take, who may enrol, and who has to leave
  when a building or the system itself is lost.

  A system has up to four schools: its Polytech (every agent type shares
  it) and one university per agent type. Slots come from the buildings
  standing in the system right now:

    * Polytech — one slot per Delta Polytech, whatever its level;
    * university — one slot per level of each host building.

  Students are `Instance.StellarSystem.Character` entries carrying their
  `training` map. A student whose course has ended still stands in the
  system until its owner recalls it, but holds no slot.
  """

  alias Instance.Character.Training

  @doc "Slots of `school` for agents of `type`."
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

  @doc """
  Whether `character` (already activated as a :student) may take a seat.
  Returns `:ok` or `{:error, reason}`.
  """
  def check_enrollment(system, character, constant) do
    students = Map.get(system, :students, [])
    %{school: school} = character.training
    type = character.type
    owner = system.owner

    cond do
      system.status != :inhabited_player or is_nil(owner) -> {:error, :no_school}
      owner.faction_id != character.owner.faction_id -> {:error, :school_of_another_faction}
      system.siege != nil -> {:error, :no_character_activation_under_siege}
      Enum.any?(students, fn s -> s.id == character.id end) -> {:error, :already_enrolled}
      capacity(system, school, type) == 0 -> {:error, :no_school}
      true -> check_seat(system, students, character, constant)
    end
  end

  defp check_seat(system, students, %{training: %{school: :polytech}} = character, _constant) do
    cond do
      system.owner.id != character.owner.id -> {:error, :school_for_owner_only}
      full?(system, students, :polytech, character.type) -> {:error, :school_full}
      true -> :ok
    end
  end

  defp check_seat(system, students, %{training: %{school: :university}} = character, constant) do
    type = character.type
    guest? = system.owner.id != character.owner.id

    guests =
      students
      |> enrolled(:university, type)
      |> Enum.count(fn s -> s.owner.id == character.owner.id end)

    cond do
      guest? and character.level < constant.university_guest_min_level -> {:error, :character_level_too_low}
      # one student per player per building
      guest? and guests >= length(host_tiles(system, :university, type)) -> {:error, :one_student_per_school}
      full?(system, students, :university, type) -> {:error, :school_full}
      true -> :ok
    end
  end

  defp full?(system, students, school, type),
    do: length(enrolled(students, school, type)) >= capacity(system, school, type)

  @doc """
  Splits `students` into those who stay and those who must leave: every
  student when the system is no longer a player's or changed faction, a
  Polytech student when the system changed owner, and the latest arrivals
  of a school that lost slots.
  """
  def settle(system, students) do
    owner = if system.status == :inhabited_player, do: system.owner, else: nil

    {allowed, evicted} =
      Enum.split_with(students, fn s ->
        owner != nil and s.owner.faction_id == owner.faction_id and
          (s.training.school != :polytech or s.owner.id == owner.id)
      end)

    over =
      allowed
      |> Enum.filter(fn s -> Training.enrolled?(s.training) end)
      |> Enum.group_by(fn s -> if s.training.school == :polytech, do: :polytech, else: {:university, s.type} end)
      |> Enum.flat_map(fn {key, group} ->
        {school, type} = if key == :polytech, do: {:polytech, nil}, else: key
        Enum.drop(group, capacity(system, school, type))
      end)
      |> MapSet.new(fn s -> s.id end)

    {kept, dropped} = Enum.split_with(allowed, fn s -> not MapSet.member?(over, s.id) end)
    {kept, evicted ++ dropped}
  end

  @doc "Slots and seats taken per school, for the system view."
  def summary(system) do
    students = Map.get(system, :students, [])

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
