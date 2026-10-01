defmodule Wave.Fixture do
  @moduledoc """
  Hand-placed opposition for a live Wave Defense test game.

  The Rebellion's Erased only act on what they can see of the human side, so
  proving their targeting needs a human side that exists: players holding
  systems, agents standing in specific places, fleets of a chosen size,
  sieges pressing a chosen system. Waiting for real players to produce that
  arrangement is not a test; this module builds it on demand.

  Everything is engine-real. Agents are minted with `Instance.Character.Character.new/6`
  and handed over through the same `{:convert_character, ...}` player call the
  seduction action uses, so they live in a real roster with a real agent
  process and are valid targets for removal, sabotage and seduction. Ships go
  in through the `order_ship` + `put_ship` pair the fight simulator and the
  Warlord's own colony grant use. Orders are pushed as an ordinary itinerary
  through the player agent, so the engine validates them exactly as it would a
  human's.

  Dev-only, reached through `Portal.WaveController`.
  """

  require Logger

  alias Instance.Character.Character, as: GameCharacter
  alias Wave.Nav

  @doc """
  Mint an agent and stand it in a system.

  Options:

    * `:type` — `:admiral` / `:spy` / `:speaker` (default `:admiral`)
    * `:rank` — market rank to mint at (default `:common`)
    * `:system_id` — where to stand it (default: the player's capital)
    * `:level` — force the level, and with it the protection the Erased weigh
    * `:skills` — a six-slot skill list, for an agent of a precise shape
    * `:specialization` / `:second_specialization` — spy specs are
      `:informer`, `:assassin`, `:saboteur`, `:counter_spy`, `:cleaner`, `:mafioso`
    * `:name` — override the rolled name (pass `"CMO #0000-0000"` to test the
      replacement-officer rule)

  Returns `{:ok, %{id:, name:, type:, system_id:, level:}}`.
  """
  def place_agent(instance_id, player_id, opts \\ %{}) do
    type = atom(opts["type"] || opts[:type] || "admiral", :admiral)
    rank = atom(opts["rank"] || opts[:rank] || "common", :common)

    with {:ok, player} <- player(instance_id, player_id),
         {:ok, system_id} <- system_id(player, opts),
         {:ok, tmp_id} <- step(Game.call(instance_id, :character_market, :master, :get_next_character_id)) do
      character =
        tmp_id
        |> GameCharacter.new(type, rank, 1, instance_id, initial_data(instance_id, type, opts))
        |> shape(instance_id, type, opts)

      before = roster_ids(player)

      case Game.call(instance_id, :player, player_id, {:convert_character, character, system_id}, 1, 30_000) do
        :ok ->
          # `convert_character` mints its own id for the handover, so the one we
          # built with is not the one that ends up in the roster. Diff the
          # roster rather than guessing at the sequence.
          with {:ok, player} <- player(instance_id, player_id),
               [id] <- MapSet.difference(roster_ids(player), before) |> MapSet.to_list() do
            {:ok,
             %{
               id: id,
               name: character.name,
               type: type,
               level: character.level,
               skills: character.skills,
               specialization: character.specialization,
               system_id: system_id
             }}
          else
            _ -> {:error, :character_not_in_roster}
          end

        other ->
          {:error, {:convert_character, other}}
      end
    end
  end

  defp roster_ids(player), do: MapSet.new(player.characters, & &1.id)

  @doc """
  Materialize ships into a Navarch's fleet — the instant build the Warlord
  uses for its own colony ships: plan the ship on a tile, then complete it.
  No queue, no credit, no patent, no shipyard.

  `ships` is `%{"key" => "fighter_1", "count" => 4, "tile" => 1}`, or a list of
  `%{"key" => …, "tile" => …}` for a mixed fleet. `put_ship` is a cast, so the
  Navarch reads `:docking` for a moment afterwards.
  """
  def grant_ships(instance_id, character_id, ships) do
    placed =
      ships
      |> expand_ships()
      |> Enum.map(fn {tile, key} ->
        case Game.call(instance_id, :character, character_id, {:order_ship, {nil, tile, key, nil}}, 1, 30_000) do
          {:ok, _character} ->
            Game.cast(instance_id, :character, character_id, {:put_ship, tile, 0})
            {tile, key, :ok}

          other ->
            {tile, key, inspect(other)}
        end
      end)

    {:ok, Enum.map(placed, fn {tile, key, result} -> %{tile: tile, ship: key, result: result} end)}
  end

  @doc """
  Push an itinerary: the lane hops to `target_id`, then `action` there. The
  same shape the Warlord orders with, so a hand-placed Navarch can be told to
  `conquest` a rebel system and produce a real siege for the Erased to find.
  """
  def order(instance_id, player_id, character_id, action, target_id, extra \\ %{}) do
    with {:ok, galaxy} <- step(Game.call(instance_id, :galaxy, :master, :get_state)),
         character when is_map(character) <-
           Game.call(instance_id, :player, player_id, {:get_character_state, character_id}),
         hops when is_list(hops) <- Nav.path_hops(Nav.adjacency(galaxy), character.system, target_id),
         :ok <-
           Game.call(
             instance_id,
             :player,
             player_id,
             {:add_character_actions, character_id, Wave.Warlord.itinerary(hops, action, target_id, extra)}
           ) do
      {:ok, %{character_id: character_id, action: action, target: target_id, hops: length(hops)}}
    else
      nil -> {:error, :no_route}
      other -> {:error, other}
    end
  end

  @doc """
  Give a player research the way a human gets it: the named patents and lexes
  with their ancestors, bought through the player agent, and lex slots up to
  `slots`. The technology and ideology are granted first. Lets a test check
  what the Rebellion copies from the humans (ship patents, lex slots).
  """
  def research(instance_id, player_id, opts \\ %{}) do
    call = &Game.call(instance_id, :player, player_id, &1)
    patents = Data.Querier.all(Data.Game.Patent, instance_id)
    lexes = Data.Querier.all(Data.Game.Doctrine, instance_id)

    with {:ok, player} <- player(instance_id, player_id),
         :ok <- call.({:add_resources, 0, 5_000_000, 5_000_000}) do
      wanted_patents = Wave.Research.purchase_plan(patents, named(patents, opts["patents"]), player.patents)
      wanted_lexes = Wave.Research.purchase_plan(lexes, named(lexes, opts["lexes"]), player.doctrines)
      slots = max(trunc(opts["slots"] || 0) - player.max_policies, 0)

      results =
        Enum.map(wanted_patents, &{&1, call.({:purchase_patent, &1})}) ++
          Enum.map(wanted_lexes, &{&1, call.({:purchase_doctrine, &1})}) ++
          if(slots > 0, do: Enum.map(1..slots, fn _ -> {:lex_slot, call.(:purchase_policy_slot)} end), else: [])

      with {:ok, player} <- player(instance_id, player_id) do
        {:ok,
         %{
           patents: player.patents,
           lexes: player.doctrines,
           enacted: player.policies,
           lex_slots: player.max_policies,
           refused: for({key, result} <- results, result != :ok, do: %{key: key, result: inspect(result)})
         }}
      end
    end
  end

  # Catalog keys for the names a request carries; unknown names are dropped.
  defp named(nodes, names) when is_list(names) do
    by_name = Map.new(nodes, &{Atom.to_string(&1.key), &1.key})
    names |> Enum.map(&Map.get(by_name, to_string(&1))) |> Enum.reject(&is_nil/1)
  end

  defp named(_nodes, _names), do: []

  # --- internals ----------------------------------------------------------------

  # A market character is rolled, not designed. For a fixture we want a known
  # shape. Skills and specializations go in through `initial_data` so
  # `Character.new/6` builds the coefficients from them; name and level are
  # overwritten afterwards, and `Character.activate/3` recomputes the bonuses
  # on the way into the roster either way.
  defp shape(character, instance_id, type, opts) do
    character
    |> put(:name, opts["name"] || opts[:name])
    |> level(instance_id, type, opts["level"] || opts[:level])
  end

  defp put(character, _key, nil), do: character
  defp put(character, key, value), do: Map.put(character, key, value)

  # Protection and determination are earned per level
  # (`Instance.Character.Character.level_up/1`), so forcing a level means
  # forcing the stats that come with it — otherwise a "level 8" fixture would
  # defend like a level 0 one.
  defp level(character, _instance_id, _type, nil), do: character

  defp level(character, instance_id, type, level) when is_number(level) do
    level = level |> trunc() |> max(0) |> min(12)
    type_data = Data.Querier.one(Data.Game.Character, instance_id, type)

    %{
      character
      | level: level,
        protection: min(type_data.initial_protection + level * type_data.gain_protection, type_data.max_protection),
        determination:
          min(type_data.initial_determination + level * type_data.gain_determination, type_data.max_determination)
    }
  end

  defp level(character, _instance_id, _type, _level), do: character

  # `initial_data` is the only way to pin what a character is made of; without
  # it `Character.new/6` rolls the specializations and leaves the skills empty.
  # Asking for either one takes this path, and the unasked-for half falls back
  # to the first specialization of the type.
  defp initial_data(instance_id, type, opts) do
    spec = atom(opts["specialization"] || opts[:specialization], nil)
    skills = skills(opts)

    if spec || skills do
      spec = spec || default_spec(instance_id, type)

      %{
        spec1: spec,
        spec2: atom(opts["second_specialization"] || opts[:second_specialization], spec),
        skills: skills || [0, 0, 0, 0, 0, 0]
      }
    end
  end

  defp default_spec(instance_id, type) do
    Data.Querier.one(Data.Game.Character, instance_id, type).specializations |> hd() |> Map.fetch!(:key)
  end

  defp skills(opts) do
    case opts["skills"] || opts[:skills] do
      list when is_list(list) and length(list) == 6 -> Enum.map(list, &trunc(&1 || 0))
      _ -> nil
    end
  end

  defp expand_ships(%{} = ships) do
    key = atom(ships["key"] || ships[:key] || "fighter_1", :fighter_1)
    count = trunc(ships["count"] || ships[:count] || 1)
    first = trunc(ships["tile"] || ships[:tile] || 1)

    for offset <- 0..(max(count, 1) - 1), do: {first + offset, key}
  end

  defp expand_ships(ships) when is_list(ships) do
    ships
    |> Enum.with_index(1)
    |> Enum.map(fn {ship, index} ->
      {trunc(ship["tile"] || ship[:tile] || index), atom(ship["key"] || ship[:key] || "fighter_1", :fighter_1)}
    end)
  end

  defp expand_ships(_ships), do: []

  defp player(instance_id, player_id) do
    case Game.call(instance_id, :player, player_id, :get_state) do
      {:ok, player} -> {:ok, player}
      other -> {:error, {:player, other}}
    end
  end

  # Default placement is the player's own capital — the one system a fresh
  # human always has.
  defp system_id(player, opts) do
    case opts["system_id"] || opts[:system_id] do
      id when is_integer(id) ->
        {:ok, id}

      _ ->
        systems = player.stellar_systems ++ player.dominions

        case Enum.find(systems, &Map.get(&1, :capital?, false)) || List.first(systems) do
          nil -> {:error, :player_has_no_system}
          system -> {:ok, system.id}
        end
    end
  end

  defp step({:ok, value}), do: {:ok, value}
  defp step(other), do: {:error, other}

  defp atom(value, _fallback) when is_atom(value) and not is_nil(value), do: value

  defp atom(value, fallback) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> fallback
  end

  defp atom(_value, fallback), do: fallback
end
