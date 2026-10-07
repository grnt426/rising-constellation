defmodule Instance.Character.Training do
  @moduledoc """
  Agent training (docs/agent-training.md): the rules of the two schools a
  `:student` character can be deployed to, with no process or instance
  access so they can be tested alone.

    * `:polytech` — a Delta Polytech (`:university_open`). Any agent of the
      building's owner; passive experience at the governor rate for as long
      as it stays.
    * `:university` — the building of the agent's own type (Monolith for
      Siderians, Orb-INTEL for Erased, Aerospace Military Academy for
      Navarchs). After settling in, experience at twice the governor rate
      and one reallocation per `university_reallocation_interval`, for a
      fee. The course ends when the agent holds `university_max_reallocations`,
      or when its owner can no longer pay; either way the agent goes straight
      back to its owner's deck (`:graduated` only lives until the owner's
      player agent has read it).

  A character's `training` is a plain map (it rides in snapshots):

      %{school: :polytech | :university,
        phase: :settling | :active | :graduated,
        elapsed: ut spent in the current phase (since the last reallocation earned while :active),
        ended: nil | :completed | :unpaid}
  """

  @polytech_host :university_open
  @university_hosts %{speaker: :monument_dome, spy: :counterintelligence_open, admiral: :military_school_dome}

  # absorbs float drift between a scheduled tick and the time it measures
  @epsilon 1.0e-6

  def schools, do: [:polytech, :university]
  def types, do: Map.keys(@university_hosts)

  @doc "The building key that hosts agents of `type` for `school`."
  def host_building(:polytech, _type), do: @polytech_host
  def host_building(:university, type), do: Map.get(@university_hosts, type)
  def host_building(_school, _type), do: nil

  @doc """
  The school `building_key` hosts: `{:polytech, nil}`, `{:university, type}`,
  or nil for every other building.
  """
  def school_of(@polytech_host), do: {:polytech, nil}

  def school_of(building_key) do
    case Enum.find(@university_hosts, fn {_type, key} -> key == building_key end) do
      {type, _key} -> {:university, type}
      nil -> nil
    end
  end

  @doc "Seats a host building gives at `level`: one for a Polytech, one per level for a university."
  def seats(:polytech, _level), do: 1
  def seats(:university, level), do: level

  def new(:polytech, _constant), do: %{school: :polytech, phase: :active, elapsed: 0.0, ended: nil}

  def new(:university, constant) do
    phase = if constant.university_settle_time > 0, do: :settling, else: :active
    %{school: :university, phase: phase, elapsed: 0.0, ended: nil}
  end

  @doc "A student still in class (settling in or on its course) holds a slot of its school."
  def enrolled?(%{phase: phase}), do: phase in [:settling, :active]
  def enrolled?(_training), do: false

  @doc "Protection and Determination are cut for as long as the agent is in class."
  def penalized?(training), do: enrolled?(training)

  @doc "Multiplier on the governor's passive experience rate."
  def xp_factor(%{school: :polytech, phase: :active}, constant), do: constant.polytech_xp_factor
  def xp_factor(%{school: :university, phase: :active}, constant), do: constant.university_xp_factor
  def xp_factor(_training, _constant), do: 0.0

  @doc """
  The fee an agent of `type` and `level` pays per ut: `{resource, amount}`,
  or nil when it pays nothing (a Polytech, or a course that has ended).
  """
  def fee(type, level, %{school: :university} = training, constant) do
    if enrolled?(training) do
      case type do
        :speaker -> {:ideology, constant.university_fee_ideology * level}
        :admiral -> {:technology, constant.university_fee_technology * level}
        :spy -> {:credit, constant.university_fee_credit * level}
        _ -> nil
      end
    end
  end

  def fee(_type, _level, _training, _constant), do: nil

  @doc "Ends the course where it stands; the owner's player agent sends the agent home."
  def finish(training, reason), do: %{training | phase: :graduated, elapsed: 0.0, ended: reason}

  @doc """
  Plays `elapsed` ut of training.

  Returns `{training, reallocations, xp_time, events}`: `xp_time` is the part of
  `elapsed` spent in class (experience accrues over it at `xp_factor/2`),
  `events` the list of `:settled | :reallocation | :graduated` that happened, in
  order.
  """
  def advance(%{school: :polytech} = training, reallocations, elapsed, _constant),
    do: {training, reallocations, elapsed, []}

  def advance(%{phase: :graduated} = training, reallocations, _elapsed, _constant),
    do: {training, reallocations, 0.0, []}

  def advance(%{phase: :settling} = training, reallocations, elapsed, constant) do
    remaining = constant.university_settle_time - training.elapsed

    if elapsed + @epsilon < remaining do
      {%{training | elapsed: training.elapsed + elapsed}, reallocations, 0.0, []}
    else
      {training, reallocations, xp_time, events} =
        advance(%{training | phase: :active, elapsed: 0.0}, reallocations, max(elapsed - remaining, 0.0), constant)

      {training, reallocations, xp_time, [:settled | events]}
    end
  end

  def advance(%{phase: :active} = training, reallocations, elapsed, constant) do
    remaining = constant.university_reallocation_interval - training.elapsed

    cond do
      # already full (reallocations banked from an earlier course and none spent)
      reallocations >= constant.university_max_reallocations ->
        {finish(training, :completed), reallocations, 0.0, [:graduated]}

      elapsed + @epsilon < remaining ->
        {%{training | elapsed: training.elapsed + elapsed}, reallocations, elapsed, []}

      reallocations + 1 >= constant.university_max_reallocations ->
        {finish(training, :completed), reallocations + 1, remaining, [:reallocation, :graduated]}

      true ->
        {training, reallocations, xp_time, events} =
          advance(%{training | elapsed: 0.0}, reallocations + 1, max(elapsed - remaining, 0.0), constant)

        {training, reallocations, remaining + xp_time, [:reallocation | events]}
    end
  end

  @doc "Ut until the next phase change or reallocation earned, or `:never`."
  def next_event(%{school: :university, phase: :settling} = training, constant),
    do: max(constant.university_settle_time - training.elapsed, 0.0)

  def next_event(%{school: :university, phase: :active} = training, constant),
    do: max(constant.university_reallocation_interval - training.elapsed, 0.0)

  def next_event(_training, _constant), do: :never

  @doc """
  Ut before a student holding `reallocations` leaves its seat by itself: the
  rest of its course, or nil at a Polytech, which nobody ever has to leave.
  It is the longest an agent queued behind it can wait.
  """
  def time_left(%{school: :university, phase: phase} = training, reallocations, constant)
      when phase in [:settling, :active] do
    missing = max(constant.university_max_reallocations - (reallocations || 0), 0)

    case phase do
      :settling ->
        max(constant.university_settle_time - training.elapsed, 0.0) +
          missing * constant.university_reallocation_interval

      :active ->
        if missing == 0,
          do: 0.0,
          else:
            max(constant.university_reallocation_interval - training.elapsed, 0.0) +
              (missing - 1) * constant.university_reallocation_interval
    end
  end

  def time_left(%{school: :university}, _reallocations, _constant), do: 0.0
  def time_left(_training, _reallocations, _constant), do: nil

  @doc """
  Checks a reallocation of `old` skills into `new` for an agent whose main
  skill sits at `main_index`, holding `reallocations`.

  One reallocation moves one point. A skill that gains points may not pass
  `max_skill`, nor the main skill as it ends up — the same two limits a
  level-up respects. Returns `{:ok, points_moved}` or `{:error, reason}`.
  """
  def check_reallocation(old, new, main_index, reallocations, max_skill) do
    cond do
      not is_list(new) or length(new) != length(old) -> {:error, :invalid_skills}
      not Enum.all?(new, &(is_integer(&1) and &1 >= 0)) -> {:error, :invalid_skills}
      Enum.sum(new) != Enum.sum(old) -> {:error, :skill_points_mismatch}
      true -> check_moves(old, new, main_index, reallocations, max_skill)
    end
  end

  defp check_moves(old, new, main_index, reallocations, max_skill) do
    main = Enum.at(new, main_index)

    raised =
      [old, new]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.filter(fn {{before, later}, _index} -> later > before end)

    moved = Enum.reduce(raised, 0, fn {{before, later}, _index}, acc -> acc + later - before end)

    cond do
      moved == 0 ->
        {:error, :nothing_to_reallocate}

      moved > reallocations ->
        {:error, :not_enough_reallocations}

      Enum.any?(raised, fn {{_before, later}, _index} -> later > max_skill end) ->
        {:error, :skill_over_maximum}

      Enum.any?(raised, fn {{_before, later}, index} -> index != main_index and later > main end) ->
        {:error, :skill_over_main}

      true ->
        {:ok, moved}
    end
  end
end
