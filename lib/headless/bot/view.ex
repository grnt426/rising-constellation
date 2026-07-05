defmodule Headless.Bot.View do
  @moduledoc """
  Per-decision game-state snapshot for a bot player.

  Built fresh each decision tick by the driver — this is the "bot reads the
  game" cost that AI evaluation pays, so it is measured (see
  `Headless.Bot` stats) rather than hidden. Fields:

    * `:player` — full `Instance.Player.Player` struct (resources, characters,
      owned systems list, patents/doctrines, deck)
    * `:systems` — `%{system_id => stellar_system_state}` for OWNED systems
      (bodies/tiles/production queues — what the economy taskmaster needs)
    * `:market` — character market state (hireable characters)
    * `:galaxy` — galaxy agent state (all-system summaries: position, type,
      status, owner, population). NOTE: this is an omniscient read — no
      fog-of-war filtering yet. Shipped 4X AIs overwhelmingly cheat on
      vision (see docs/game-ai.md §1); revisit when bots must be fair.
    * `:now_ut` — current game time (UT-days), for pipeline timing and
      time-to-milestone metrics.
  """

  defstruct [:instance_id, :player, :systems, :market, :galaxy, :characters, :radar_blips, :intel, :victory, :now_ut]

  @type t :: %__MODULE__{}

  def build(instance_id, player_id) do
    with {:ok, player} <- Game.call(instance_id, :player, player_id, :get_state) do
      systems =
        player.stellar_systems
        |> Enum.map(& &1.id)
        |> Enum.reduce(%{}, fn id, acc ->
          case Game.call(instance_id, :stellar_system, id, :get_state) do
            {:ok, system} -> Map.put(acc, id, system)
            _ -> acc
          end
        end)

      # Full state (army tiles, action queue) for characters active on the
      # map — the player struct only carries summaries.
      characters =
        player.characters
        |> Enum.map(& &1.id)
        |> Enum.reduce(%{}, fn id, acc ->
          case Game.call(instance_id, :player, player_id, {:get_character_state, id}) do
            {:error, _} -> acc
            %{} = character -> Map.put(acc, id, character)
            {:ok, %{} = character} -> Map.put(acc, id, character)
            _ -> acc
          end
        end)

      market =
        case Game.call(instance_id, :character_market, :master, :get_state) do
          {:ok, market} -> market
          _ -> nil
        end

      galaxy =
        case Game.call(instance_id, :galaxy, :master, :get_state) do
          {:ok, galaxy} -> galaxy
          _ -> nil
        end

      # Faction-level intelligence (true information rules, not omniscient):
      # radar_blips — foreign characters currently in radar range
      # (%{faction, character_id, owner_player_id, position, angle});
      # intel — per-system visibility contacts (%{system_id =>
      # Core.VisibilityValue}): level >= 3 means the system is scouted
      # deeply enough to read its internals (stability etc.).
      {radar_blips, intel} =
        case Game.call(instance_id, :faction, player.faction_id, :get_state) do
          {:ok, faction} ->
            {Enum.reject(faction.detected_objects, &(&1.faction == player.faction)), faction.contacts}

          _ ->
            {[], %{}}
        end

      # Victory-track standings are PUBLIC (the victory panel): per-faction
      # conquest/population/visibility tracks — the observable that lets a
      # bot react to an enemy closing on a shadows victory.
      victory =
        case Game.call(instance_id, :victory, :master, :get_state) do
          {:ok, victory} -> victory
          _ -> nil
        end

      now_ut =
        case Game.call(instance_id, :time, :master, :get_state) do
          {:ok, %{now: %{value: v}}} -> v
          _ -> nil
        end

      {:ok,
       %__MODULE__{
         instance_id: instance_id,
         player: player,
         systems: systems,
         market: market,
         galaxy: galaxy,
         characters: characters,
         radar_blips: radar_blips,
         intel: intel,
         victory: victory,
         now_ut: now_ut
       }}
    end
  end
end
