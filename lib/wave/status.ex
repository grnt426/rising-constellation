defmodule Wave.Status do
  @moduledoc """
  A JSON-able readout of a live Wave Defense instance, for the dev harness and
  for eyeballing the MVP: what the Warlord is doing, what the bot player looks
  like (resources, caps, bankruptcy, agents), how its systems are developing,
  and — as a control — the caps and bankruptcy state of a human player in the
  same instance, which must NOT carry the bot's bypasses.

  Every read is a live agent call and every failure degrades to nil rather than
  raising, so the endpoint stays usable while an instance is mid-boot.
  """

  def read(instance_id) when is_binary(instance_id), do: read(String.to_integer(instance_id))

  def read(instance_id) when is_integer(instance_id) do
    warlord = call(instance_id, :wave, :master, :status)
    galaxy = call(instance_id, :galaxy, :master, :get_state)
    time = call(instance_id, :time, :master, :get_state)

    bot_id = warlord && warlord.player_id
    bot = bot_id && call(instance_id, :player, bot_id, :get_state)

    humans =
      case galaxy do
        %{players: players} ->
          players
          |> Map.values()
          |> Enum.reject(&(&1.id == bot_id))
          |> Enum.map(fn p -> call(instance_id, :player, p.id, :get_state) end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    %{
      instance_id: instance_id,
      running: match?(%{is_running: true}, time),
      speed: time && time.speed,
      game_day: time && round_to(time.now.value, 1),
      warlord: warlord,
      rebellion: bot && player_view(bot),
      rebel_systems: bot && Enum.map(bot.stellar_systems ++ bot.dominions, &system_view(instance_id, &1.id)),
      humans: Enum.map(humans, &player_view/1),
      sectors: galaxy && sectors_view(galaxy, warlord && warlord.bot_faction)
    }
  end

  # Sector control: who owns each sector, the inhabited-system counts that
  # decide ownership (neutral systems count as a nil faction), and how many
  # uninhabited systems are still open to colonization.
  defp sectors_view(galaxy, bot_faction) do
    systems_by_sector = Enum.group_by(galaxy.stellar_systems, & &1.sector_id)

    rows =
      galaxy.sectors
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn sector ->
        systems = Map.get(systems_by_sector, sector.id, [])
        count = fn pred -> Enum.count(systems, pred) end

        %{
          id: sector.id,
          name: sector.name,
          owner: sector.owner,
          adjacent: Enum.sort(sector.adjacent),
          victory_points: sector.victory_points,
          systems: length(systems),
          rebel: count.(&(&1.faction == bot_faction and &1.faction != nil)),
          human: count.(&(&1.faction not in [nil, bot_faction])),
          neutral: count.(&(&1.status == :inhabited_neutral)),
          uninhabited: count.(&(&1.status == :uninhabited)),
          uninhabitable: count.(&(&1.status == :uninhabitable))
        }
      end)

    %{
      total: length(rows),
      rebel_owned: Enum.count(rows, &(&1.owner == bot_faction and bot_faction != nil)),
      rows: rows
    }
  end

  defp player_view(player) do
    %{
      id: player.id,
      name: player.name,
      faction: player.faction,
      is_active: player.is_active,
      is_bankrupt: player.is_bankrupt,
      credit: round_to(player.credit.value, 0),
      credit_per_ut: round_to(player.credit.change, 1),
      technology: round_to(player.technology.value, 0),
      ideology: round_to(player.ideology.value, 0),
      caps: %{
        max_systems: player.max_systems.value,
        max_dominions: player.max_dominions.value,
        max_admirals: player.max_admirals.value
      },
      systems: length(player.stellar_systems),
      dominions: length(player.dominions),
      agents:
        Enum.map(player.characters, fn c ->
          %{id: c.id, type: c.type, status: c.status, action_status: c.action_status, system: c.system}
        end),
      deck: Enum.map(player.character_deck, fn %{character: c} -> c.id end)
    }
  end

  defp system_view(instance_id, system_id) do
    case call(instance_id, :stellar_system, system_id, :get_state) do
      nil ->
        %{id: system_id, unreachable: true}

      system ->
        tiles = system.bodies |> flatten_bodies() |> Enum.flat_map(& &1.tiles)
        built = Enum.filter(tiles, &(&1.building_status == :built))

        %{
          id: system.id,
          name: system.name,
          status: system.status,
          production: round_to(system.production.value, 1),
          ai_next_action_ut: round_to(system.ai_next_action.value, 2),
          # Growth gates the build AI reacts to: free workforce blocks new
          # buildings, habitation caps population.
          workforce: system.workforce,
          used_workforce: system.used_workforce,
          habitation: round_to(system.habitation.value, 1),
          population: round_to(system.population.value, 1),
          population_change: round_to(system.population.change, 3),
          happiness: round_to(system.happiness.value, 1),
          tiles: length(tiles),
          built: length(built),
          levels: built |> Enum.map(& &1.building_level) |> Enum.frequencies(),
          queue:
            system.queue.queue
            |> Queue.to_list()
            |> Enum.map(fn item -> %{type: item.type, key: item.prod_key, level: item.prod_level} end)
        }
    end
  end

  defp flatten_bodies(bodies), do: Enum.flat_map(bodies, fn body -> [body | body.bodies] end)

  defp call(instance_id, type, id, message) do
    case Game.call_no_log(instance_id, type, id, message, 1, 3_000) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp round_to(value, digits) when is_number(value), do: Float.round(value / 1, digits)
  defp round_to(_value, _digits), do: nil
end
