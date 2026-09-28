defmodule RC.Archive.Importer do
  @moduledoc """
  Builds (or rebuilds) the archive of one finished match.

  Inputs are a list of snapshot file paths — typically the newest snapshot
  of each nightly S3 tarball plus whatever end-of-game snapshots still exist
  (see `deploy/bin/rc-archive-import`) — and the permanent DB tables read by
  `RC.Archive.EventStats`. Snapshots are optional: a match whose tarballs
  aged out still gets event/player_stats series, just no snapshot metrics.

  Sample selection, per match day (see `EventStats.day_of/2`):

    * the latest snapshot taken at or before the victory is that day's
      sample — the grace period after victory is not part of the match;
    * if the last day has no pre-victory snapshot, the earliest post-victory
      one stands in (flagged `post_victory_final` in `summary`) — older
      matches only kept autosaves from the grace period.

  Re-running replaces the previous archive of the instance but keeps its
  `published` flag unless `published:` is passed.
  """

  import Ecto.Query, warn: false
  require Logger

  alias RC.Repo
  alias RC.Archive.{EventStats, FactionDay, Match, Player, SnapshotStats, Unlock}

  # Real ms per ut is 180_000 / speed factor (lib/game/core/tick.ex).
  @speed_factor %{"slow" => 1, "medium" => 20, "fast" => 120}

  def run(instance_id, paths, opts \\ []) do
    instance = load_instance!(instance_id)
    factions = load_factions(instance_id)
    registrations = load_registrations(instance_id)
    started_at = started_at(instance_id, instance)
    {ended_at, victory_type} = ended_at!(instance_id, opts)
    last_day = EventStats.day_of(ended_at, started_at)
    faction_keys = Enum.map(factions, & &1.key)

    picks = select_samples(paths, instance_id, started_at, ended_at, last_day)
    log("instance #{instance_id}: #{last_day} days, #{map_size(picks)} snapshot samples from #{length(paths)} files")

    samples =
      picks
      |> Enum.sort()
      |> Enum.map(fn {day, pick} ->
        log("  day #{day}: #{Path.basename(pick.path)}#{if pick.post_victory, do: " (post-victory)", else: ""}")
        Map.merge(pick, %{day: day, stats: extract_file(pick.path)})
      end)

    reg_faction = Map.new(registrations, &{&1.id, &1.faction})
    events = EventStats.collect(instance_id, started_at, ended_at, reg_faction)

    final = List.last(samples)

    attrs = %{
      instance_id: instance_id,
      name: instance.name,
      map_name: get_in(instance.game_metadata || %{}, ["name"]),
      speed: speed(instance),
      started_at: started_at,
      ended_at: ended_at,
      victory_type: victory_type,
      winner_faction: winner(factions, victory_type),
      player_count: length(registrations),
      system_count:
        (final && length(final.stats.galaxy.systems)) || get_in(instance.game_metadata || %{}, ["system_number"]) || 0,
      factions: faction_summaries(factions, registrations, final),
      summary: summary(instance, samples, events, faction_keys, last_day),
      map: map_data(samples, faction_keys),
      source: %{
        files:
          Enum.map(
            samples,
            &%{day: &1.day, file: Path.basename(&1.path), sampled_at: &1.ts, post_victory: &1.post_victory}
          ),
        imported_at: DateTime.utc_now()
      }
    }

    days = faction_day_rows(samples, events, faction_keys, last_day)
    players = player_rows(registrations, final, events)
    unlocks = unlock_rows(samples)

    persist(attrs, days, players, unlocks, opts)
  end

  # --- sources -------------------------------------------------------------

  defp load_instance!(instance_id) do
    from(i in "instances",
      where: i.id == ^instance_id,
      select: %{
        name: i.name,
        game_metadata: i.game_metadata,
        game_data: i.game_data,
        state: i.state,
        opening_date: i.opening_date,
        inserted_at: i.inserted_at
      }
    )
    |> Repo.one()
    |> case do
      nil -> raise ArgumentError, "instance #{instance_id} not found"
      instance -> instance
    end
  end

  defp load_factions(instance_id) do
    from(f in "factions",
      where: f.instance_id == ^instance_id,
      order_by: [asc_nulls_last: f.final_rank, asc: f.id],
      select: %{id: f.id, key: f.faction_ref, rank: f.final_rank}
    )
    |> Repo.all()
  end

  defp load_registrations(instance_id) do
    from(r in "registrations",
      join: f in "factions",
      on: f.id == r.faction_id,
      join: p in "profiles",
      on: p.id == r.profile_id,
      where: f.instance_id == ^instance_id,
      select: %{id: r.id, faction: f.faction_ref, profile_id: p.id, name: p.name}
    )
    |> Repo.all()
  end

  # The instance starts ticking at its first "running" state, which can be
  # hours after opening_date (registration window).
  defp started_at(instance_id, instance) do
    from(s in "instance_states",
      where: s.instance_id == ^instance_id and s.state == "running",
      order_by: [asc: s.inserted_at],
      limit: 1,
      select: s.inserted_at
    )
    |> Repo.one()
    |> case do
      nil -> utc(instance.opening_date || instance.inserted_at)
      running_at -> utc(running_at)
    end
  end

  defp ended_at!(instance_id, opts) do
    victory =
      from(v in "victories", where: v.instance_id == ^instance_id, select: %{at: v.inserted_at, type: v.victory_type})
      |> Repo.one()

    cond do
      victory -> {utc(victory.at), victory.type}
      opts[:ended_at] -> {utc(opts[:ended_at]), nil}
      true -> raise ArgumentError, "instance #{instance_id} has no victory row — pass ended_at: to archive it anyway"
    end
  end

  defp speed(instance) do
    get_in(instance.game_data || %{}, ["speed"]) || get_in(instance.game_metadata || %{}, ["speed"]) || "slow"
  end

  defp winner(_factions, nil), do: nil

  defp winner(factions, _type) do
    case Enum.find(factions, &(&1.rank == 1)) do
      nil -> nil
      f -> f.key
    end
  end

  # --- snapshots -----------------------------------------------------------

  @doc false
  def select_samples(paths, instance_id, started_at, ended_at, last_day) do
    files =
      paths
      |> Enum.flat_map(fn path ->
        case parse_snapshot_name(Path.basename(path)) do
          {^instance_id, ts} -> [%{path: path, ts: ts}]
          _ -> []
        end
      end)
      |> Enum.filter(&(DateTime.compare(&1.ts, started_at) != :lt))
      |> Enum.uniq_by(&Path.basename(&1.path))

    {pre, post} = Enum.split_with(files, &(DateTime.compare(&1.ts, ended_at) != :gt))

    picks =
      pre
      |> Enum.group_by(&EventStats.day_of(&1.ts, started_at))
      |> Map.new(fn {day, fs} ->
        {min(day, last_day), fs |> Enum.max_by(&DateTime.to_unix(&1.ts)) |> Map.put(:post_victory, false)}
      end)

    if Map.has_key?(picks, last_day) or post == [] do
      picks
    else
      Map.put(picks, last_day, post |> Enum.min_by(&DateTime.to_unix(&1.ts)) |> Map.put(:post_victory, true))
    end
  end

  @doc "Every file under `dir` (recursively) named like a snapshot of `instance_id`."
  def snapshot_paths(dir, instance_id) do
    dir
    |> Path.join("**/*snapshot-#{instance_id}-*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  # snapshot-<iid>-<unix seconds><4 random digits>, optionally prefixed.
  @doc false
  def parse_snapshot_name(name) do
    case Regex.run(~r/snapshot-(\d+)-(\d{10})\d*$/, name) do
      [_, iid, unix] -> {String.to_integer(iid), DateTime.from_unix!(String.to_integer(unix) * 1_000_000, :microsecond)}
      _ -> nil
    end
  end

  # Decoding a 12-25MB snapshot balloons the heap; doing it in a throwaway
  # process hands only the small extract back and frees the rest at once.
  defp extract_file(path) do
    fn -> path |> File.read!() |> SnapshotStats.decode() |> SnapshotStats.extract() end
    |> Task.async()
    |> Task.await(:infinity)
  end

  # --- rows ----------------------------------------------------------------

  defp faction_day_rows(samples, events, faction_keys, last_day) do
    by_day = Map.new(samples, &{&1.day, &1})
    zero_events = zero_event_metrics()

    for day <- 1..last_day, faction <- faction_keys do
      sample = Map.get(by_day, day)
      snap = (sample && Map.get(sample.stats.factions, faction)) || %{}
      ev = Map.get(events.days, {faction, day}, %{})

      %{
        faction: faction,
        day: day,
        sampled_at: sample && sample.ts,
        metrics: zero_events |> Map.merge(ev) |> Map.merge(snap)
      }
    end
  end

  defp zero_event_metrics do
    action_keys =
      Enum.flat_map(EventStats.actions(), fn a -> ["#{a}_attempts", "#{a}_success", "#{a}_suffered"] end)

    Map.new(action_keys ++ ~w(conquest_from_enemy colonization battles battles_won), &{&1, 0})
  end

  defp player_rows(registrations, final, events) do
    snap_players = if final, do: final.stats.players, else: []

    Enum.map(registrations, fn reg ->
      snap =
        Enum.find(snap_players, &(&1.registration_id == reg.id)) ||
          Enum.find(snap_players, &(&1.id == reg.profile_id))

      metrics =
        ((snap && snap.metrics) || %{})
        |> Map.merge(Map.get(events.players, reg.id, %{}))

      %{
        profile_id: reg.profile_id,
        name: (snap && snap.name) || reg.name,
        faction: reg.faction,
        metrics: metrics,
        series: Map.get(events.series, reg.id, [])
      }
    end)
  end

  defp unlock_rows([]), do: []

  defp unlock_rows(samples) do
    final = List.last(samples)

    for {kind, keys} <- final.stats.unlocks, {key, per_faction} <- keys, {faction, count} <- per_faction do
      first_day =
        Enum.find_value(samples, fn s ->
          if get_in(s.stats.unlocks, [kind, key, faction]), do: s.day
        end)

      %{kind: kind, key: key, faction: faction, player_count: count, first_day: first_day}
    end
  end

  defp faction_summaries(factions, registrations, final) do
    Enum.map(factions, fn f ->
      m = (final && Map.get(final.stats.factions, f.key)) || %{}

      %{
        key: f.key,
        rank: f.rank,
        players: Enum.count(registrations, &(&1.faction == f.key)),
        victory_points: m["victory_points"],
        systems: m["systems"],
        dominions: m["dominions"],
        sectors: m["sectors"]
      }
    end)
  end

  defp summary(instance, samples, events, faction_keys, last_day) do
    totals =
      Map.new(faction_keys, fn f ->
        sums =
          Enum.reduce(1..last_day, zero_event_metrics(), fn day, acc ->
            events.days
            |> Map.get({f, day}, %{})
            |> Map.drop(Enum.filter(Map.keys(Map.get(events.days, {f, day}, %{})), &String.starts_with?(&1, "ps_")))
            |> Map.merge(acc, fn _, a, b -> a + b end)
          end)

        {f, sums}
      end)

    speed = speed(instance)

    %{
      days: last_day,
      sample_days: Enum.map(samples, & &1.day),
      post_victory_final: match?([_ | _], samples) and List.last(samples).post_victory,
      ut_per_hour: 20 * Map.get(@speed_factor, speed, 1),
      totals: totals,
      battle_count: events.battle_count,
      activity: events.activity
    }
  end

  # Ownership codes per system (in `galaxy.systems` order) per sample day:
  # 0 uninhabited, 1 neutral, 2 + 2i player system, 3 + 2i dominion, where
  # i is the faction's index in `faction_keys`.
  defp map_data([], faction_keys), do: %{faction_keys: faction_keys, days: []}

  defp map_data(samples, faction_keys) do
    galaxy = List.last(samples).stats.galaxy
    index = faction_keys |> Enum.with_index() |> Map.new()

    days =
      Enum.map(samples, fn s ->
        %{
          day: s.day,
          sectors: Map.new(s.stats.sector_owners, fn {id, owner} -> {id, owner} end),
          systems:
            Enum.map(galaxy.systems, fn sys ->
              case Map.get(s.stats.system_codes, sys.id) do
                {f, "player"} when is_map_key(index, f) -> 2 + 2 * index[f]
                {f, "dominion"} when is_map_key(index, f) -> 3 + 2 * index[f]
                {_, "neutral"} -> 1
                _ -> 0
              end
            end)
        }
      end)

    Map.merge(galaxy, %{faction_keys: faction_keys, days: days})
  end

  # --- persistence ---------------------------------------------------------

  defp persist(attrs, days, players, unlocks, opts) do
    Repo.transaction(
      fn ->
        existing = Repo.get_by(Match, instance_id: attrs.instance_id)
        published = Keyword.get(opts, :published, (existing && existing.published) || false)
        if existing, do: Repo.delete!(existing)

        # Re-imports keep the match id so shared archive links stay valid.
        attrs = attrs |> Map.put(:published, published) |> Map.put(:id, existing && existing.id)
        match = Repo.insert!(struct(Match, attrs))

        insert_children(FactionDay, match.id, days)
        insert_children(Player, match.id, players)
        insert_children(Unlock, match.id, unlocks)

        log(
          "archived instance #{attrs.instance_id} as match #{match.id}: #{length(days)} faction-days, #{length(players)} players, #{length(unlocks)} unlocks (published: #{published})"
        )

        match
      end,
      timeout: :infinity
    )
  end

  defp insert_children(schema, match_id, rows) do
    rows
    |> Enum.map(&Map.put(&1, :match_id, match_id))
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(schema, &1))
  end

  # utc_datetime_usec columns insist on microsecond precision.
  defp utc(%NaiveDateTime{} = dt), do: dt |> DateTime.from_naive!("Etc/UTC") |> utc()
  defp utc(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp log(msg) do
    Logger.info("[archive] " <> msg)
    IO.puts("[archive] " <> msg)
  end
end
