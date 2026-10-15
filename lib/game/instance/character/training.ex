defmodule Instance.Character.Training do
  @moduledoc """
  Agent training (docs/agent-training.md): the rules of the schools a
  `:student` character can be deployed to, with no process or instance
  access so they can be tested alone.

    * `:polytech` — basic training at a Delta Polytech (`:university_open`),
      the one school `passive?/1` names. One seat per building, any agent of
      the building's owner; passive experience at the governor rate for as
      long as it stays, no fee, no queue, no settling in, no rewire.
    * `:university` — specialized training at the building of the agent's
      own type (Monolith for Siderians, Orb-INTEL for Erased, Aerospace
      Military Academy for Navarchs), for the faction: one place at
      building levels 1 and 2, two at 3 and 4, three at 5 (`seats/2`).
      After settling in, experience at twice the governor rate and one
      reallocation per `university_reallocation_interval`, for a fee. The course ends when the agent holds `university_max_reallocations`,
      or when its owner can no longer pay; either way the agent goes straight
      back to its owner's deck (`:graduated` only lives until the owner's
      player agent has read it).

  A character's `training` is a plain map (it rides in snapshots):

      %{school: :polytech | :university,
        phase: :settling | :active | :graduated,
        elapsed: ut spent in the current phase (since the last reallocation earned while :active),
        ended: nil | :completed | :unpaid,
        at: the action clock (`Instance.Time.Time.now/1`, ms) when `elapsed` was last measured, or nil,
        xp_bonus, time_factor, cost_factor, school_level: the conditions of the system it sits in (see below)}

  ## Conditions

  The buildings of the system the student sits in change its course
  (`Instance.StellarSystem.School.conditions/3`): Experiment Stations add
  to the experience every student earns, Delta Polytechs shorten the time a
  rewire takes, Holodomes cut the fee of a course, and the level of the
  university sets part of that fee and how far the student's defence falls.
  The student ticks by itself, so its system hands it those four numbers
  and they ride in its `training`:

    * `xp_bonus` — percent added to the school's experience rate;
    * `time_factor` — multiplier on `university_reallocation_interval`;
    * `cost_factor` — multiplier on the fee;
    * `school_level` — the highest level among the buildings of its
      university, nil at a Polytech.

  They postdate the first students: read them with `conditions/1`.

  `elapsed` only moves when the student ticks, which is at its next event:
  hours apart. `at` is what lets a client holding a copy tell how far along
  the phase is right now (front/src/game/training.js), the way an action's
  `started_at` does. It postdates the first students: read it with
  `anchored_at/1`.
  """

  # one seat per building for its owner's agents, and the governor's rate
  @passive_hosts %{polytech: :university_open}
  @university_hosts %{speaker: :monument_dome, spy: :counterintelligence_open, admiral: :military_school_dome}

  @default_conditions %{xp_bonus: 0.0, time_factor: 1.0, cost_factor: 1.0, school_level: nil}

  # Protection and Determination of a university student, as a share of its
  # own, by the level of its university
  @university_defense %{1 => 0.4, 2 => 0.5, 3 => 0.6, 4 => 0.7, 5 => 0.8}

  # absorbs float drift between a scheduled tick and the time it measures
  @epsilon 1.0e-6

  def schools, do: passive_schools() ++ [:university]
  def passive_schools, do: [:polytech]
  def types, do: Map.keys(@university_hosts)

  @doc "A Delta Polytech: one seat per building, every agent type, its owner alone, no queue."
  def passive?(school), do: Map.has_key?(@passive_hosts, school)

  @doc "The building key that hosts agents of `type` for `school`."
  def host_building(:university, type), do: Map.get(@university_hosts, type)
  def host_building(school, _type), do: Map.get(@passive_hosts, school)

  @doc """
  The school `building_key` hosts: `{:polytech, nil}`, `{:university, type}`,
  or nil for every other building.
  """
  def school_of(building_key) do
    passive = Enum.find(@passive_hosts, fn {_school, key} -> key == building_key end)
    university = Enum.find(@university_hosts, fn {_type, key} -> key == building_key end)

    case {passive, university} do
      {{school, _key}, _} -> {school, nil}
      {nil, {type, _key}} -> {:university, type}
      {nil, nil} -> nil
    end
  end

  @doc """
  Seats a host building gives at `level`: one for a Polytech, whatever its
  level; one at levels 1 and 2 of a university, two at 3 and 4, three at 5.
  """
  def seats(:university, level) when level >= 5, do: 3
  def seats(:university, level) when level >= 3, do: 2
  def seats(:university, _level), do: 1
  def seats(_school, _level), do: 1

  def new(:university, constant) do
    phase = if constant.university_settle_time > 0, do: :settling, else: :active
    Map.merge(@default_conditions, %{school: :university, phase: phase, elapsed: 0.0, ended: nil, at: nil})
  end

  def new(school, _constant),
    do: Map.merge(@default_conditions, %{school: school, phase: :active, elapsed: 0.0, ended: nil, at: nil})

  @doc "The conditions `training` runs under, the defaults for a map that carries none."
  def conditions(training) when is_map(training) do
    Map.new(@default_conditions, fn {key, default} ->
      {key, if(is_nil(Map.get(training, key)), do: default, else: Map.get(training, key))}
    end)
  end

  def conditions(_training), do: @default_conditions

  @doc """
  Puts `training` under new `conditions` (a map with `xp_bonus`,
  `time_factor`, `cost_factor` and `school_level`). A rewire being earned keeps the share
  of it already done: `elapsed` is scaled with the time a rewire now takes.
  """
  def set_conditions(training, conditions) when is_map(training) do
    before = conditions(training)
    later = Map.merge(before, Map.take(conditions, Map.keys(@default_conditions)))

    training =
      if training.school == :university and training.phase == :active and before.time_factor > 0,
        do: %{training | elapsed: training.elapsed * later.time_factor / before.time_factor},
        else: training

    Map.merge(training, later)
  end

  def set_conditions(training, _conditions), do: training

  @doc "Ut a rewire takes under the conditions of `training`."
  def reallocation_interval(training, constant),
    do: constant.university_reallocation_interval * conditions(training).time_factor

  @doc "The action clock reading `elapsed` was measured at, nil when unknown."
  def anchored_at(training) when is_map(training), do: Map.get(training, :at)
  def anchored_at(_training), do: nil

  @doc "Stamps `elapsed` as measured at `clock` (a reading of the action clock)."
  def anchor(training, clock) when is_map(training), do: Map.put(training, :at, clock)
  def anchor(training, _clock), do: training

  @doc "A student still in class (settling in or on its course) holds a slot of its school."
  def enrolled?(%{phase: phase}), do: phase in [:settling, :active]
  def enrolled?(_training), do: false

  @doc "Protection and Determination are cut for as long as the agent is in class."
  def penalized?(training), do: enrolled?(training)

  @doc """
  The share of its own Protection and Determination a student in class
  keeps: 40% at a university of level 1, ten points more per level, 80% at
  level 5; `training_defense_factor` (a half) at a Polytech, and for a
  university student whose map predates `school_level`.
  """
  def defense_factor(%{school: :university} = training, constant) do
    case conditions(training).school_level do
      level when is_integer(level) -> Map.fetch!(@university_defense, level |> max(1) |> min(5))
      _ -> constant.training_defense_factor
    end
  end

  def defense_factor(_training, constant), do: constant.training_defense_factor

  @doc """
  Multiplier on the governor's passive experience rate: the school's own,
  raised by the `xp_bonus` of the system.
  """
  def xp_factor(%{phase: :active} = training, constant) do
    base = if training.school == :university, do: constant.university_xp_factor, else: constant.polytech_xp_factor
    base * (1 + conditions(training).xp_bonus / 100)
  end

  def xp_factor(_training, _constant), do: 0.0

  @doc """
  The fee an agent of `type` and `level` pays per ut: `{resource, amount}`,
  or nil when it pays nothing (a Polytech, or a course that has ended).
  The standard salary is apart: it is never discounted. One rate per resource, paid once per level of the
  agent and once per level of its university, less what the Holodomes of
  the system take off (`cost_factor`).
  """
  def fee(type, level, %{school: :university} = training, constant) do
    %{school_level: school_level, cost_factor: cost_factor} = conditions(training)
    levels = (level + (school_level || 0)) * cost_factor

    if enrolled?(training) do
      case type do
        :speaker -> {:ideology, constant.university_fee_ideology * levels}
        :admiral -> {:technology, constant.university_fee_technology * levels}
        :spy -> {:credit, constant.university_fee_credit * levels}
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
  def advance(%{phase: :graduated} = training, reallocations, _elapsed, _constant),
    do: {training, reallocations, 0.0, []}

  def advance(%{school: school} = training, reallocations, elapsed, _constant) when school != :university,
    do: {training, reallocations, elapsed, []}

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
    remaining = reallocation_interval(training, constant) - training.elapsed

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
    do: max(reallocation_interval(training, constant) - training.elapsed, 0.0)

  def next_event(_training, _constant), do: :never

  @doc """
  Ut before a student holding `reallocations` leaves its seat by itself: the
  rest of its course under its current conditions, or nil at a Polytech,
  which nobody ever has to leave.
  It is the longest an agent queued behind it can wait.
  """
  def time_left(%{school: :university, phase: phase} = training, reallocations, constant)
      when phase in [:settling, :active] do
    missing = max(constant.university_max_reallocations - (reallocations || 0), 0)
    interval = reallocation_interval(training, constant)

    case phase do
      :settling ->
        max(constant.university_settle_time - training.elapsed, 0.0) + missing * interval

      :active ->
        if missing == 0,
          do: 0.0,
          else: max(interval - training.elapsed, 0.0) + (missing - 1) * interval
    end
  end

  def time_left(%{school: :university}, _reallocations, _constant), do: 0.0
  def time_left(_training, _reallocations, _constant), do: nil

  @doc """
  Checks a reallocation of `old` skills into `new` for an agent whose main
  skill sits at `main_index`, holding `reallocations`.

  One reallocation moves one point from a skill to another, and two add a
  point to a skill outright: a point a skill gains costs one when another
  skill gave it up, two otherwise (`reallocation_cost/2`). Every point taken
  has to be placed. A skill that gains points may not pass `max_skill`, nor
  the main skill as it ends up — the same two limits a level-up respects.
  Returns `{:ok, reallocations_spent}` or `{:error, reason}`.
  """
  def check_reallocation(old, new, main_index, reallocations, max_skill) do
    cond do
      not is_list(new) or length(new) != length(old) -> {:error, :invalid_skills}
      not Enum.all?(new, &(is_integer(&1) and &1 >= 0)) -> {:error, :invalid_skills}
      Enum.sum(new) < Enum.sum(old) -> {:error, :skill_points_mismatch}
      true -> check_moves(old, new, main_index, reallocations, max_skill)
    end
  end

  @doc """
  Reallocations it takes to turn `old` skills into `new`: one per point
  moved, two per point added. Points gained are paired with the points
  taken first, so a move is never billed as an addition.
  """
  def reallocation_cost(old, new) do
    changes = Enum.zip_with(old, new, fn before, later -> later - before end)
    gained = changes |> Enum.filter(&(&1 > 0)) |> Enum.sum()
    taken = changes |> Enum.filter(&(&1 < 0)) |> Enum.sum() |> abs()

    gained + max(gained - taken, 0)
  end

  defp check_moves(old, new, main_index, reallocations, max_skill) do
    main = Enum.at(new, main_index)

    raised =
      [old, new]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.filter(fn {{before, later}, _index} -> later > before end)

    cost = reallocation_cost(old, new)

    cond do
      raised == [] ->
        {:error, :nothing_to_reallocate}

      cost > reallocations ->
        {:error, :not_enough_reallocations}

      Enum.any?(raised, fn {{_before, later}, _index} -> later > max_skill end) ->
        {:error, :skill_over_maximum}

      Enum.any?(raised, fn {{_before, later}, index} -> index != main_index and later > main end) ->
        {:error, :skill_over_main}

      true ->
        {:ok, cost}
    end
  end
end
