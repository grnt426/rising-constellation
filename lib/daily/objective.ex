defmodule Daily.Objective do
  @moduledoc """
  Scoring goals for the daily challenge. Each day's challenge picks exactly
  one objective; it decides which resource the leaderboard ranks by and how
  that resource is aggregated:

    * `:total`  — the running balance the player is sitting on at the
      deadline (reward early compounding).
    * `:income` — the player's best per-tick rate for that resource
      (reward a high-output build).

  `score/2` reads the relevant field out of a player-stats map — the same
  shape `RC.Instances.PlayerStat` snapshots (see
  lib/rc/instances/player_stat.ex) — so the end-of-daily hook can rank
  players without this module touching the engine. Every objective is
  "higher is better", so the leaderboard sorts by `score/2` descending.

  Note: `:stored_technology` / `:stored_ideology` are not yet columns on
  PlayerStat (only `:stored_credit` is). The two "total" objectives for
  tech/ideology reference those fields so the contract is fixed now; wiring
  the snapshot to populate them is part of the leaderboard milestone (see
  docs/daily-challenge.md).
  """

  @catalog [
    %{
      key: :coffers_of_the_realm,
      name: "Coffers of the Realm",
      resource: :credit,
      aggregation: :total,
      stat_field: :stored_credit,
      description: "Amass the largest credit reserve by the deadline."
    },
    %{
      key: :archives_of_ages,
      name: "Archives of Ages",
      resource: :technology,
      aggregation: :total,
      stat_field: :stored_technology,
      description: "Accumulate the most technology by the deadline."
    },
    %{
      key: :weight_of_faith,
      name: "Weight of Faith",
      resource: :ideology,
      aggregation: :total,
      stat_field: :stored_ideology,
      description: "Accumulate the most ideology by the deadline."
    },
    %{
      key: :golden_flow,
      name: "Golden Flow",
      resource: :credit,
      aggregation: :income,
      stat_field: :output_credit,
      description: "Drive credit income as high as it will go."
    },
    %{
      key: :tide_of_invention,
      name: "Tide of Invention",
      resource: :technology,
      aggregation: :income,
      stat_field: :output_technology,
      description: "Drive technology income as high as it will go."
    },
    %{
      key: :rising_creed,
      name: "Rising Creed",
      resource: :ideology,
      aggregation: :income,
      stat_field: :output_ideology,
      description: "Drive ideology income as high as it will go."
    },
    %{
      key: :forge_unceasing,
      name: "Forge Unceasing",
      resource: :production,
      aggregation: :income,
      stat_field: :best_prod,
      description: "Push industrial production to its peak."
    }
  ]

  @doc "Every objective, in display order."
  def catalog, do: @catalog

  @doc "Just the objective keys, in display order."
  def keys, do: Enum.map(@catalog, & &1.key)

  @doc """
  Look up one objective by key. Accepts atoms or strings (the latter is what
  arrives from game_data jsonb).
  """
  def get(key) when is_atom(key), do: Enum.find(@catalog, &(&1.key == key))
  def get(key) when is_binary(key), do: Enum.find(@catalog, &(Atom.to_string(&1.key) == key))
  def get(_), do: nil

  @doc """
  Score a player against an objective. `objective` may be a catalog entry,
  an objective key (atom or string), or nil. `stats` is a map of player
  stats keyed by either atom or string. Missing data scores 0 rather than
  crashing, so a player who never moved still ranks (last).
  """
  def score(%{stat_field: field}, stats) when is_map(stats), do: fetch_number(stats, field)

  def score(key, stats) when (is_atom(key) or is_binary(key)) and is_map(stats) do
    case get(key) do
      nil -> 0
      objective -> score(objective, stats)
    end
  end

  def score(_, _), do: 0

  defp fetch_number(stats, field) do
    value = Map.get(stats, field) || Map.get(stats, Atom.to_string(field))
    if is_number(value), do: value, else: 0
  end
end
