defmodule RC.SystemPlanner do
  @moduledoc """
  The system planner page (`front/src/portal/pages/SystemPlanner.vue`): a
  freeform what-if for one star system. The player sets buildings and their
  levels, the population, a governor's skills and the active lexes, and this
  module runs the game's own bonus pipeline on the result —
  `StellarSystem.update_bonuses/3`, the call a live system makes whenever its
  bonuses change — so every number and every breakdown matches what the game
  would show for the same system.

  Nothing here is constrained the way an order is: no costs, no build times,
  no patents, no one-level-at-a-time upgrades, no infrastructure ceiling. Only
  what keeps the system physically possible is checked: a building has to fit
  its body's biome and tile type, its level has to exist, and unique buildings
  stay unique.

  Game data comes from the `{:planner, speed}` virtual instance
  (`Data.Data.get/2`), so no game process is involved.

  Left out on purpose, because they are temporary or belong to the faction
  rather than the system: sieges, stability penalties from events, faction
  government effects and station buildings.
  """

  alias Instance.StellarSystem.{ProductionQueue, StarterStellarSystemData, StellarBody, StellarSystem, Tile}

  # "daily" is Legacy content at a fast clock (Data.Game.Speed.Content), so
  # a system exported from a daily plans with Legacy data.
  @speeds %{"fast" => :fast, "medium" => :medium, "slow" => :slow, "daily" => :slow}

  @max_population 400
  @max_primary_bodies 16
  @max_sub_bodies 8
  @max_tiles 12
  @max_factor 5
  @skill_count 6
  @max_skill 12
  @max_lexes 64
  @max_name 60

  def instance_id(speed), do: {:planner, speed}

  @doc """
  Validate `params` (the JSON body of `POST /api/system-planner/compute`) and
  compute the system. Returns `{:ok, %{system: %StellarSystem{}, growth: float}}`
  — `growth` is the population change per tick, also stored as
  `system.population.change` — or `{:error, reason_atom}`.
  """
  def compute(params) when is_map(params) do
    with {:ok, spec} <- parse(params) do
      {:ok, run(spec)}
    end
  end

  def compute(_), do: {:error, :invalid_plan}

  @doc "Content speed for a speed key string (\"daily\" plans as Legacy)."
  def parse_speed(speed) do
    case Map.fetch(@speeds, speed) do
      {:ok, speed} -> {:ok, speed}
      :error -> {:error, :invalid_speed}
    end
  end

  @doc """
  The standard starting system at `speed` (the fixed layout every new player
  gets, with its infrastructure and starting population), in the planner's
  plan format. The page opens on it when there is nothing to import.
  """
  def template(speed) do
    iid = instance_id(speed)
    c = Data.Querier.one(Data.Game.Constant, iid, :main)

    bodies = Enum.map(StarterStellarSystemData.content(), &template_body/1)

    %{
      speed: speed,
      capital: true,
      population: c.system_starting_population,
      bodies: open_template(bodies)
    }
  end

  # -- parsing ----------------------------------------------------------------

  @doc false
  def parse(params) do
    with {:ok, speed} <- parse_speed(params["speed"]),
         iid = instance_id(speed),
         {:ok, faction} <- parse_faction(params["faction"], iid),
         {:ok, population} <- parse_population(params["population"]),
         {:ok, bodies} <- parse_bodies(params["bodies"], iid),
         :ok <- check_limitations(bodies, iid),
         {:ok, governor} <- parse_governor(params["governor"], iid),
         {:ok, lexes} <- parse_lexes(params["lexes"], iid) do
      {:ok,
       %{
         instance_id: iid,
         faction: faction,
         capital?: params["capital"] == true,
         population: population,
         bodies: bodies,
         governor: governor,
         lexes: lexes
       }}
    end
  end

  defp parse_faction(key, iid) do
    case find_data(Data.Game.Faction, iid, key) do
      nil -> {:error, :invalid_faction}
      faction -> {:ok, faction.key}
    end
  end

  defp parse_population(value) when is_number(value) and value >= 0 and value <= @max_population,
    do: {:ok, value / 1}

  defp parse_population(_), do: {:error, :invalid_population}

  defp parse_bodies(bodies, iid) when is_list(bodies) and length(bodies) in 1..@max_primary_bodies do
    bodies
    |> Enum.with_index(1)
    |> collect(fn {body, id} -> parse_body(body, id, nil, iid) end)
  end

  defp parse_bodies(_, _), do: {:error, :invalid_bodies}

  defp parse_body(body, id, parent_id, iid) when is_map(body) do
    kind = if parent_id == nil, do: :primary, else: :secondary

    with %Data.Game.StellarBody{type: ^kind} = body_data <- find_data(Data.Game.StellarBody, iid, body["type"]),
         {:ok, factors} <- parse_factors(body),
         {:ok, tiles} <- parse_tiles(body["tiles"], kind, body_data, iid),
         {:ok, bodies} <- parse_sub_bodies(body["bodies"], kind, id, iid) do
      uid = if parent_id == nil, do: "#{id}", else: "#{parent_id}-#{id}"

      {:ok,
       struct(StellarBody, %{
         id: id,
         uid: uid,
         type: body_data.key,
         name: parse_name(body["name"], uid),
         industrial_factor: factors.industrial_factor,
         technological_factor: factors.technological_factor,
         activity_factor: factors.activity_factor,
         population: 0,
         bodies: bodies,
         tiles: tiles
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_body}
    end
  end

  defp parse_body(_, _, _, _), do: {:error, :invalid_body}

  defp parse_factors(body) do
    keys = [:industrial_factor, :technological_factor, :activity_factor]

    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case body[Atom.to_string(key)] do
        value when is_integer(value) and value >= 0 and value <= @max_factor ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        _ ->
          {:halt, {:error, :invalid_body_factor}}
      end
    end)
  end

  defp parse_sub_bodies(nil, _kind, _parent_id, _iid), do: {:ok, []}
  defp parse_sub_bodies([], _kind, _parent_id, _iid), do: {:ok, []}

  defp parse_sub_bodies(bodies, :primary, parent_id, iid)
       when is_list(bodies) and length(bodies) <= @max_sub_bodies do
    bodies
    |> Enum.with_index(1)
    |> collect(fn {body, id} -> parse_body(body, id, parent_id, iid) end)
  end

  defp parse_sub_bodies(_, _, _, _), do: {:error, :invalid_body}

  defp parse_tiles(nil, _kind, _body_data, _iid), do: {:ok, []}

  defp parse_tiles(tiles, kind, body_data, iid) when is_list(tiles) and length(tiles) <= @max_tiles do
    tiles
    |> Enum.with_index(1)
    |> collect(fn {tile, id} -> parse_tile(tile, Tile.new(id, kind), body_data, iid) end)
  end

  defp parse_tiles(_, _, _, _), do: {:error, :invalid_tiles}

  defp parse_tile(tile, empty, body_data, iid) when is_map(tile) do
    case tile["building_key"] do
      nil ->
        {:ok, empty}

      key ->
        with {:building, %Data.Game.Building{} = building} <- {:building, find_data(Data.Game.Building, iid, key)},
             {:biome, true} <- {:biome, building.biome == body_data.biome},
             {:tile_type, true} <- {:tile_type, building.type == empty.type},
             {:level, level} when is_integer(level) and level >= 1 and level <= length(building.levels) <-
               {:level, tile["building_level"]} do
          built = Tile.force_building(empty, building.key, level)

          if tile["building_status"] == "damaged",
            do: {:ok, %{built | building_status: :damaged}},
            else: {:ok, built}
        else
          {:building, _} -> {:error, :unknown_building}
          {:biome, _} -> {:error, :building_biome_mismatch}
          {:tile_type, _} -> {:error, :building_tile_mismatch}
          {:level, _} -> {:error, :invalid_building_level}
        end
    end
  end

  defp parse_tile(nil, empty, _body_data, _iid), do: {:ok, empty}
  defp parse_tile(_, _, _, _), do: {:error, :invalid_tiles}

  defp parse_name(name, _uid) when is_binary(name) and name != "", do: String.slice(name, 0, @max_name)
  defp parse_name(_, uid), do: uid

  # Unique buildings stay unique: one per system (:unique_system) or one per
  # body (:unique_body), exactly as the build menu enforces them.
  defp check_limitations(bodies, iid) do
    buildings_data = Data.Querier.all(Data.Game.Building, iid)
    limitation = fn key -> Enum.find_value(buildings_data, &(&1.key == key && &1.limitation)) end

    per_body = Enum.map(flatten_bodies(bodies), fn body -> body_building_keys(body) end)

    over_body? =
      Enum.any?(per_body, fn keys ->
        keys
        |> Enum.frequencies()
        |> Enum.any?(fn {key, count} -> count > 1 and limitation.(key) == :unique_body end)
      end)

    over_system? =
      per_body
      |> List.flatten()
      |> Enum.frequencies()
      |> Enum.any?(fn {key, count} -> count > 1 and limitation.(key) == :unique_system end)

    cond do
      over_body? -> {:error, :unique_building_per_body}
      over_system? -> {:error, :unique_building_per_system}
      true -> :ok
    end
  end

  defp body_building_keys(body) do
    body.tiles
    |> Enum.filter(&(&1.building_key != nil))
    |> Enum.map(& &1.building_key)
  end

  defp parse_governor(nil, _iid), do: {:ok, nil}

  defp parse_governor(%{"type" => type, "skills" => skills} = governor, iid) when is_list(skills) do
    valid_skills? =
      length(skills) == @skill_count and
        Enum.all?(skills, &(is_integer(&1) and &1 >= 0 and &1 <= @max_skill))

    case {find_data(Data.Game.Character, iid, type), valid_skills?} do
      {%Data.Game.Character{} = character, true} ->
        {:ok, %{type: character.key, skills: skills, name: parse_name(governor["name"], "governor")}}

      _ ->
        {:error, :invalid_governor}
    end
  end

  defp parse_governor(_, _), do: {:error, :invalid_governor}

  defp parse_lexes(nil, _iid), do: {:ok, []}

  defp parse_lexes(keys, iid) when is_list(keys) and length(keys) <= @max_lexes do
    keys
    |> Enum.uniq()
    |> collect(fn key ->
      case find_data(Data.Game.Doctrine, iid, key) do
        nil -> {:error, :unknown_lex}
        doctrine -> {:ok, doctrine.key}
      end
    end)
  end

  defp parse_lexes(_, _), do: {:error, :invalid_lexes}

  # -- computing --------------------------------------------------------------

  defp run(spec) do
    iid = spec.instance_id
    c = Data.Querier.one(Data.Game.Constant, iid, :main)

    # The same extraction a live player pushes to every system it owns:
    # active lexes and the faction's traditions. The planner has no
    # stellar_systems/dominions/characters, which only feed the player's
    # own income, and no government (a beta, faction-wide).
    player =
      struct(Instance.Player.Player, %{
        instance_id: iid,
        faction: spec.faction,
        policies: spec.lexes,
        stellar_systems: [],
        dominions: [],
        characters: [],
        government_effects: nil
      })

    player_bonuses = Instance.Player.Player.extract_bonus(player, [:stellar_system])

    system =
      struct(StellarSystem, %{
        id: 0,
        name: "planner",
        status: :inhabited_player,
        capital?: spec.capital?,
        instance_id: iid,
        bodies: spec.bodies,
        queue: ProductionQueue.new(),
        siege: nil,
        owner: nil,
        governor: nil,
        characters: [],
        station: nil,
        population: Core.DynamicValue.new(spec.population),
        workforce: floor(spec.population),
        # compute_bonus re-derives the population status only when stability
        # moved since the last computation; a value no result can equal
        # makes it always derive it.
        happiness: %Core.Value{value: :not_computed, details: %{}},
        remove_contact: Core.DynamicValue.new(0.0),
        happiness_penalties: [],
        bonuses: %{character: governor_bonuses(spec.governor, iid)}
      })

    {_, _, system} = StellarSystem.update_bonuses(system, :player, player_bonuses)

    growth =
      StellarSystem.population_growth(
        system.habitation.value,
        spec.population,
        system.happiness.value,
        c.system_base_growth
      )

    %{system: %{system | population: %{system.population | change: growth}}, growth: growth}
  end

  # What StellarSystem.push_character(_, character, :governor) extracts.
  defp governor_bonuses(nil, _iid), do: []

  defp governor_bonuses(governor, iid) do
    character =
      struct(Instance.Character.Character, %{
        instance_id: iid,
        type: governor.type,
        name: governor.name,
        skills: governor.skills,
        bonuses: %{}
      })

    Instance.Character.Character.extract_bonus(character, [:stellar_system])
  end

  # -- template ---------------------------------------------------------------

  defp template_body(body) do
    %{
      type: body["key"],
      industrial_factor: body["ind_factor"],
      technological_factor: body["tec_factor"],
      activity_factor: body["act_factor"],
      tiles: List.duplicate(%{building_key: nil}, body["tiles"]),
      bodies: Enum.map(body["subbodies"], &template_body/1)
    }
  end

  # Mirrors StellarSystem's open_system/1: the infrastructure goes on the
  # largest habitable planet, else on the largest sterile one.
  defp open_template(bodies) do
    {type, infra} =
      if Enum.any?(bodies, &(&1.type == "habitable_planet")),
        do: {"habitable_planet", "infra_open"},
        else: {"sterile_planet", "infra_dome"}

    target =
      bodies
      |> Enum.with_index()
      |> Enum.filter(fn {body, _} -> body.type == type end)
      |> Enum.max_by(fn {body, _} -> length(body.tiles) end, fn -> nil end)

    case target do
      nil ->
        bodies

      {body, index} ->
        [_ | rest] = body.tiles
        tiles = [%{building_key: infra, building_level: 1, building_status: "built"} | rest]
        List.replace_at(bodies, index, %{body | tiles: tiles})
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Data entry whose key's string form is `value` (keys arrive as JSON
  # strings and must never be turned into new atoms).
  defp find_data(module, iid, value) when is_binary(value) do
    Enum.find(Data.Querier.all(module, iid), &(Atom.to_string(&1.key) == value))
  end

  defp find_data(_, _, _), do: nil

  # Map `fun` over `list`, stopping at the first {:error, _}.
  defp collect(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp flatten_bodies(bodies), do: Enum.flat_map(bodies, fn body -> [body | flatten_bodies(body.bodies)] end)
end
