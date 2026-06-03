defmodule Instance.Mutators do
  @moduledoc """
  Per-instance mutator lookup. Reads the scenario's mutator list
  (jsonb under game_data["mutators"]) out of the in-memory metadata
  cache that `Instance.Manager.init_from_model/4` populates at game
  start.

  All lookups return safe defaults (`false`, `1.0`, `[]`) when the
  cache hasn't been initialized — so calling this from code paths
  that might run outside a live instance (a test, a cold migration
  task) doesn't crash.

  See lib/data/game/mutator.ex for the catalog and lib/game/instance/
  manager.ex for the cache write.
  """

  alias Data.Game.Mutator

  @doc """
  All active mutator keys for `instance_id` as a list of atoms.
  Atoms come from String.to_existing_atom so an unknown / typo'd
  mutator name in game_data silently no-ops rather than blowing
  up.
  """
  def active_keys(instance_id) when is_integer(instance_id) do
    instance_id
    |> raw_list()
    |> Enum.flat_map(fn entry ->
      case entry do
        %{"key" => key} when is_binary(key) -> safe_atom(key)
        %{key: key} when is_atom(key) -> [key]
        _ -> []
      end
    end)
  end

  def active_keys(_), do: []

  @doc """
  True when `key` is enabled for this instance.
  """
  def active?(instance_id, key) when is_atom(key) do
    key in active_keys(instance_id)
  end

  @doc """
  Resource-scaler helpers. Each returns the multiplier the active
  mutators want applied to the corresponding starting resource.
  """
  def credit_multiplier(instance_id), do: Mutator.credit_multiplier(active_keys(instance_id))

  def technology_multiplier(instance_id),
    do: Mutator.technology_multiplier(active_keys(instance_id))

  def ideology_multiplier(instance_id), do: Mutator.ideology_multiplier(active_keys(instance_id))

  # --- private ---

  # Returns the raw mutator entries as stored in game_data. Tolerates
  # the case where the metadata cache hasn't been written yet (returns
  # []) so tests and tooling don't have to set up the full instance
  # registry just to call into Player.new.
  defp raw_list(instance_id) do
    try do
      Data.Data.get(instance_id, :metadata)[:mutators] || []
    rescue
      _ -> []
    end
  end

  defp safe_atom(name) do
    [String.to_existing_atom(name)]
  rescue
    ArgumentError -> []
  end
end
