defmodule SystemAI.Helper do
  alias SystemAI.BuildingsHelper

  def profiles() do
    [:production, :credit, :technologic, :ideologic, :defense]
  end

  # Shares of twenty. A military system is the most valuable to take once it
  # is built up and a faction needs fewer of them, so it gets a little less
  # than an even share and credit a little more.
  @profile_lots [production: 4, credit: 5, technologic: 4, ideologic: 4, defense: 3]

  @doc "How many lots in twenty each system type holds when a system is generated."
  def profile_lots, do: @profile_lots

  @doc """
  The list a new system draws its type from: each type once per lot, so one
  even draw over it follows `profile_lots/0`.
  """
  def profile_draw do
    Enum.flat_map(@profile_lots, fn {profile, lots} -> List.duplicate(profile, lots) end)
  end

  def get_workforce_range(system_value) do
    cond do
      system_value >= 0 and system_value < 8 -> 0..2
      system_value >= 8 and system_value < 18 -> 2..4
      system_value >= 18 -> 3..6
    end
  end

  # Probabilities
  ################

  @doc """
  Return tuple of 5 probabilities that match a category. The sum is 1.
  The order is [p_prod, p_cred, p_ideo, p_techno, p_defense}
  """
  def get_profile_probabilities(profile_key) do
    probabilities =
      case profile_key do
        :balanced -> [1 / 5, 1 / 5, 1 / 5, 1 / 5, 1 / 5]
        :production -> [1 / 2, 1 / 8, 1 / 8, 1 / 8, 1 / 8]
        :credit -> [1 / 8, 1 / 2, 1 / 8, 1 / 8, 1 / 8]
        :technologic -> [1 / 8, 1 / 8, 1 / 2, 1 / 8, 1 / 8]
        :ideologic -> [1 / 8, 1 / 8, 1 / 8, 1 / 2, 1 / 8]
        :defense -> [1 / 8, 1 / 8, 1 / 8, 1 / 8, 1 / 2]
      end

    Enum.zip([:production, :credit, :technologic, :ideologic, :defense], probabilities)
  end

  @doc """
  Compute a shifted distribution based on `p_base` and the map of ratios `k_values`.
  If k is 1 the corresponding category in `p_base` is not considered.
  """
  def get_cumulated_probabilities(p_base, k_values) do
    # shift with k values
    shifted_probabilities =
      Enum.zip(p_base, k_values)
      |> Enum.map(fn {{category, p_base}, {_category, k}} -> {category, (1 - k) * p_base} end)
      |> Enum.filter(fn {_category, p} -> p != 0 end)

    # sum of new density
    sum_shifted_probabilities = Enum.reduce(shifted_probabilities, 0, fn {_category, p}, acc -> p + acc end)

    # normalize to have the sum equal to 1
    normalized_shifted_probabilities =
      Enum.map(shifted_probabilities, fn {category, p} -> {category, p / sum_shifted_probabilities} end)

    # compute cumulated probabilities
    normalized_shifted_probabilities
    |> Enum.scan(fn {category, p}, {_c, p_prev} -> {category, p + p_prev} end)
  end

  @doc """
  With the list of cumulated probabilities and a random variable r in [0,1[, draws a random building category.
  """
  def get_random_category(cumulated_probabilities, r) do
    Enum.reduce(cumulated_probabilities, nil, fn {category, p}, category_acc ->
      if r < p and category_acc == nil,
        do: category,
        else: category_acc
    end)
  end

  @doc """
  Get a random building. The buildings are filtered by the profile, the system
  value, the biome, and already-built unique buildings.
  """
  def get_random_building(instance_id, profile_key, biome_key, body, bodies, system_value) do
    filtered_buildings = drawable_buildings(instance_id, profile_key, biome_key, body, bodies, system_value)

    if Enum.empty?(filtered_buildings),
      do: nil,
      else: Game.call(instance_id, :rand, :master, {:random, filtered_buildings})
  end

  @doc """
  The buildings a category draw on `body` chooses among. `tiers` is `:stage`
  (only the buildings of the system's current stage, as the vanilla tree
  draws) or `:up_to` (those and every earlier stage's).
  """
  def drawable_buildings(instance_id, profile_key, biome_key, body, bodies, system_value, tiers \\ :stage) do
    BuildingsHelper.get_biome_buildings(biome_key, instance_id)
    |> filter_buildings_by_system_value(system_value, tiers)
    |> filter_building_by_profile(profile_key)
    |> filter_already_built_unique_buildings(body, bodies)
  end

  # --- suited draws (the Rebel Dominion tree) -------------------------------------

  # A military system builds what a shipyard system needs: production first,
  # then defense, credit to pay for the ships, a little research, and hardly
  # any ideology. Lots out of 21.
  @military_lots [production: 8, credit: 3, technologic: 2, ideologic: 1, defense: 7]

  # ... and inside a category it leans the same way, bonus by bonus: what
  # defends the system or trains its crews counts three times over,
  # production and stability a little more, research less, ideology and
  # mobility half. The tripling is what lets a shield or an academy, flat
  # buildings both, clear the build floor even on a planet whose best
  # potential is a 5 (x0.25 there, so x0.75 with it).
  @military_emphasis %{
    sys_defense: 3.0,
    sys_fighter_lvl: 3.0,
    sys_corvette_lvl: 3.0,
    sys_frigate_lvl: 3.0,
    sys_capital_lvl: 3.0,
    sys_production: 1.25,
    sys_happiness: 1.25,
    sys_technology: 0.75,
    sys_ideology: 0.5,
    sys_mobility: 0.5
  }

  @doc """
  The category odds the suited draw starts from. Every system type but the
  military one uses `get_profile_probabilities/1`.
  """
  def get_suited_profile_odds(:defense) do
    total = @military_lots |> Keyword.values() |> Enum.sum()
    Enum.map(@military_lots, fn {category, lots} -> {category, lots / total} end)
  end

  def get_suited_profile_odds(profile_key), do: get_profile_probabilities(profile_key)

  @doc "What a system type wants less (or more) of, as `SystemAI.Weights.building/4` takes it."
  def suited_emphasis(:defense), do: @military_emphasis
  def suited_emphasis(_profile_key), do: %{}

  @doc """
  Like `get_random_building/6`, but every building's lots are multiplied by
  how well it suits `body` (`SystemAI.Weights.building/4`): a building that
  scales with a potential the body lacks is seldom drawn, and a flat-bonus
  building is drawn where it displaces the least. Earlier stages' buildings
  stay on offer. Returns `{building, multiplier}` or nil.
  """
  def get_suited_building(state, profile_key, biome_key, body, bodies, system_value) do
    weigh = suited_weigher(state, body, bodies, biome_key, system_value)

    state.instance_id
    |> drawable_buildings(profile_key, biome_key, body, bodies, system_value, :up_to)
    |> Enum.map(&{&1, weigh.(&1)})
    |> draw_weighted(state.instance_id)
  end

  @doc """
  Each category's odds on `body`: the system type's base odds times the mean
  multiplier of the category's pool, 0 for an empty pool. Scaling the
  category by its pool carries the buildings' lots through the category draw,
  which matters wherever a category holds a single building.
  """
  def get_suited_category_odds(state, body, bodies, biome_key, system_value) do
    weigh = suited_weigher(state, body, bodies, biome_key, system_value)

    Enum.map(get_suited_profile_odds(state.ai_profile), fn {profile_key, base} ->
      weights =
        state.instance_id
        |> drawable_buildings(profile_key, biome_key, body, bodies, system_value, :up_to)
        |> Enum.map(weigh)

      {profile_key, if(weights == [], do: 0.0, else: base * Enum.sum(weights) / length(weights))}
    end)
  end

  @doc """
  What a flat-bonus building on `body` would displace: the best multiplier a
  scaling building could still get there, over every category's pool. Low on
  a body whose potentials are all poor, and on one whose good potential is
  already used by a one-per-body building.
  """
  def body_opportunity(state, body, bodies, biome_key, system_value) do
    profiles()
    |> Enum.flat_map(&drawable_buildings(state.instance_id, &1, biome_key, body, bodies, system_value, :up_to))
    |> Enum.uniq_by(& &1.key)
    |> SystemAI.Weights.opportunity(body, state)
  end

  defp suited_weigher(state, body, bodies, biome_key, system_value) do
    opts = [
      opportunity: body_opportunity(state, body, bodies, biome_key, system_value),
      emphasis: suited_emphasis(state.ai_profile)
    ]

    &SystemAI.Weights.building(&1, body, state, opts)
  end

  @doc "One legal upgrade, drawn by how well each building suits the body it stands on."
  def get_suited_upgrade(state, candidates) do
    buildings = Map.new(BuildingsHelper.get_all_buildings(state.instance_id), &{&1.key, &1})
    bodies = Map.new(get_bodies(state), &{&1.uid, &1})
    opts = [emphasis: suited_emphasis(state.ai_profile)]

    candidates
    |> Enum.map(fn tile ->
      building = Map.fetch!(buildings, tile.building_key)
      {tile, SystemAI.Weights.building(building, Map.fetch!(bodies, tile.body_id), state, opts)}
    end)
    |> draw_weighted(state.instance_id)
  end

  @doc "One draw over `[{item, weight}]`, as `{item, weight}`; nil for an empty list."
  def draw_weighted([], _instance_id), do: nil

  def draw_weighted(weighted, instance_id) do
    total = weighted |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total <= 0 do
      # Nothing worth any lots at all: an even draw, so weights never leave a pool undrawable.
      Game.call(instance_id, :rand, :master, {:random, weighted})
    else
      mark = Game.call(instance_id, :rand, :master, {:uniform}) * total

      weighted
      |> Enum.reduce_while(0.0, fn {_item, weight} = entry, seen ->
        if mark < seen + weight, do: {:halt, {:drawn, entry}}, else: {:cont, seen + weight}
      end)
      |> case do
        {:drawn, entry} -> entry
        # float rounding left the mark a hair past the last share
        _ -> List.last(weighted)
      end
    end
  end

  # --- specials: one-per-system flat buildings in orbit ---------------------------

  @doc """
  The orbital buildings a system holds one of and that pay the same on any
  body: the shipyards and the radar. Read off the catalog.
  """
  def special_buildings(instance_id) do
    :orbital
    |> BuildingsHelper.get_biome_buildings(instance_id)
    |> Enum.filter(&(&1.limitation == :unique_system and SystemAI.Weights.flat?(&1)))
  end

  @doc "The specials the system has neither built nor started."
  def missing_specials(state, bodies \\ nil) do
    standing = tile_building_keys(bodies || get_bodies(state))
    Enum.reject(special_buildings(state.instance_id), &(&1.key in standing))
  end

  @doc """
  The missing specials the system could start now: on offer at its stage
  (earlier stages included) and within its free workforce.
  """
  def buildable_specials(state, system_value) do
    _first..last//_ = get_workforce_range(system_value)
    free = state.workforce - state.used_workforce
    Enum.filter(missing_specials(state), &(&1.workforce <= last and &1.workforce <= free))
  end

  @doc """
  The uids of the moons and asteroids kept free for the specials: the poorest
  one, since a flat building displaces the least there. A military system
  keeps as many of its poorest as it takes to hold every special, so it can
  have the full set of shipyards. Nothing is kept once no special is missing.
  """
  def reserved_bodies(state) do
    bodies = get_bodies(state)

    if missing_specials(state, bodies) == [] do
      []
    else
      moons =
        bodies
        |> Enum.filter(&(body_type_to_biome_key(&1.type) == :orbital))
        |> Enum.sort_by(&poorness/1)

      wanted = if state.ai_profile == :defense, do: length(special_buildings(state.instance_id)), else: 1

      moons
      |> Enum.reduce_while({[], 0}, fn moon, {kept, tiles} ->
        if tiles >= wanted,
          do: {:halt, {kept, tiles}},
          else: {:cont, {[moon.uid | kept], tiles + length(moon.tiles)}}
      end)
      |> elem(0)
      |> Enum.reverse()
    end
  end

  # Poorest first: lowest best potential, then lowest potentials overall; among
  # equals the one with more tiles, as it holds more specials.
  defp poorness(body) do
    potentials =
      for key <- [:industrial_factor, :technological_factor, :activity_factor],
          value = Map.get(body, key),
          is_number(value),
          do: value

    {Enum.max(potentials, fn -> 0 end), Enum.sum(potentials), -length(body.tiles), body.uid}
  end

  @doc """
  The body of `building`'s biome where it would displace the least, among the
  bodies that can take a normal building now (a free tile, and on a planet
  its infrastructure in place). nil when there is none.
  """
  def best_body_for(state, building, system_value) do
    bodies = get_bodies(state)

    bodies
    |> Enum.filter(&(body_type_to_biome_key(&1.type) == building.biome and buildable_tiles(&1) != []))
    |> Enum.min_by(&{body_opportunity(state, &1, bodies, building.biome, system_value), &1.uid}, fn -> nil end)
  end

  @doc """
  Filters the buildings by profile.

  The `profile` atom is mapped to an atom of the %Building{} struct.
  """
  def filter_building_by_profile(buildings, profile) do
    building_output =
      case profile do
        :production -> :prod
        :credit -> :credit
        :technologic -> :tech
        :ideologic -> :ideo
        :defense -> :defense
      end

    buildings
    |> Enum.filter(fn building ->
      building_output in building.outputs
    end)
  end

  @doc """
  Returns a ratio for each building category. If the ratio is 1, the dominion will not consider the category.

  The buildings are filtered by the system value and by already-built unique
  buildings — the same filters `get_random_building/6` applies. Keeping the two
  in sync guarantees a drawn category always has at least one drawable
  building; a category whose pool the unique filter empties gets ratio 1 and
  is never drawn (a mismatch would make `build_random` fail and, with every
  other branch failing too, restart the behavior tree forever).
  """
  def get_categories_proportion_built(body, bodies, biome_key, system_value, instance_id) do
    buildings =
      BuildingsHelper.get_biome_buildings(biome_key, instance_id)
      |> filter_buildings_by_system_value(system_value)
      |> filter_already_built_unique_buildings(body, bodies)

    length_production_buildings = buildings |> filter_building_by_profile(:production) |> length()
    length_credit_buildings = buildings |> filter_building_by_profile(:credit) |> length()
    length_techno_buildings = buildings |> filter_building_by_profile(:technologic) |> length()
    length_ideologic_buildings = buildings |> filter_building_by_profile(:ideologic) |> length()
    length_defense_buildings = buildings |> filter_building_by_profile(:defense) |> length()

    {n_productions, n_credits, n_technologics, n_ideologics, n_defenses} = count_buildings(body, buildings)

    ratio_productions = get_ratio(n_productions, length_production_buildings)
    ratio_credits = get_ratio(n_credits, length_credit_buildings)
    ratio_technologics = get_ratio(n_technologics, length_techno_buildings)
    ratio_ideologics = get_ratio(n_ideologics, length_ideologic_buildings)
    ratio_defenses = get_ratio(n_defenses, length_defense_buildings)

    [
      production: ratio_productions,
      credit: ratio_credits,
      technologic: ratio_technologics,
      ideologic: ratio_ideologics,
      defense: ratio_defenses
    ]
  end

  defp get_ratio(count, length) do
    cond do
      # no building in category built
      length == 0 -> 1
      # buildings in category built but some are duplicates
      length >= 1 -> 1 / 2
      # normal computation
      true -> count / length
    end
  end

  # Bodies
  ################

  def get_bodies(stellar_system) do
    Enum.flat_map(
      stellar_system.bodies,
      fn body ->
        get_nested_bodies(body) ++
          if not Enum.empty?(body.tiles),
            do: [body_view(body)],
            else: []
      end
    )
  end

  defp get_nested_bodies(body) do
    Enum.map(body.bodies, &body_view/1)
  end

  # What the tree needs of a body: its tiles, and what a building on it would
  # scale with (the three potentials and the local population).
  defp body_view(body) do
    %{
      uid: body.uid,
      type: body.type,
      tiles: body.tiles,
      industrial_factor: Map.get(body, :industrial_factor),
      technological_factor: Map.get(body, :technological_factor),
      activity_factor: Map.get(body, :activity_factor),
      population: Map.get(body, :population, 0)
    }
  end

  def get_body(system, stellar_body_id) do
    [body] =
      system
      |> get_bodies()
      |> Enum.filter(fn body -> body.uid == stellar_body_id end)

    body
  end

  def get_bodies_no_infra(system) do
    system
    |> get_bodies()
    |> Enum.filter(fn body -> body.type == :habitable_planet or body.type == :sterile_planet end)
    |> Enum.filter(fn body -> hd(body.tiles).building_status == :empty end)
  end

  def filter_free_bodies(bodies) do
    Enum.filter(bodies, fn body ->
      free_tile?(body)
    end)
  end

  def filter_bodies(bodies, body_type) do
    Enum.filter(bodies, fn body -> body.type == body_type end)
  end

  @doc """
  Filter the bodies that have all the happiness buildings already built.
  """
  def filter_full_happiness_bodies(bodies, instance_id) do
    Enum.filter(bodies, fn body ->
      building_keys =
        get_built_tiles(body)
        |> Enum.map(fn tile -> tile.building_key end)

      eligible_buildings = get_happiness_buildings(body, instance_id, building_keys)

      # true if not all buildings of eligible buildings are in buildings_keys
      not Enum.all?(eligible_buildings, fn prod_key -> Enum.member?(building_keys, prod_key) end)
    end)
  end

  @doc """
  Map a body type to its corresponding biome.
  """
  def body_type_to_biome_key(body_type) do
    case body_type do
      :habitable_planet -> :open
      :sterile_planet -> :dome
      :moon -> :orbital
      :asteroid -> :orbital
    end
  end

  @doc """
   Returns the uid of a habitable planet with a megapole

   Returns `nil` if not found
  """
  def get_main_body(system, max_tiles, biome \\ :open) do
    {body_type, main_infra} =
      if biome == :open,
        do: {:habitable_planet, :infra_open},
        else: {:sterile_planet, :infra_dome}

    bodies =
      get_bodies(system)
      |> filter_bodies(body_type)
      |> Enum.filter(fn body -> has_building?(body.tiles, main_infra) end)
      |> Enum.filter(fn body -> free_tile?(body) end)

    # in case of multiple bodies with a megapole, choose random
    case bodies do
      [] ->
        nil

      [body] ->
        # Return only if less than max_tiles tiles are taken
        free_tiles = get_free_tiles(body)

        if length(free_tiles) > max_tiles,
          do: body,
          else: nil

      [_ | _] ->
        nil
    end
  end

  # Tiles
  ################

  def free_tile?(body) do
    Enum.any?(body.tiles, fn tile -> tile.building_status == :empty end)
  end

  def get_free_tiles(body) do
    Enum.filter(body.tiles, fn tile -> tile.building_status == :empty end)
  end

  def get_built_tiles(body) do
    Enum.filter(body.tiles, fn tile -> tile.building_status == :built end)
  end

  def get_damaged_tiles(bodies) do
    Enum.flat_map(bodies, fn body ->
      body.tiles
      |> Enum.filter(&(&1.building_status == :damaged))
      |> Enum.map(fn tile -> Map.merge(tile, %{body_id: body.uid}) end)
    end)
  end

  @doc """
  Returns the tiles within a category that are upgradable.
  """
  def get_upgradable_tiles(bodies, instance_id, category_key) do
    # get built tiles of our bodies
    built_tiles_with_body_id =
      Enum.flat_map(bodies, fn body ->
        body.tiles
        |> Enum.filter(&(&1.building_status == :built))
        |> Enum.map(fn tile -> Map.merge(tile, %{body_id: body.uid}) end)
      end)

    # get all buildings of the category `category_key`
    eligible_buildings =
      BuildingsHelper.get_all_buildings(instance_id)
      |> Enum.reject(fn building -> building.key in BuildingsHelper.excluded_building_keys() end)
      |> filter_building_by_profile(category_key)
      |> Enum.map(& &1.key)

    # built tiles should be in `eligible_buildings` and should not have reached their max lvl
    Enum.filter(built_tiles_with_body_id, fn tile ->
      max_lvl = get_building_max_level(tile.building_key, instance_id)
      tile.building_level < max_lvl and Enum.member?(eligible_buildings, tile.building_key)
    end)
  end

  @doc """
  Every built tile the engine would currently accept a +1 upgrade on, tagged
  with its `body_id`. Mirrors the upgrade guards in
  `Instance.StellarSystem.StellarSystem.order_building_production/2`:

    * the tile holds a finished building (`:built`) with no construction in flight;
    * the building is below its max level and is not a player-only wonder;
    * outside the orbital biome, a tile other than the tile-1 infrastructure may
      only rise to a level its body's infrastructure has already reached.
  """
  def get_legal_upgrades(system) do
    instance_id = system.instance_id
    excluded = BuildingsHelper.excluded_building_keys()

    system
    |> get_bodies()
    |> Enum.flat_map(fn body ->
      orbital? = body_type_to_biome_key(body.type) == :orbital
      infra = Enum.find(body.tiles, &(&1.id == 1))
      infra_level = if infra && infra.building_status == :built, do: infra.building_level, else: 0

      body.tiles
      |> Enum.filter(fn tile ->
        tile.building_status == :built and
          tile.construction_status == :none and
          tile.building_key not in excluded and
          is_integer(tile.building_level) and
          tile.building_level < get_building_max_level(tile.building_key, instance_id) and
          (orbital? or tile.id == 1 or infra_level >= tile.building_level + 1)
      end)
      |> Enum.map(&Map.put(&1, :body_id, body.uid))
    end)
  end

  # Building
  ################

  def enough_workforce?(state, {_body_id, _tile, prod_key, _level}) do
    building = Enum.find(BuildingsHelper.get_all_buildings(state.instance_id), &(&1.key == prod_key))
    state.workforce - state.used_workforce >= building.workforce
  end

  def build(state, production_data) do
    with true <- enough_workforce?(state, production_data),
         {:ok, updated_state} <- Instance.StellarSystem.StellarSystem.order_building_production(state, production_data) do
      {:done, updated_state}
    else
      false ->
        {:done, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns a random workforce building depending of the biome.
  """
  def get_workforce_building_key(instance_id, biome) do
    buildings =
      BuildingsHelper.get_biome_buildings(biome, instance_id)
      |> Enum.filter(fn %{type: type, outputs: outputs} -> type === :normal and :hab in outputs end)
      |> Enum.map(fn b -> b.key end)

    Game.call(instance_id, :rand, :master, {:random, buildings})
  end

  @doc """
  Returns buildings that produce happiness.
  """
  def get_happiness_buildings(body, instance_id, already_built_keys) do
    body_type_to_biome_key(body.type)
    |> BuildingsHelper.get_biome_buildings(instance_id)
    # infrastructures also output :happiness but only fit the infra tile
    |> Enum.filter(fn %{outputs: outputs, type: type} -> :happiness in outputs and type == :normal end)
    |> Enum.filter(fn %{key: key} -> not Enum.member?(already_built_keys, key) end)
  end

  @doc """
  Every happiness building the engine would accept right now, as production
  data `{body_uid, tile_id, key, 1}`: a body with a free tile, a happiness
  building it does not have yet (and no unique rule forbids), and enough free
  workforce to staff it.
  """
  def happiness_builds(system) do
    bodies = get_bodies(system)
    free_workforce = system.workforce - system.used_workforce

    bodies
    |> filter_free_bodies()
    |> Enum.flat_map(fn body ->
      built_keys = body |> get_built_tiles() |> Enum.map(& &1.building_key)

      case buildable_tiles(body) do
        [] ->
          []

        [tile | _] ->
          body
          |> get_happiness_buildings(system.instance_id, built_keys)
          |> filter_already_built_unique_buildings(body, bodies)
          |> Enum.filter(&(&1.workforce <= free_workforce))
          |> Enum.map(&{body.uid, tile.id, &1.key, 1})
      end
    end)
  end

  # Empty tiles a normal building can go on. A planet takes nothing until its
  # tile-1 infrastructure exists, and its infrastructure tile takes nothing else.
  defp buildable_tiles(%{type: type, tiles: tiles}) when type in [:habitable_planet, :sterile_planet] do
    if Enum.any?(tiles, &(&1.id == 1 and &1.building_status != :empty)),
      do: Enum.filter(tiles, &(&1.building_status == :empty and &1.type != :infrastructure)),
      else: []
  end

  defp buildable_tiles(body), do: get_free_tiles(body)

  @doc "The legal upgrades (`get_legal_upgrades/1`) of buildings that output happiness."
  def happiness_upgrades(system) do
    happy =
      system.instance_id
      |> BuildingsHelper.get_all_buildings()
      |> Enum.filter(&(is_list(&1.outputs) and :happiness in &1.outputs))
      |> MapSet.new(& &1.key)

    system |> get_legal_upgrades() |> Enum.filter(&MapSet.member?(happy, &1.building_key))
  end

  def has_building?(tiles, building_atom) do
    Enum.any?(tiles, fn tile -> tile.building_key == building_atom end)
  end

  def has_n_building?(tiles, building_atom, n) do
    Enum.count(tiles, fn tile -> tile.building_key == building_atom end) >= n
  end

  @doc """
  Filters the buildings with the `system_value` value of the system.
  """
  def filter_buildings_by_system_value(buildings, system_value, tiers \\ :stage)

  def filter_buildings_by_system_value(buildings, system_value, :stage) do
    range = get_workforce_range(system_value)

    buildings
    |> Enum.filter(fn building ->
      Enum.member?(range, building.workforce)
    end)
  end

  # Every stage up to the current one: a developed system keeps the cheap
  # buildings of its youth on offer.
  def filter_buildings_by_system_value(buildings, system_value, :up_to) do
    _first..last//_ = get_workforce_range(system_value)
    Enum.filter(buildings, &(&1.workforce <= last))
  end

  @doc """
  Returns tuple with the count of buildings for the 5 categories: neutral, technologic and ideologic.
  """
  def count_buildings(body, buildings) do
    Enum.reduce(body.tiles, {0, 0, 0, 0, 0}, fn tile, acc ->
      with true <- tile.building_key != nil,
           building_struct <- Enum.find(buildings, &(&1.key == tile.building_key)),
           true <- building_struct != nil do
        building_outputs = building_struct.outputs

        Enum.reduce(building_outputs, acc, fn building_output, {acc_prod, acc_cred, acc_techno, acc_ideo, acc_def} ->
          case building_output do
            :prod -> {acc_prod + 1, acc_cred, acc_techno, acc_ideo, acc_def}
            :hab -> {acc_prod + 1, acc_cred, acc_techno, acc_ideo, acc_def}
            :credit -> {acc_prod, acc_cred + 1, acc_techno, acc_ideo, acc_def}
            :tech -> {acc_prod, acc_cred, acc_techno + 1, acc_ideo, acc_def}
            :ideo -> {acc_prod, acc_cred, acc_techno, acc_ideo + 1, acc_def}
            :defense -> {acc_prod, acc_cred, acc_techno, acc_ideo, acc_def + 1}
            :happiness -> {acc_prod, acc_cred, acc_techno, acc_ideo, acc_def}
          end
        end)
      else
        _ -> acc
      end
    end)
  end

  def get_building_max_level(building_key, instance_id) do
    building_data = Data.Querier.one(Data.Game.Building, instance_id, building_key)
    buildings_levels = Enum.map(building_data.levels, fn level_data -> level_data.level end)
    Enum.max(buildings_levels)
  end

  @doc """
  Filters out unique buildings that are already present: `:unique_body` when
  present on the target `body`, `:unique_system` when present on any body in
  `bodies`. Mirrors the limitation guard in
  `Instance.StellarSystem.StellarSystem.order_building_production/2` — a tile
  with the building planned or damaged still carries its `building_key`, so it
  counts as present.
  """
  def filter_already_built_unique_buildings(buildings, body, bodies) do
    on_body = tile_building_keys([body])
    in_system = tile_building_keys(bodies)

    Enum.reject(buildings, fn %{key: key, limitation: limitation} ->
      (limitation == :unique_body and key in on_body) or
        (limitation == :unique_system and key in in_system)
    end)
  end

  defp tile_building_keys(bodies) do
    bodies
    |> Enum.flat_map(fn body -> body.tiles end)
    |> Enum.map(fn tile -> tile.building_key end)
    |> Enum.reject(&is_nil/1)
  end
end
