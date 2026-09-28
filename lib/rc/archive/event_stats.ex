defmodule RC.Archive.EventStats do
  @moduledoc """
  Day-bucketed per-faction activity counts for an archived match, read from
  the permanent DB tables (unlike snapshots, these never age out):

    * `player_events` box rows — one row per involved player per resolved
      action, `data.side` = attacker/defender. Attacker rows count what a
      faction DID, defender rows what it SUFFERED. `fight` rows carry no
      side, one per participating player, so battles are de-duplicated on
      (system, timestamp).
    * `player_stats` — every player's points/net income/systems roughly
      every 15 real minutes; the last row per player per day is kept.

  Everything after `ended_at` (the victory row) is ignored: the post-victory
  grace period keeps producing events that aren't part of the match.

  Day N covers `[started_at + (N-1)·24h, started_at + N·24h)`.

  ## Metric keys (per faction per day)

    * `<action>_attempts`, `<action>_success` — attacker rows; action is one
      of `raid` (UI Bombard), `loot` (Pillage), `conquest` (system capture),
      `make_dominion` (dominion capture), `infiltration`, `sabotage`,
      `assassination`, `encourage_hate` (Destabilize), `conversion` (Seduce)
    * `<action>_suffered` — successful actions against this faction
    * `conquest_from_enemy` — captured systems that belonged to another faction
    * `colonization` — completed colonizations
    * `battles`, `battles_won`
    * `ps_points`, `ps_credit_net`, `ps_technology_net`, `ps_ideology_net`,
      `ps_credit_stock`, `ps_systems`, `ps_population` — player_stats sums
  """

  import Ecto.Query, warn: false

  alias RC.Repo

  @actions ~w(raid loot conquest make_dominion infiltration sabotage assassination encourage_hate conversion)
  @box_keys ["fight", "colonization" | @actions]

  def actions, do: @actions

  @doc """
  `registrations` maps registration id → faction key (string).

  Returns `%{days: %{{faction, day} => metrics}, players: %{reg_id => metrics},
  series: %{reg_id => [[day, points, systems, credit_net]]},
  activity: %{system_id => %{kind => count}}}`.
  """
  def collect(instance_id, started_at, ended_at, registrations) do
    events = box_events(instance_id, ended_at)
    stats = player_stats(instance_id, ended_at)
    day = &day_of(&1, started_at)

    {action_days, action_players} = action_counts(events, registrations, day)
    {battle_days, battle_players, battle_activity, battle_count} = battle_counts(events, registrations, day)
    {ps_days, ps_players, series} = stats_counts(stats, registrations, day)

    %{
      # Distinct battles — per-faction `battles` counts each side separately.
      battle_count: battle_count,
      days: merge_all([action_days, battle_days, ps_days]),
      players: merge_all([action_players, battle_players, ps_players]),
      series: series,
      activity: merge_activity(action_activity(events), battle_activity)
    }
  end

  def day_of(%DateTime{} = ts, started_at), do: max(1, div(DateTime.diff(ts, started_at, :second), 86_400) + 1)
  def day_of(%NaiveDateTime{} = ts, started_at), do: ts |> DateTime.from_naive!("Etc/UTC") |> day_of(started_at)

  # --- queries -------------------------------------------------------------

  defp box_events(instance_id, ended_at) do
    # `data` is a text column holding full admiral/army payloads; let
    # Postgres parse it and ship back only the few fields we need.
    from(e in "player_events",
      where:
        e.instance_id == ^instance_id and e.type == "box" and e.key in ^@box_keys and
          e.inserted_at <= ^naive(ended_at),
      select: %{
        key: e.key,
        registration_id: e.registration_id,
        inserted_at: e.inserted_at,
        side: fragment("?::jsonb->>'side'", e.data),
        outcome: fragment("?::jsonb->>'outcome'", e.data),
        system_id: fragment("(?::jsonb#>>'{system,id}')::bigint", e.data),
        system_owner: fragment("?::jsonb#>>'{system,owner,faction}'", e.data)
      }
    )
    |> Repo.all()
  end

  defp player_stats(instance_id, ended_at) do
    from(s in "player_stats",
      where: s.instance_id == ^instance_id and s.inserted_at <= ^naive(ended_at),
      order_by: [asc: s.inserted_at],
      select: %{
        registration_id: s.registration_id,
        inserted_at: s.inserted_at,
        points: s.points,
        credit_net: s.output_credit,
        technology_net: s.output_technology,
        ideology_net: s.output_ideology,
        credit_stock: s.stored_credit,
        systems: s.total_systems,
        population: s.total_population
      }
    )
    |> Repo.all()
  end

  # --- aggregation ---------------------------------------------------------

  defp action_counts(events, registrations, day) do
    rows =
      events
      |> Enum.filter(&(&1.key in @actions or &1.key == "colonization"))
      |> Enum.flat_map(fn e ->
        faction = Map.get(registrations, e.registration_id)
        success? = success?(e.outcome)

        metrics =
          cond do
            faction == nil ->
              []

            e.key == "colonization" ->
              ["colonization"]

            e.side == "attacker" ->
              ["#{e.key}_attempts"] ++
                if(success?, do: ["#{e.key}_success"], else: []) ++
                if(success? and e.key == "conquest" and e.system_owner not in [nil, faction],
                  do: ["conquest_from_enemy"],
                  else: []
                )

            # The defender's copy carries the outcome from ITS point of view.
            e.side == "defender" and not success? ->
              ["#{e.key}_suffered"]

            true ->
              []
          end

        Enum.map(metrics, &{faction, day.(e.inserted_at), e.registration_id, &1})
      end)

    days = count_by(rows, fn {f, d, _, m} -> {{f, d}, m} end)
    players = count_by(rows, fn {_, _, r, m} -> {r, m} end)
    {days, players}
  end

  defp battle_counts(events, registrations, day) do
    battles =
      events
      |> Enum.filter(&(&1.key == "fight"))
      |> Enum.group_by(&{&1.system_id, &1.inserted_at})

    rows =
      Enum.flat_map(battles, fn {{_sid, ts}, rows} ->
        rows
        |> Enum.group_by(&Map.get(registrations, &1.registration_id))
        |> Enum.reject(fn {faction, _} -> is_nil(faction) end)
        |> Enum.flat_map(fn {faction, f_rows} ->
          won? = Enum.any?(f_rows, &(&1.outcome == "victory"))
          d = day.(ts)
          [{faction, d, nil, "battles"}] ++ if(won?, do: [{faction, d, nil, "battles_won"}], else: [])
        end)
      end)

    player_rows =
      events
      |> Enum.filter(&(&1.key == "fight" and Map.has_key?(registrations, &1.registration_id)))
      |> Enum.flat_map(fn e ->
        [{e.registration_id, "battles"}] ++
          if(e.outcome == "victory", do: [{e.registration_id, "battles_won"}], else: [])
      end)

    activity =
      battles
      |> Map.keys()
      |> Enum.reject(fn {sid, _} -> is_nil(sid) end)
      |> Enum.reduce(%{}, fn {sid, _}, acc -> bump(acc, sid, "battles") end)

    count = Enum.count(battles, fn {_, rows} -> Enum.any?(rows, &Map.has_key?(registrations, &1.registration_id)) end)

    {count_by(rows, fn {f, d, _, m} -> {{f, d}, m} end), count_by(player_rows, & &1), activity, count}
  end

  defp action_activity(events) do
    events
    |> Enum.filter(&(&1.side == "attacker" and &1.key in ~w(raid loot conquest make_dominion) and &1.system_id))
    |> Enum.reduce(%{}, fn e, acc -> bump(acc, e.system_id, e.key) end)
  end

  defp stats_counts(stats, registrations, day) do
    # Last row per registration per day.
    last =
      stats
      |> Enum.filter(&Map.has_key?(registrations, &1.registration_id))
      |> Enum.reduce(%{}, fn s, acc -> Map.put(acc, {s.registration_id, day.(s.inserted_at)}, s) end)

    fields = ~w(points credit_net technology_net ideology_net credit_stock systems population)a

    days =
      Enum.reduce(last, %{}, fn {{reg, d}, s}, acc ->
        key = {Map.fetch!(registrations, reg), d}

        sums =
          Map.new(fields, fn f -> {"ps_#{f}", Map.fetch!(s, f)} end)
          |> Map.put("ps_players", 1)

        Map.update(acc, key, sums, &Map.merge(&1, sums, fn _, a, b -> a + b end))
      end)

    series =
      last
      |> Enum.group_by(fn {{reg, _}, _} -> reg end, fn {{_, d}, s} -> [d, s.points, s.systems, s.credit_net] end)
      |> Map.new(fn {reg, rows} -> {reg, Enum.sort(rows)} end)

    players =
      stats
      |> Enum.filter(&Map.has_key?(registrations, &1.registration_id))
      |> Enum.reduce(%{}, fn s, acc ->
        Map.put(acc, s.registration_id, Map.new(fields, fn f -> {"final_#{f}", Map.fetch!(s, f)} end))
      end)

    {days, players, series}
  end

  # --- helpers -------------------------------------------------------------

  defp success?(outcome) when is_binary(outcome), do: String.ends_with?(outcome, "success")
  defp success?(_), do: false

  defp count_by(rows, fun) do
    Enum.reduce(rows, %{}, fn row, acc ->
      {key, metric} = fun.(row)
      Map.update(acc, key, %{metric => 1}, &Map.update(&1, metric, 1, fn n -> n + 1 end))
    end)
  end

  defp bump(acc, sid, kind), do: Map.update(acc, sid, %{kind => 1}, &Map.update(&1, kind, 1, fn n -> n + 1 end))

  defp merge_all(maps), do: Enum.reduce(maps, %{}, &Map.merge(&2, &1, fn _, a, b -> Map.merge(a, b) end))

  defp merge_activity(a, b), do: Map.merge(a, b, fn _, x, y -> Map.merge(x, y) end)

  defp naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp naive(%NaiveDateTime{} = dt), do: dt
end
