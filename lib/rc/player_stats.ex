defmodule RC.PlayerStats do
  alias RC.Repo
  alias RC.Instances.PlayerStat

  @doc """
  Creates a player_stat.
  """
  def create_player_stat(attrs \\ %{}) do
    %PlayerStat{}
    |> PlayerStat.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets all last player stat given an instance_id.
  Returns a map row per registered player covering ONLY the fields
  the in-game `RankingPanel.vue` displays — `total_systems`,
  `total_population`, `points`, and the four `best_*` aggregates.

  Stage 8 F1 fix. The previous SELECT projected `output_credit`,
  `output_technology`, `output_ideology`, and `stored_credit` per
  player and shipped them via the GlobalChannel `get_stats` reply to
  every authenticated joiner — but the UI renders none of those
  columns (repo-wide grep across `front/` for any of the four returns
  zero hits). The wire therefore exposed every rival's exact bank
  balance and exact per-tick resource accrual rate, letting a wire
  reader time market bids, predict bankruptcy, and detect patent /
  doctrine purchases via accrual dips. The admin-facing
  `get_players_stats_by_instance_id/2` still projects the full set
  for `charts_live.ex`, which is the correct surface for those
  values.
  """
  def get_last_player_stat_by_instance_id(instance_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT
          profiles.id AS player_id,
          profiles.name AS player_name,
          factions.faction_ref AS faction,
          player_stats.total_systems,
          player_stats.total_population,
          player_stats.points,
          player_stats.best_prod,
          player_stats.best_credit,
          player_stats.best_technology,
          player_stats.best_ideology,
          player_stats.best_workforce
        FROM
          (SELECT
            MAX(id) AS id,
            registration_id,
            MAX(inserted_at) AS inserted_at
          FROM player_stats
          GROUP BY registration_id) AS latest_stats
        INNER JOIN player_stats
        ON player_stats.id = latest_stats.id
          AND player_stats.inserted_at = latest_stats.inserted_at
        INNER JOIN registrations
        ON registrations.id = player_stats.registration_id
        INNER JOIN profiles
        ON profiles.id = registrations.profile_id
        INNER JOIN factions
        ON factions.id = registrations.faction_id
        WHERE player_stats.instance_id = $1",
        [instance_id]
      )

    Enum.map(result.rows, fn row ->
      Enum.reduce(Enum.with_index(row), %{}, fn {value, index}, acc ->
        Map.put(acc, Enum.at(result.columns, index), value)
      end)
    end)
  end

  @doc """
  Gets players stats given an instance_id.
  Returns a map of registration_id => stats[]
  """
  def get_players_stats_by_instance_id(instance_id, registration_ids) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT
          registrations.id AS registration_id,
          profiles.name AS player_name,
          player_stats.inserted_at,
          player_stats.output_credit,
          player_stats.output_credit,
          player_stats.output_technology,
          player_stats.output_ideology
        FROM player_stats
        INNER JOIN registrations
          ON registrations.id = player_stats.registration_id
        INNER JOIN profiles
          ON profiles.id = registrations.profile_id
        WHERE player_stats.instance_id = $1
          AND player_stats.registration_id = ANY($2)
        ORDER BY player_stats.inserted_at",
        [instance_id, registration_ids]
      )

    Enum.map(result.rows, fn row ->
      Enum.reduce(Enum.with_index(row), %{}, fn {value, index}, acc ->
        Map.put(acc, Enum.at(result.columns, index), value)
      end)
    end)
    |> Enum.group_by(& &1["registration_id"])
    |> Enum.reduce(%{}, fn {registration_id, stats}, acc ->
      dates_list = Enum.map(stats, & &1["inserted_at"])
      credit = Enum.map(stats, & &1["output_credit"])
      ideology = Enum.map(stats, & &1["output_ideology"])
      technology = Enum.map(stats, & &1["output_technology"])

      Map.put(acc, registration_id, %{
        name: List.first(Enum.map(stats, & &1["player_name"])),
        dates: dates_list,
        credit: credit,
        ideology: ideology,
        technology: technology
      })
    end)
  end
end
