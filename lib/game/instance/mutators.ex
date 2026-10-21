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

  @doc """
  Absolute starting-credit override (package days like The Bequest), or nil
  for the normal constant × multiplier path.
  """
  def credit_override(instance_id), do: Mutator.credit_override(active_keys(instance_id))

  @doc """
  Cost multiplier for `kind` (`:patent` | `:ship_production`) from active
  on_cost mutators (Open Science, Lost Sciences, Subsidized Yards). 1.0
  outside a live instance / with no such mutator active.
  """
  def cost_multiplier(instance_id, kind), do: Mutator.cost_multiplier(active_keys(instance_id), kind)

  @doc """
  Experience-gain multiplier for a character of `status` from active on_xp
  mutators (Prodigies, Inexperienced Court). 1.0 outside a live instance /
  with no such mutator active.
  """
  def xp_multiplier(instance_id, status), do: Mutator.xp_multiplier(active_keys(instance_id), status)

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
  (income / production / happiness modifiers, etc.) — one entry per bonus, so
  a multi-lever mutator (Panopticon, Open Court, ...) yields several. Consumed
  by `Instance.Player.Player.extract_bonus/2`, which routes each to the
  player, stellar-system or character pipeline by its target — exactly like
  faction traditions. Empty outside a live instance.
  """
  def bonus_entries(instance_id) when is_integer(instance_id) do
    instance_id
    |> active_keys()
    |> Enum.flat_map(fn key ->
      Enum.map(Mutator.bonuses(key), fn bonus -> {key, bonus} end)
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
  The day's objective key (string) for a daily instance, or nil. Read from the
  metadata cache so the live scoring path doesn't re-hit the DB.
  """
  def daily_objective(instance_id), do: meta(instance_id, :daily_objective)

  @doc "The daily's ISO date (string) for `instance_id`, or nil."
  def daily_date(instance_id), do: meta(instance_id, :daily_date)

  @doc "The enemy (puppet) faction's key (string) on a puppet-faction daily, or nil."
  def daily_puppet_faction(instance_id), do: meta(instance_id, :daily_puppet_faction)

  @doc """
  A scenario script's setup on an Edict day (`game_data["daily"]["setup"]`,
  string keys), or nil on every other instance.
  """
  def daily_setup(instance_id), do: meta(instance_id, :daily_setup)

  @doc "True on a day run by a scenario script (Edict) rather than a catalog objective."
  def daily_scripted?(instance_id), do: is_map(daily_setup(instance_id))

  # The day's setup speaks in strings (it comes from jsonb); the engine wants
  # the content's atoms. Only keys that name existing content come through,
  # by lookup, so nothing from the setup ever becomes a new atom.
  defp content_atoms(instance_id, module, keys) when is_list(keys) do
    known = module |> Data.Querier.all(instance_id) |> Map.new(&{Atom.to_string(&1.key), &1.key})
    keys |> Enum.map(&Map.get(known, &1)) |> Enum.reject(&is_nil/1)
  end

  defp content_atoms(_instance_id, _module, _keys), do: []

  @doc """
  Patents the day hands the player up front (before their ancestors are
  added): the script's `grant_patents`, else the catalog objective's grants.
  """
  def daily_granted_patents(instance_id) do
    case daily_setup(instance_id) do
      %{"grant_patents" => keys} -> content_atoms(instance_id, Data.Game.Patent, keys)
      _ -> instance_id |> daily_objective() |> Daily.Objective.granted_patents()
    end
  end

  @doc "Whether the day's granted patents stay out of the per-patent price increase."
  def daily_markup_free?(instance_id) do
    case daily_setup(instance_id) do
      %{"markup_free" => free} -> free == true
      _ -> instance_id |> daily_objective() |> Daily.Objective.markup_free_grants?()
    end
  end

  @doc "Price factors the day puts on single patents, as `%{patent_key => factor}`."
  def daily_patent_discounts(instance_id) do
    case daily_setup(instance_id) do
      %{"patent_discounts" => discounts} when is_map(discounts) ->
        keys = content_atoms(instance_id, Data.Game.Patent, Map.keys(discounts))
        Map.new(keys, fn key -> {key, discounts[Atom.to_string(key)] / 1} end)

      _ ->
        instance_id |> daily_objective() |> Daily.Objective.patent_discounts()
    end
  end

  @doc "Body kinds every system of the day must hold (a catalog objective's `requires`)."
  def daily_required_bodies(instance_id) do
    case daily_setup(instance_id) do
      %{} -> []
      _ -> instance_id |> daily_objective() |> Daily.Objective.required_bodies()
    end
  end

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
