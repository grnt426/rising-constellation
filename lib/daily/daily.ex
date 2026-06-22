defmodule Daily do
  @moduledoc """
  Entry points for the daily challenge.

  A *daily* is a single procedurally-generated star system, seeded from the
  calendar date, that every player solves independently. The leaderboard
  ranks players by the day's `Daily.Objective`. Because the system and
  mutators are fully determined by the date, every player faces the same
  puzzle — only their decisions differ.

  This module assembles the day's *definition* (pure, deterministic) and the
  scenario attrs needed to stand one up. Actually spawning a per-player
  instance and persisting the leaderboard is the next milestone; the boot
  chain it will use is:

      attrs = Daily.to_scenario_attrs(Daily.definition_for(Date.utc_today()))
      {:ok, %{scenario: scenario}} = RC.Scenarios.create_scenario(attrs, :reuse_thumbnail)
      {:ok, %{instance: instance}} =
        RC.Instances.create_instance(instance_attrs, scenario, account_id)
      Instance.Manager.create_from_model(instance)

  with `instance_attrs` carrying a single faction (`%{"key" => "tetrarchy",
  "capacity" => 1}`) and `public: false` so the daily never shows in the
  public lobby. See docs/daily-challenge.md for the full plan.
  """

  alias Daily.{Generator, Objective}
  alias Data.Game.Mutator

  import Ecto.Query, only: [from: 2]

  @doc """
  The full, human-friendly definition of the daily for `date` (a `Date` or
  an ISO-8601 string): the raw `game_data`, its metadata mirror, the resolved
  objective and mutator records, and the system archetype.
  """
  def definition_for(date) do
    iso = to_iso(date)
    game_data = Generator.for_date(iso)

    %{
      date: iso,
      game_data: game_data,
      game_metadata: Generator.metadata_for(game_data),
      objective: Objective.get(game_data["daily"]["objective"]),
      mutators: Enum.map(game_data["mutators"], fn %{"key" => key} -> Mutator.get(key) end),
      archetype: game_data["daily"]["archetype"],
      faction: game_data["daily"]["faction"]
    }
  end

  @doc """
  Scenario attrs for a daily definition, ready for `RC.Scenarios.create_scenario/2`.
  """
  def to_scenario_attrs(%{game_data: game_data, game_metadata: game_metadata}) do
    %{
      game_data: game_data,
      game_metadata: game_metadata,
      is_official: true,
      is_map: false
    }
  end

  @doc """
  Record a player's `score` for `date`, keeping the best across attempts
  (upsert on profile + date). `objective` and `instance_id` are stored for
  context. Returns `{:ok, _}` (`:kept_best` when an existing score was higher).
  """
  def record_score(profile_id, date, objective, score, instance_id) do
    attrs = %{
      profile_id: profile_id,
      date: date,
      objective: to_string(objective),
      score: score / 1,
      instance_id: instance_id
    }

    case RC.Repo.get_by(Daily.Entry, profile_id: profile_id, date: date) do
      nil ->
        %Daily.Entry{} |> Daily.Entry.changeset(attrs) |> RC.Repo.insert()

      %Daily.Entry{score: existing} = entry when score > existing ->
        entry |> Daily.Entry.changeset(attrs) |> RC.Repo.update()

      _existing_is_better ->
        {:ok, :kept_best}
    end
  end

  @doc """
  The ranked leaderboard for `date`: the top `limit` scores, highest first
  (ties broken by who reached the score first). Each row is
  `%{rank, name, score, objective}`.
  """
  def leaderboard(date, limit \\ 50) do
    from(e in Daily.Entry,
      join: p in RC.Accounts.Profile,
      on: p.id == e.profile_id,
      where: e.date == ^date,
      order_by: [desc: e.score, asc: e.updated_at],
      limit: ^limit,
      select: %{name: p.name, score: e.score, objective: e.objective}
    )
    |> RC.Repo.all()
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} -> Map.put(row, :rank, rank) end)
  end

  @doc """
  A single player's best score + rank for `date`, or nil if they haven't
  played it. Rank = (number of strictly higher scores) + 1.
  """
  def player_rank(profile_id, date) do
    case RC.Repo.get_by(Daily.Entry, profile_id: profile_id, date: date) do
      nil ->
        nil

      entry ->
        ahead =
          RC.Repo.one(
            from(e in Daily.Entry,
              where: e.date == ^date and e.score > ^entry.score,
              select: count(e.id)
            )
          )

        %{score: entry.score, rank: ahead + 1}
    end
  end

  defp to_iso(%Date{} = date), do: Date.to_iso8601(date)
  defp to_iso(date) when is_binary(date), do: date
end
