defmodule Instance.Victory.Victory do
  use TypedStruct

  alias Instance.Victory
  alias Portal.Controllers.FactionChannel

  @tick_interval 10
  @final_unit_days 200
  @next_update_unit_days 20

  def jason(), do: [except: [:instance_id, :next_update, :time_only]]

  typedstruct enforce: true do
    field(:ut_time_left, float())
    field(:victory_points, integer())
    field(:inhabitable_systems_count, integer())
    field(:factions, [%Victory.Faction{}])
    field(:sectors, [%Victory.Sector{}])
    field(:winner, nil | atom())
    field(:instance_id, integer())
    field(:next_update, %Core.DynamicValue{})
    # When true the game can end *only* on the clock — the points-based win
    # (victory_points >= 14) is ignored. Set for daily challenges, which reuse
    # this agent but must run their full timer. Defaults to false / optional so
    # a pre-field snapshot (a multiplayer instance restored across this change)
    # deserializes cleanly and keeps the normal points-win behaviour.
    field(:time_only, boolean(), default: false, enforce: false)
  end

  def new(ut_time_left, victory_points, inhabitable_systems, sectors, factions, instance_id, time_only \\ false) do
    next_update = Core.DynamicValue.new(0, :misc, Core.ValuePart.new(:default, 1))

    %Victory.Victory{
      ut_time_left: ut_time_left,
      victory_points: victory_points,
      inhabitable_systems_count: inhabitable_systems,
      factions: Enum.map(factions, &Victory.Faction.convert/1),
      sectors: Enum.map(sectors, &Victory.Sector.convert/1),
      winner: nil,
      instance_id: instance_id,
      next_update: next_update,
      time_only: time_only
    }
  end

  def update_sector(state, new_sector) do
    sectors =
      Enum.map(state.sectors, fn sector ->
        if sector.id == new_sector.id,
          do: Victory.Sector.convert(new_sector),
          else: sector
      end)

    %{state | sectors: sectors} |> update_tracks()
  end

  def add_player(state, faction_id) do
    factions =
      Enum.map(state.factions, fn faction ->
        if faction.id == faction_id,
          do: Victory.Faction.add_player(faction),
          else: faction
      end)

    %{state | factions: factions} |> update_tracks()
  end

  def reset_player_count(state, players) do
    factions = Enum.map(state.factions, fn f -> Victory.Faction.reset_player_count(f, players) end)
    %{state | factions: factions}
  end

  def update_systems(state, systems) do
    factions =
      Enum.map(state.factions, fn faction ->
        counts =
          systems
          |> Enum.filter(fn s -> s.faction == faction.key end)
          |> Enum.reduce({0, 0, 0, 0, 0.0}, fn s,
                                                {possession_count, system_count, dominion_count, population_points,
                                                 population_value} ->
            possession_count = possession_count + 1
            system_count = if s.status == :inhabited_player, do: system_count + 1, else: system_count
            dominion_count = if s.status == :inhabited_dominion, do: dominion_count + 1, else: dominion_count

            class = Data.Querier.one(Data.Game.PopulationClass, state.instance_id, s.class)
            population_points = population_points + class.points

            # Raw population sum is independent of the bucketized class.points and
            # only feeds the tie-break score (see tie_break_score/2). Galaxy.StellarSystem.convert/1
            # carries system.population.value through verbatim.
            population_value = population_value + (s.population || 0.0)

            {possession_count, system_count, dominion_count, population_points, population_value}
          end)

        Victory.Faction.update_systems_count(faction, counts)
      end)

    %{state | factions: factions} |> update_tracks()
  end

  def update_visibility(state, faction_key, visibility_count) do
    factions =
      Enum.map(state.factions, fn faction ->
        if faction.key == faction_key,
          do: Victory.Faction.update_visibility(faction, visibility_count),
          else: faction
      end)

    %{state | factions: factions} |> update_tracks()
  end

  def compute_next_tick_interval(_state),
    do: @tick_interval

  # Tick handling

  def next_tick(state, elapsed_time) do
    {MapSet.new(), state, nil}
    |> update_next_update(elapsed_time)
    |> decrease_ut_time_left(elapsed_time)
    |> check_for_victory(elapsed_time)
    |> check_for_closing_game(elapsed_time)
  end

  # Core functions

  defp update_next_update({change, state, export}, elapsed_time) do
    next_update = Core.DynamicValue.next_tick(state.next_update, elapsed_time)

    {next_update, change} =
      if next_update.value >= @next_update_unit_days do
        next_update = Core.DynamicValue.change_value(next_update, 0.0)
        change = MapSet.put(change, :victory_update)
        {next_update, change}
      else
        {next_update, change}
      end

    {change, %{state | next_update: next_update}, export}
  end

  defp decrease_ut_time_left({change, state, export}, elapsed_time) do
    {change, %{state | ut_time_left: state.ut_time_left - elapsed_time}, export}
  end

  defp check_for_victory({change, %{winner: nil} = state, export}, _elapsed_time) do
    # check if instance has reached the time limit
    time_is_up = state.ut_time_left <= 0

    # check victory
    current_rankings = rank_factions(state)
    leader = List.first(current_rankings)

    # Daily challenges (time_only) end *only* when the clock runs out: they
    # reuse this agent but must ignore the points-based win. A solo player on a
    # single-system daily trips `victory_points >= 14` almost for free — owning
    # the lone sector already maxes the conquest track (10 pts), so a little
    # population growth (+5) ends the run minutes before the deadline. Map.get
    # keeps a pre-field snapshot defaulting to the normal points-win behaviour.
    # See lib/daily + docs/daily-challenge.md.
    has_winner = not Map.get(state, :time_only, false) and leader.victory_points >= 14

    victory_type =
      cond do
        time_is_up -> "win_on_time"
        has_winner -> "victory_track"
        true -> false
      end

    if victory_type do
      state = %{state | winner: leader.key, ut_time_left: @final_unit_days}
      change = change |> MapSet.put(:victory) |> MapSet.put(:victory_update)
      export = %{ranking: current_rankings, victory_type: victory_type}
      {change, state, export}
    else
      {change, state, export}
    end
  end

  defp check_for_victory({change, state, export}, _elapsed_time) do
    {change, state, export}
  end

  # Sort factions for the win-declaration. Primary key is the integer
  # victory_points (the bucketized win-track score). On ties — which happen
  # often on `win_on_time` since the track only takes 12 distinct values in
  # [0, 27] and most timed-out games cluster low — we break the tie with the
  # continuous score in `tie_break_score/2`. Without this, Enum.sort's
  # stability would just hand victory to whichever faction happens to be first
  # in `state.factions` (i.e. lowest faction id).
  def rank_factions(state) do
    Enum.sort(state.factions, fn a, b ->
      cond do
        a.victory_points > b.victory_points -> true
        a.victory_points < b.victory_points -> false
        true -> tie_break_score(a, state) >= tie_break_score(b, state)
      end
    end)
  end

  # Continuous, normalized tie-break score for a faction in [0, 3]. Three
  # equally-weighted terms, each clamped to [0, 1] by construction:
  #
  #   conquest   = possession_count / inhabitable_systems_count
  #                (a faction can only own colonizable systems, so this caps
  #                 at 1.0 only when it owns the entire habitable galaxy)
  #
  #   population = total_raw_pop / (possession_count * 160)
  #                160 is the :prodigious threshold from PopulationClass —
  #                the highest class in Data.Game.PopulationClass.Content.
  #                Past 160 a system gives no extra victory_points anyway, so
  #                this is the natural per-system ceiling. Capped at 1.0
  #                defensively even though pop *can* exceed 160 (population
  #                growth turns negative above habitation + 0.75, but a
  #                transient overshoot shouldn't break the sort).
  #
  #   visibility = visibility_count / (enemy_possessions * 5)
  #                Matches max_visibility_points from update_tracks/1 —
  #                Core.VisibilityValue clamps each system at 5, so a faction
  #                tops out at 5 per enemy-held system.
  #
  # Deliberately ignores the bucketized population_points / track indices.
  # Those drove the tie in the first place; using them again as the
  # tie-break would just reproduce the bucket collision.
  def tie_break_score(faction, state) do
    conquest_ratio =
      if state.inhabitable_systems_count > 0,
        do: faction.possession_count / state.inhabitable_systems_count,
        else: 0.0

    # Defensive default: typedstruct's enforce only fires at compile-time
    # construction, not when restoring a snapshot from before this field
    # existed. A snapshot-then-tick window can land here with the key
    # entirely absent from the struct, so Map.get/3 is required — plain
    # `faction.population_value || 0.0` raises KeyError before the `||`
    # runs. update_systems repopulates on the next system tick.
    population_value = Map.get(faction, :population_value, 0.0) || 0.0

    population_ratio =
      if faction.possession_count > 0 do
        raw = population_value / (faction.possession_count * 160)
        Enum.min([raw, 1.0])
      else
        0.0
      end

    enemy_possessions =
      state.factions
      |> Enum.filter(fn f -> f.key != faction.key end)
      |> Enum.reduce(0, fn f, acc -> acc + f.possession_count end)

    visibility_ratio =
      if enemy_possessions > 0,
        do: faction.visibility_count / (enemy_possessions * 5),
        else: 0.0

    conquest_ratio + population_ratio + visibility_ratio
  end

  defp check_for_closing_game({change, state, export}, _elapsed_time) do
    if state.winner != nil and state.ut_time_left <= 0 and not any_connected_players?(state),
      do: {MapSet.put(change, :close_game), state, export},
      else: {change, state, export}
  end

  defp update_tracks(state) do
    total_sector_points = Enum.reduce(state.sectors, 0, fn s, acc -> acc + s.value end)
    total_player_count = Enum.reduce(state.factions, 0, fn f, acc -> acc + f.player_count end)
    total_faction_count = length(state.factions)

    factions =
      Enum.map(state.factions, fn faction ->
        faction_weighting =
          if total_player_count > 0 do
            weight = :math.pow(faction.player_count / (total_player_count / total_faction_count), 0.5)
            Enum.max([Enum.min([weight, 1.5]), 0.5])
          else
            1
          end

        foreign_possessions =
          state.factions
          |> Enum.filter(fn f -> f.key != faction.key end)
          |> Enum.reduce(0, fn f, acc -> acc + f.possession_count end)

        # conquest
        conquest_points =
          state.sectors
          |> Enum.filter(fn s -> s.owner == faction.key end)
          |> Enum.reduce(0, fn s, acc -> acc + s.value end)

        conquest_thresholds =
          [0.0, 0.25, 0.6, 0.95]
          |> Enum.with_index()
          |> Enum.map(fn {coeff, index} ->
            threshold = Float.round(coeff * total_sector_points * 2 * (1 / total_faction_count) * faction_weighting)
            threshold = Enum.max([threshold, index])
            Enum.min([threshold, total_sector_points])
          end)

        # population
        population_points = faction.population_points
        max_points_possible = state.inhabitable_systems_count * 16
        cap_by_player = 400

        population_thresholds =
          [0.0, 0.15, 0.3, 0.6]
          |> Enum.with_index()
          |> Enum.map(fn {coeff, index} ->
            threshold = Float.round(coeff * max_points_possible * faction_weighting)
            threshold = Enum.max([threshold, index])
            Enum.min([threshold, cap_by_player * coeff * faction.player_count + index])
          end)

        # visibility
        visibility_points = faction.visibility_count
        max_visibility_points = foreign_possessions * 5

        visibility_thresholds =
          [0.0, 0.3, 0.8, 0.98]
          |> Enum.with_index()
          |> Enum.map(fn {coeff, index} ->
            threshold = Float.round(coeff * max_visibility_points * 2 * (1 / total_faction_count) * faction_weighting)
            threshold = Enum.max([threshold, index])
            Enum.min([threshold, max_visibility_points + index])
          end)

        # final points
        threshold_values = [0, 2, 5, 10]
        conquest_index = length(Enum.filter(conquest_thresholds, fn t -> conquest_points >= t end)) - 1
        population_index = length(Enum.filter(population_thresholds, fn t -> population_points >= t end)) - 1
        visibility_index = length(Enum.filter(visibility_thresholds, fn t -> visibility_points >= t end)) - 1

        victory_points =
          Enum.at(threshold_values, conquest_index) + Enum.at(threshold_values, population_index) +
            Enum.at(threshold_values, visibility_index)

        %{
          faction
          | conquest_track: %{points: conquest_points, index: conquest_index, milestones: conquest_thresholds},
            population_track: %{points: population_points, index: population_index, milestones: population_thresholds},
            visibility_track: %{points: visibility_points, index: visibility_index, milestones: visibility_thresholds},
            victory_points: victory_points
        }
      end)

    %{state | factions: factions}
  end

  defp any_connected_players?(%{factions: factions, instance_id: instance_id}) do
    all_faction_channels_empty =
      factions
      |> Enum.map(fn %{id: faction_id} ->
        FactionChannel.topic(%{instance_id: instance_id, faction_id: faction_id})
        |> Portal.Presence.list()
        |> Enum.empty?()
      end)
      |> Enum.all?()

    not all_faction_channels_empty
  end
end
