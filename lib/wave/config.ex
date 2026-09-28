defmodule Wave.Config do
  @moduledoc """
  Runtime reads of the Wave Defense mode switches.

  Every read goes through the per-instance metadata cache (`Data.Data`), the
  same way `Instance.Mutators.daily?/1` does — the engine must never hit the
  DB on a tick path. All functions are rescue-guarded and return a safe
  "not a wave game" answer outside a live instance (tests, the `:sim`
  pseudo-instance, an instance booted before this feature existed), so they
  are cheap to call unconditionally from hot code.
  """

  alias Instance.StellarSystem.StellarSystem

  @doc "True when this instance is a Wave Defense game."
  def enabled?(instance_id) when is_integer(instance_id) do
    metadata(instance_id)[:wave] == true
  end

  def enabled?(_), do: false

  @doc """
  The merged knob map (`Wave.defaults/0` under the instance's own
  `game_data["wave"]`). Returns the defaults for a non-wave instance, so
  callers can read a knob without a nil check — but they should gate on
  `enabled?/1` first.
  """
  def knobs(instance_id) do
    stored = metadata(instance_id)[:wave_config]

    case stored do
      map when is_map(map) -> Map.merge(Wave.defaults(), stringify(map))
      _ -> Wave.defaults()
    end
  end

  @doc "One knob, with the shipped default as fallback."
  def knob(instance_id, key, default \\ nil) do
    case Map.get(knobs(instance_id), key) do
      nil -> default
      value -> value
    end
  end

  @doc "The bot-held faction key as an atom, or nil outside a wave game."
  def bot_faction(instance_id) do
    if enabled?(instance_id) do
      to_faction_atom(knob(instance_id, "bot_faction"))
    end
  end

  @doc "True when `faction_key` is the instance's bot-held faction."
  def bot_faction?(_instance_id, nil), do: false

  def bot_faction?(instance_id, faction_key) do
    case bot_faction(instance_id) do
      nil -> false
      key -> key == faction_key
    end
  end

  @doc """
  True when this stellar system is held by the Rebellion — an owned system or
  a dominion. Unowned (neutral / uninhabited) systems are never rebel systems.
  """
  def bot_system?(%StellarSystem{owner: nil}), do: false

  def bot_system?(%StellarSystem{owner: owner, instance_id: instance_id}) do
    bot_faction?(instance_id, Map.get(owner, :faction))
  end

  def bot_system?(_), do: false

  @doc """
  The permanent bonuses that lift the bot player's caps. Returned in
  `Instance.Player.Player.extract_bonus/2`'s `%{reason:, bonus:}` shape and
  applied ONLY to the bot player, so humans in the same instance keep the
  normal caps. Additive on the `player_*` pipeline-out keys, which map to
  `max_systems` / `max_dominions` / `max_admirals` / `max_spies` /
  `max_speakers`.
  """
  def player_bonuses(instance_id) do
    [
      {:max_systems_bonus, :player_system},
      {:max_dominions_bonus, :player_dominion},
      {:max_admirals_bonus, :player_admiral},
      {:max_spies_bonus, :player_spy},
      {:max_speakers_bonus, :player_speaker}
    ]
    |> Enum.flat_map(fn {knob, pipeline_key} ->
      case knob(instance_id, Atom.to_string(knob), 0) do
        value when is_number(value) and value > 0 ->
          [
            %{
              reason: {:misc, :wave_rebellion},
              bonus: %Core.Bonus{from: :direct, value: value, type: :add, to: pipeline_key}
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc """
  True when bankruptcy must not be applied to this player. The Rebellion is a
  scripted antagonist: a bankruptcy would put every one of its agents
  `on_strike` and silently freeze the mode.
  """
  def bankruptcy_exempt?(%{instance_id: instance_id, faction: faction}) do
    bot_faction?(instance_id, faction)
  end

  def bankruptcy_exempt?(_), do: false

  @doc """
  The behavior-tree key and AI cadence (in ut) for a stellar system, or nil
  when the system has no autonomous AI at all.

    * rebellion-held system or dominion -> the Rebel Dominion tree, fast cadence
    * any other neutral system or dominion -> the vanilla tree, `default_interval`
    * a human-owned system -> nil (players build their own systems)
  """
  def system_ai(%StellarSystem{} = system, default_interval) do
    cond do
      bot_system?(system) and system.status in [:inhabited_player, :inhabited_dominion] ->
        {:rebel_dominion, ai_interval(system.instance_id)}

      system.status in [:inhabited_neutral, :inhabited_dominion] ->
        {:dominion, default_interval}

      true ->
        nil
    end
  end

  @doc "Cadence of the Rebel Dominion tree, in ut."
  def ai_interval(instance_id) do
    case knob(instance_id, "ai_interval_ut", 1.667) do
      value when is_number(value) and value > 0 -> value
      _ -> 1.667
    end
  end

  # --- internals ------------------------------------------------------------

  defp metadata(instance_id) when is_integer(instance_id) do
    Data.Data.get(instance_id, :metadata) || []
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp metadata(_), do: []

  # game_data comes back from jsonb with string keys; a freshly-built config
  # (tests, Wave.Boot before the round-trip) may use atoms. Normalize one level.
  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp to_faction_atom(key) when is_atom(key) and not is_nil(key), do: key

  defp to_faction_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp to_faction_atom(_), do: nil
end
