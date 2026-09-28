defmodule Wave.Lobby do
  @moduledoc """
  Rebel Defense through the normal Forge → lobby path.

  `Wave.Boot` stands a wave game up in one call for the dev harness. Players
  reach the mode the ordinary way instead:

    1. **Forge.** The map-maker picks "Rebel Defense" as the scenario's game
       mode, paints two factions as usual and marks one of them as the rebel
       start. The editor saves that faction's sectors as `"rebellion"`, so a
       wave scenario carries exactly one human faction and the Rebellion
       (`validate_scenario/1`).
    2. **New game.** `RC.Instances.create_instance/3` calls
       `prepare_instance/2`: the mode is forced to `"wave"`, faction government
       off, the Rebellion's seat count to one, and the `game_data["wave"]` block
       names both factions (knobs default at runtime through `Wave.Config`).
    3. **Publish / Start.** `ensure_rebellion_registered/1` seats the shared
       Rebellion bot profile, idempotently, on publish and again before the first
       start. The Manager then spawns the Warlord like any wave instance.
  """

  import Ecto.Query

  alias RC.Instances.Registration

  @rebellion "rebellion"

  @doc "True when a scenario's or instance's `game_data` is a Rebel Defense game."
  def wave?(%{"game_mode_type" => mode}), do: mode == Wave.mode_type()
  def wave?(_game_data), do: false

  @doc """
  Check a wave scenario's `game_data`: Legacy speed, exactly one playable
  faction plus the Rebellion, each holding at least one sector. Non-wave
  scenarios pass untouched.
  """
  def validate_scenario(game_data) do
    if wave?(game_data), do: do_validate(game_data), else: :ok
  end

  defp do_validate(game_data) do
    keys = game_data |> Map.get("factions", []) |> Enum.map(&faction_key/1)
    sectors = Map.get(game_data, "sectors", [])
    humans = Enum.reject(keys, &(&1 == @rebellion))
    held? = fn key -> Enum.any?(sectors, &(&1["faction"] == key)) end

    cond do
      game_data["speed"] != "slow" -> {:error, :wave_requires_legacy_speed}
      @rebellion not in keys -> {:error, :wave_requires_rebel_faction}
      length(humans) != 1 -> {:error, :wave_requires_one_human_faction}
      not playable?(hd(humans)) -> {:error, :wave_human_faction_not_playable}
      not held?.(@rebellion) -> {:error, :wave_rebellion_has_no_sector}
      not held?.(hd(humans)) -> {:error, :wave_human_faction_has_no_sector}
      true -> :ok
    end
  end

  @doc "The human faction key of a wave scenario/instance `game_data`, or nil."
  def human_faction(game_data) do
    game_data
    |> Map.get("factions", [])
    |> Enum.map(&faction_key/1)
    |> Enum.find(&(&1 != @rebellion))
  end

  @doc """
  Rewrite `RC.Instances.create_instance/3`'s attrs and `game_data` for a wave
  scenario. A non-wave scenario can never become a wave game (the Rebellion
  needs a start sector the map-maker placed), so a stray `"wave"` mode from
  the client falls back to casual there.

  Returns `{attrs, game_data}`.
  """
  def prepare_instance(attrs, game_data) do
    cond do
      wave?(game_data) -> prepare_wave(attrs, game_data)
      attrs["game_mode_type"] == Wave.mode_type() -> {Map.put(attrs, "game_mode_type", "casual"), game_data}
      true -> {attrs, game_data}
    end
  end

  defp prepare_wave(attrs, game_data) do
    human = human_faction(game_data)

    wave =
      game_data
      |> Map.get("wave", %{})
      |> case do
        map when is_map(map) -> map
        _ -> %{}
      end
      |> Map.merge(%{"bot_faction" => @rebellion, "human_faction" => human})

    game_data = Map.put(game_data, "wave", wave)

    attrs =
      attrs
      |> Map.put("game_mode_type", Wave.mode_type())
      # The Rebellion has no government; an absent key would grandfather it ON.
      |> Map.put("faction_gov_enabled", false)
      |> Map.put("factions", wave_factions(attrs["factions"], human))

    {attrs, game_data}
  end

  # The human faction keeps the creator's capacity; the Rebellion always has
  # exactly one seat, the bot's. Any other faction the client sent is dropped.
  defp wave_factions(factions, human) do
    human_capacity =
      (factions || [])
      |> Enum.find(&(&1["key"] == human))
      |> case do
        %{"capacity" => capacity} when is_integer(capacity) and capacity > 0 -> capacity
        _ -> 20
      end

    [%{"key" => human, "capacity" => human_capacity}, %{"key" => @rebellion, "capacity" => 1}]
  end

  @doc """
  Seat the shared Rebellion bot profile in a wave instance's Rebellion faction.
  Idempotent; a no-op (`{:ok, :not_wave}`) for other instances.
  """
  def ensure_rebellion_registered(%{game_data: game_data, id: instance_id}) do
    if wave?(game_data) do
      instance = RC.Instances.get_instance_with_registration(instance_id)

      case Enum.find(instance.factions, &(&1.faction_ref == @rebellion)) do
        nil -> {:error, :wave_instance_without_rebel_faction}
        faction -> register(faction)
      end
    else
      {:ok, :not_wave}
    end
  end

  defp register(faction) do
    profile = Wave.Boot.rebellion_profile()

    already? =
      RC.Repo.exists?(from(r in Registration, where: r.faction_id == ^faction.id and r.profile_id == ^profile.id))

    if already? do
      {:ok, :already_registered}
    else
      case RC.Registrations.register_profile(faction, profile) do
        {:ok, _} -> {:ok, :registered}
        {:error, step, reason, _} -> {:error, {:register_rebellion, step, reason}}
        other -> {:error, {:register_rebellion, other}}
      end
    end
  end

  defp faction_key(%{"key" => key}), do: key
  defp faction_key(%{key: key}), do: to_string(key)
  defp faction_key(key) when is_binary(key), do: key
  defp faction_key(_), do: nil

  @playable_keys Data.Game.Faction.Content.data() |> Data.Game.Faction.playable() |> Enum.map(&Atom.to_string(&1.key))

  defp playable?(key), do: key in @playable_keys
end
