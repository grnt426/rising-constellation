defmodule Mix.Tasks.Headless.Inspect do
  @shortdoc "Boot a small headless instance and dump bot-relevant state shapes"

  @moduledoc """
  Developer tool: boots a 50-system headless instance, prints the exact
  runtime shapes a bot policy codes against (home-system bodies/tiles,
  player fields, admiral/army, market slot), then tears down. No game runs.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    faction = List.first(args) || "tetrarchy"

    game_data =
      Headless.Scenario.small()
      |> Map.put("victory_points", 999)
      |> Map.put("headless", true)

    [profile | _] = Headless.Runner.ensure_bot_profiles(2)
    instance_id = :os.system_time(:millisecond) * 1_000 + rem(System.unique_integer([:positive]), 1_000)

    model = %{
      id: instance_id,
      factions: [
        %{id: 1, capacity: 1, faction_ref: faction, registrations: [%{id: 1, profile: profile}]}
      ],
      game_data: game_data
    }

    {:ok, :instantiated} = Instance.Manager.create_from_model(model, nil)

    {:ok, player} = Game.call(instance_id, :player, profile.id, :get_state)

    IO.puts("\n=== PLAYER (top-level fields) ===")

    player
    |> Map.from_struct()
    |> Map.take([:patents, :doctrines, :policies, :max_systems, :max_policies, :max_admirals])
    |> IO.inspect(limit: 30)

    IO.puts("\n=== player.credit/technology/ideology ===")
    IO.inspect(%{credit: player.credit.value, tech: player.technology.value, ideo: player.ideology.value})

    IO.puts("\n=== player.characters ===")
    IO.inspect(player.characters, limit: 8, printable_limit: 2000)

    IO.puts("\n=== player.character_deck (first entry) ===")
    IO.inspect(List.first(player.character_deck), limit: 12)

    IO.puts("\n=== HOME SYSTEM ===")
    [%{id: home_id} | _] = player.stellar_systems
    {:ok, system} = Game.call(instance_id, :stellar_system, home_id, :get_state)

    IO.puts("system top-level keys:")
    system |> Map.from_struct() |> Map.keys() |> IO.inspect(limit: 60)

    IO.puts("\nqueue field:")
    system |> Map.from_struct() |> Map.take([:queue, :production_queue]) |> IO.inspect(limit: 10)

    IO.puts("\nbodies (id/type/tiles):")

    Enum.each(system.bodies, fn body ->
      tiles = Enum.map(body.tiles, fn t -> Map.from_struct(t) |> Map.take([:id, :type, :building_key, :building_status, :construction_status]) end)
      IO.inspect(%{id: body.id, type: body.type, subtype: Map.get(body, :subtype), tiles: tiles}, limit: 40)
    end)

    IO.puts("\n=== GALAXY (one uninhabited system summary) ===")
    {:ok, galaxy} = Game.call(instance_id, :galaxy, :master, :get_state)
    IO.puts("galaxy top-level keys:")
    galaxy |> Map.from_struct() |> Map.keys() |> IO.inspect(limit: 40)

    sys_sample = galaxy.stellar_systems |> Enum.find(fn s -> s.status == :uninhabited end)
    IO.inspect(sys_sample, limit: 30)

    IO.puts("\n=== MARKET (first non-nil character) ===")
    {:ok, market} = Game.call(instance_id, :character_market, :master, :get_state)

    market.slots
    |> Enum.flat_map(& &1.data)
    |> Enum.flat_map(& &1.data)
    |> Enum.map(& &1.character)
    |> Enum.reject(&is_nil/1)
    |> List.first()
    |> IO.inspect(limit: 15, printable_limit: 1000)

    IO.puts("\n=== VIEW BUILD TIMING (per call) ===")

    for {label, fun} <- [
          {:player, fn -> Game.call(instance_id, :player, profile.id, :get_state) end},
          {:home_system, fn -> Game.call(instance_id, :stellar_system, home_id, :get_state) end},
          {:market, fn -> Game.call(instance_id, :character_market, :master, :get_state) end},
          {:galaxy, fn -> Game.call(instance_id, :galaxy, :master, :get_state) end},
          {:time, fn -> Game.call(instance_id, :time, :master, :get_state) end}
        ] do
      t0 = System.monotonic_time(:microsecond)
      result = fun.()
      us = System.monotonic_time(:microsecond) - t0
      tag = match?({:ok, _}, result) || match?(%{}, result)
      IO.puts("#{label}: #{div(us, 1000)}ms ok=#{inspect(tag)}")
    end

    IO.puts("\n=== ORDER_BUILDING ATTEMPT (hab_open_poor on first free normal open tile) ===")

    target =
      Enum.find_value(system.bodies, fn body ->
        if body.type == :habitable_planet do
          case Enum.find(body.tiles, &(&1.type == :normal and &1.building_status == :empty)) do
            nil -> nil
            tile -> {body.id, tile.id}
          end
        end
      end)

    IO.inspect(target, label: "target {body_id, tile_id}")

    if target do
      {body_id, tile_id} = target

      Game.call(instance_id, :player, profile.id, {:order_building, home_id, "build", {body_id, tile_id, :hab_open_poor, 1}})
      |> IO.inspect(label: "order_building result", limit: 6)
    end

    Instance.Manager.destroy(instance_id)
  end
end
