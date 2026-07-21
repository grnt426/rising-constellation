defmodule Daily.Objective do
  @moduledoc """
  Scoring goals for the daily challenge. Each day's challenge picks exactly
  one objective; it decides which resource the leaderboard ranks by and how
  the score is produced. Every objective has a `mode` — the scoring shape:

    * `:max_stat`   — read one field off the player-stats map at the deadline
      (higher wins). `aggregation` refines the flavor: `:total` is the running
      balance (reward early compounding), `:income` the per-tick rate (reward
      a high-output build).
    * `:composite`  — computed from several stats at score time (e.g. the
      Triumvirate's min-of-three-incomes).
    * `:race`       — the day defines a goal predicate; the score is the
      number of real seconds left on the clock when the player completes it
      (0 for did-not-finish). Completion is detected live by
      `Daily.Boot.race_tick/2`; the deadline path scores 0 with the player's
      progress toward the goal as the tiebreak.

  Every mode is "higher is better", so the leaderboard sorts by score
  descending — races included (more seconds left = faster). Ties break on the
  objective's `tiebreak`, stored alongside the score in `daily_entries` and
  published with the goal (see docs/daily-challenge-ideas.md).

  `evaluate/3` reads a player-stats map — the same shape
  `RC.Instances.PlayerStat` snapshots (see lib/rc/instances/player_stat.ex) —
  plus, for race progress, the live player (any map with a `stellar_systems`
  list works, so tests need no engine coupling).

  Note: `:stored_technology` / `:stored_ideology` are not yet columns on
  PlayerStat (only `:stored_credit` is). The scoring path derives them from
  the live player at score time (see `Daily.Boot.record_for/2`).
  """

  @catalog [
    %{
      key: :coffers_of_the_realm,
      name: "Coffers of the Realm",
      resource: :credit,
      aggregation: :total,
      mode: :max_stat,
      stat_field: :stored_credit,
      description: "Amass the largest credit reserve by the deadline."
    },
    %{
      key: :archives_of_ages,
      name: "Archives of Ages",
      resource: :technology,
      aggregation: :total,
      mode: :max_stat,
      stat_field: :stored_technology,
      description: "Accumulate the most technology by the deadline."
    },
    %{
      key: :weight_of_faith,
      name: "Weight of Faith",
      resource: :ideology,
      aggregation: :total,
      mode: :max_stat,
      stat_field: :stored_ideology,
      description: "Accumulate the most ideology by the deadline."
    },
    %{
      key: :golden_flow,
      name: "Golden Flow",
      resource: :credit,
      aggregation: :income,
      mode: :max_stat,
      stat_field: :output_credit,
      description: "Drive credit income as high as it will go."
    },
    %{
      key: :tide_of_invention,
      name: "Tide of Invention",
      resource: :technology,
      aggregation: :income,
      mode: :max_stat,
      stat_field: :output_technology,
      description: "Drive technology income as high as it will go."
    },
    %{
      key: :rising_creed,
      name: "Rising Creed",
      resource: :ideology,
      aggregation: :income,
      mode: :max_stat,
      stat_field: :output_ideology,
      description: "Drive ideology income as high as it will go."
    },
    %{
      key: :forge_unceasing,
      name: "Forge Unceasing",
      resource: :production,
      aggregation: :income,
      mode: :max_stat,
      stat_field: :best_prod,
      description: "Push industrial production to its peak."
    },
    %{
      key: :the_triumvirate,
      name: "The Triumvirate",
      resource: :balance,
      aggregation: :composite,
      mode: :composite,
      stat_field: nil,
      description:
        "Score is the LOWEST of your three income rates (credit, technology, ideology) — only balance counts. Ties break on the combined total."
    },
    # Race specs are shape-dispatched (see race_progress/2):
    #   %{system_income: %{...}} — one system meeting every income threshold
    #   %{patent: key, cost: n}  — a named patent researched (cost feeds the
    #                              DNF tiebreak: patents researched + banked
    #                              tech as a fraction of the target's cost)
    #   %{army: %{metric: n}}    — a single fleet reaching the metric
    #                              (:raid | :invasion | :maintenance)
    %{
      key: :charter_of_prosperity,
      name: "Charter of Prosperity",
      resource: :system,
      aggregation: :race,
      mode: :race,
      stat_field: nil,
      race: %{system_income: %{credit: 800, technology: 50, ideology: 40}},
      description:
        "A race: push a single system to 800 credit, 50 technology and 40 ideology income at once. Score is the time left when you get there; ties break on progress."
    },
    %{
      key: :destroyers_blueprint,
      name: "The Destroyer's Blueprint",
      resource: :technology,
      aggregation: :race,
      mode: :race,
      stat_field: nil,
      race: %{patent: :capital_1, cost: 80_000},
      description:
        "A race: research the Destroyer patent (the first capital ship). Score is the time left when it completes; ties break on patents researched, then banked technology."
    },
    %{
      key: :fleet_in_being_raiders,
      name: "Fleet in Being: Raiders",
      resource: :fleet,
      aggregation: :race,
      mode: :race,
      stat_field: nil,
      race: %{army: %{raid: 50}},
      description:
        "A race: field a single fleet with 50 bombing power. Score is the time left when it musters; ties break on your best fleet's progress."
    },
    %{
      key: :fleet_in_being_vanguard,
      name: "Fleet in Being: Vanguard",
      resource: :fleet,
      aggregation: :race,
      mode: :race,
      stat_field: nil,
      race: %{army: %{invasion: 50}},
      description:
        "A race: field a single fleet with 50 conquest power. Score is the time left when it musters; ties break on your best fleet's progress."
    },
    %{
      key: :fleet_in_being_armada,
      name: "Fleet in Being: Armada",
      resource: :fleet,
      aggregation: :race,
      mode: :race,
      stat_field: nil,
      race: %{army: %{maintenance: 500}},
      description:
        "A race: field a single fleet costing 500 credits of upkeep. Score is the time left when it musters; ties break on your best fleet's progress."
    },
    # A "package day": the objective carries its own fixed setup
    # (package_mutators) and the generator pins those INSTEAD of rolling the
    # usual 2 boons + 1 bane — the scripted scenario IS the day's identity.
    %{
      key: :the_bequest,
      name: "The Bequest",
      resource: :credit,
      aggregation: :total,
      mode: :max_stat,
      stat_field: :stored_credit,
      tiebreak_field: :output_credit,
      package_mutators: [:the_bequest_estate],
      description:
        "Inherit a fortune of 100,000,000 credits — bleeding away 5,000 a minute. End with the most left; ties break on credit income."
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
  Score + tiebreak for a player against an objective, as
  `%{score: float, tiebreak: float}`. `objective` may be a catalog entry, an
  objective key (atom or string), or nil. `stats` is a player-stats map keyed
  by atoms or strings; `player` (optional) is the live player — only race
  progress reads it (any map with a `stellar_systems` list of per-system
  income summaries works). Missing data scores 0 rather than crashing, so a
  player who never moved still ranks (last).

  Race days score 0 here — this is the deadline/DNF path; the winning score
  (seconds left at completion) is recorded live by `Daily.Boot.race_tick/2`.
  """
  def evaluate(objective, stats, player \\ nil)

  def evaluate(%{mode: :max_stat, stat_field: field} = objective, stats, _player) when is_map(stats) do
    tiebreak =
      case Map.get(objective, :tiebreak_field) do
        nil -> 0.0
        tiebreak_field -> fetch_number(stats, tiebreak_field) / 1
      end

    %{score: fetch_number(stats, field) / 1, tiebreak: tiebreak}
  end

  def evaluate(%{mode: :composite, key: :the_triumvirate}, stats, _player) when is_map(stats) do
    incomes =
      Enum.map([:output_credit, :output_technology, :output_ideology], &fetch_number(stats, &1))

    %{score: Enum.min(incomes) / 1, tiebreak: Enum.sum(incomes) / 1}
  end

  def evaluate(%{mode: :race} = objective, stats, player) when is_map(stats) do
    %{score: 0.0, tiebreak: race_progress(objective, player)}
  end

  def evaluate(key, stats, player) when is_atom(key) or is_binary(key) do
    case get(key) do
      nil -> %{score: 0.0, tiebreak: 0.0}
      objective -> evaluate(objective, stats, player)
    end
  end

  def evaluate(_, _, _), do: %{score: 0.0, tiebreak: 0.0}

  @doc """
  Score a player against an objective (deadline path only — see `evaluate/3`,
  which this delegates to). Kept as the simple entry point for callers and
  tests that don't care about tiebreaks.
  """
  def score(objective, stats), do: evaluate(objective, stats).score

  @doc """
  Whether the live player has completed a race objective's goal. `player` is
  the live player struct, or any map of the same shape. Non-race objectives
  (and nil players) are never completed. Called from the player agent's tick
  (`Daily.Boot.race_tick/2`), so every branch is a cheap read of player state
  — no engine calls.
  """
  def race_completed?(%{mode: :race, race: %{patent: patent_key}}, player) when is_map(player) do
    patent_key in (Map.get(player, :patents) || [])
  end

  def race_completed?(%{mode: :race} = objective, player) when is_map(player) do
    race_progress(objective, player) >= 1.0
  end

  def race_completed?(_, _), do: false

  @doc """
  Progress toward a race goal — the DNF tiebreak, dispatched on the race
  spec's shape. Higher is better; only same-spec values are ever compared
  (the tiebreak lives with the day's objective), so the scales don't need to
  match across specs:

    * `system_income` — the best system's bottleneck ratio in [0, 1] (the
      *lowest* of its threshold ratios — you're only as close as your weakest
      number).
    * `patent` — patents researched, plus banked technology as a fraction of
      the target patent's cost (so 12 patents + a nearly-funded target beats
      12 patents flat).
    * `army` — the best single fleet's metric over the target, in [0, 1]
      ("a fleet", not the sum of every fleet).

  0.0 when the player is nil / has nothing.
  """
  def race_progress(%{mode: :race, race: %{system_income: thresholds}}, player) when is_map(player) do
    player
    |> Map.get(:stellar_systems, [])
    |> Enum.map(fn system ->
      thresholds
      |> Enum.map(fn {field, target} ->
        min(fetch_number(system, field) / target, 1.0)
      end)
      |> Enum.min()
    end)
    |> Enum.max(fn -> 0.0 end)
    |> Kernel./(1)
  end

  def race_progress(%{mode: :race, race: %{patent: patent_key} = spec}, player) when is_map(player) do
    patents = Map.get(player, :patents) || []

    if patent_key in patents do
      length(patents) / 1
    else
      banked =
        case Map.get(player, :technology) do
          %{value: value} when is_number(value) -> value
          _ -> 0
        end

      length(patents) + min(banked / Map.get(spec, :cost, 1.0e9), 0.999)
    end
  end

  def race_progress(%{mode: :race, race: %{army: spec}}, player) when is_map(player) do
    [{metric, target}] = Enum.to_list(spec)

    player
    |> Map.get(:characters, [])
    |> Enum.filter(fn c -> Map.get(c, :type) == :admiral and Map.get(c, :status) == :on_board end)
    |> Enum.map(fn c -> min((army_metric(c, metric) || 0) / target, 1.0) end)
    |> Enum.max(fn -> 0.0 end)
    |> Kernel./(1)
  end

  def race_progress(_, _), do: 0.0

  defp army_metric(character, :raid), do: Map.get(character, :army_raid)
  defp army_metric(character, :invasion), do: Map.get(character, :army_invasion)
  defp army_metric(character, :maintenance), do: Map.get(character, :army_maintenance)

  defp fetch_number(stats, field) do
    value = Map.get(stats, field) || Map.get(stats, Atom.to_string(field))
    if is_number(value), do: value, else: 0
  end
end
