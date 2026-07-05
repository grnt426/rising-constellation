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

  @doc """
  World-generation mutator helpers, looked up while a system is being
  generated (`Instance.StellarSystem.StellarBody.new/5`). The metadata cache
  is already populated by then (`Instance.Manager.init_from_model/4` writes it
  before spinning up systems), so these see the daily's mutators. See
  `Data.Game.Mutator` for the effects.
  """
  def gen_factor_override(instance_id, body_kind),
    do: Mutator.gen_factor_override(active_keys(instance_id), body_kind)

  def extra_tiles(instance_id), do: Mutator.extra_tiles(active_keys(instance_id))

  @doc """
  `{mutator_key, %Core.Bonus{}}` for every active mutator that injects a bonus
  (income / production / happiness modifiers, etc.). Consumed by
  `Instance.Player.Player.extract_bonus/2`, which routes each to the player or
  stellar-system pipeline by its target — exactly like faction traditions.
  Empty outside a live instance.
  """
  def bonus_entries(instance_id) when is_integer(instance_id) do
    instance_id
    |> active_keys()
    |> Enum.flat_map(fn key ->
      case Mutator.bonus(key) do
        %Core.Bonus{} = bonus -> [{key, bonus}]
        _ -> []
      end
    end)
  end

  def bonus_entries(_), do: []

  @doc """
  True when this instance is a daily challenge. Read from the metadata cache
  the same way as mutators (written by `Instance.Manager.init_from_model/4`),
  so it's safe to call from generation/claim. Defaults to false outside a live
  instance.
  """
  def daily?(instance_id) when is_integer(instance_id) do
    try do
      Data.Data.get(instance_id, :metadata)[:daily] == true
    rescue
      _ -> false
    end
  end

  def daily?(_), do: false

  @doc """
  True when this instance is a headless (in-memory, no DB rows) run — see
  `Headless.Runner`. Endgame DB bookkeeping (close/record/rank) and the
  autosave loop are skipped for these instances: there is no instance row to
  update and no snapshot worth keeping. Read from the metadata cache like
  `daily?/1`; defaults to false outside a live instance.
  """
  def headless?(instance_id) when is_integer(instance_id) do
    try do
      Data.Data.get(instance_id, :metadata)[:headless] == true
    rescue
      _ -> false
    end
  end

  def headless?(_), do: false

  @doc """
  The day's objective key (string) for a daily instance, or nil. Read from the
  metadata cache so the live scoring path doesn't re-hit the DB.
  """
  def daily_objective(instance_id), do: meta(instance_id, :daily_objective)

  @doc "The daily's ISO date (string) for `instance_id`, or nil."
  def daily_date(instance_id), do: meta(instance_id, :daily_date)

  defp meta(instance_id, key) when is_integer(instance_id) do
    try do
      Data.Data.get(instance_id, :metadata)[key]
    rescue
      _ -> nil
    end
  end

  defp meta(_, _), do: nil

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
