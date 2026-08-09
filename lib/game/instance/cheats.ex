defmodule Instance.Cheats do
  @moduledoc """
  Cheat access for a running instance.

  Opt-in at game creation (`cheats_enabled` in the creation form → merged into
  `game_data` → cached in the per-instance metadata by
  `Instance.Manager.init_from_model/4`). When enabled, the game creator can
  join the CheatChannel and drive the cheat operations (grant resources,
  instant settle, election fast-forward, cooldown clears, runtime speedup).

  Read from the metadata cache the same way as `Instance.Mutators.daily?/1`,
  so it's safe to call from any engine path. Defaults to disabled outside a
  live instance (tests building domain structs directly, etc.).
  """

  @chat_announcement "This match has CHEATS enabled"

  @doc "The system chat message seeded into every faction's chat at genesis."
  def chat_announcement, do: @chat_announcement

  @doc "True when this instance was created with cheat access."
  def enabled?(instance_id) when is_integer(instance_id) do
    try do
      Data.Data.get(instance_id, :metadata)[:cheats_enabled] == true
    rescue
      _ -> false
    end
  end

  def enabled?(_), do: false

  @doc """
  The current runtime speed multiplier (set via the speed cheat), 1 when
  never changed. Persisted in the metadata cache so snapshot restores and
  late-created agents (new players, hired characters) pick it up.
  """
  def speedup(instance_id) when is_integer(instance_id) do
    try do
      case Data.Data.get(instance_id, :metadata)[:cheat_speedup] do
        multiplier when is_number(multiplier) and multiplier > 0 -> multiplier
        _ -> 1
      end
    rescue
      _ -> 1
    end
  end

  def speedup(_), do: 1
end
