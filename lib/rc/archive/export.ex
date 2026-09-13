defmodule RC.Archive.Export do
  @moduledoc """
  Spreadsheet export of one archived match, for players who want to do
  their own analysis. Everything comes from the archive tables (no snapshot
  or event re-reads), laid out long/tidy so it pivots and charts easily:

    * About — match facts, units and caveats
    * Factions — final standings + whole-match event totals
    * Faction days — one row per faction per day, one column per metric
    * Players — final per-player metrics
    * Player score by day
    * Unlocks — players per faction owning each patent / lex
    * Sectors / Systems — geometry, ownership per snapshot day, activity

  Metric keys are the archive's own (see `RC.Archive.SnapshotStats` and
  `RC.Archive.EventStats`) so exports from different matches line up.
  """

  alias RC.Archive.{Match, Xlsx}

  @content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  def content_type, do: @content_type

  def to_xlsx(%Match{} = match), do: match |> sheets() |> Xlsx.build()

  def filename(%Match{} = match) do
    slug =
      (match.name || "match")
      |> String.normalize(:nfd)
      |> String.replace(~r/[^A-Za-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.downcase()

    "legacy-archive-#{match.instance_id}-#{slug}.xlsx"
  end

  def sheets(%Match{} = match) do
    [
      {"About", about(match)},
      {"Factions", factions(match)},
      {"Faction days", faction_days(match)},
      {"Players", players(match)},
      {"Player score by day", player_series(match)},
      {"Unlocks", unlocks(match)},
      {"Sectors", sectors(match)},
      {"Systems", systems(match)}
    ]
  end

  # --- sheets --------------------------------------------------------------

  defp about(match) do
    summary = match.summary || %{}
    ut_per_hour = summary["ut_per_hour"] || 20

    [
      ["Field", "Value"],
      ["Match", match.name],
      ["Instance id", match.instance_id],
      ["Map", match.map_name],
      ["Speed", match.speed],
      ["Started (UTC)", iso(match.started_at)],
      ["Ended (UTC)", iso(match.ended_at)],
      ["Victory type", match.victory_type],
      ["Winner", match.winner_faction],
      ["Players", match.player_count],
      ["Systems", match.system_count],
      ["Days", summary["days"]],
      ["Distinct battles", summary["battle_count"]],
      ["Days with a snapshot", Enum.join(summary["sample_days"] || [], ", ")],
      ["Final snapshot taken after victory", summary["post_victory_final"] == true],
      ["Game units (ut) per real hour", ut_per_hour],
      ["Exported at (UTC)", iso(DateTime.utc_now())],
      [],
      ["Notes", ""],
      ["Days", "Day N covers the Nth 24 hours after the match started running (UTC)."],
      [
        "Units",
        "Income and per-system output metrics (*_net, *_gross, *_expense, *_src_*, *_avg_credit/technology/ideology, " <>
          "fleet_maintenance, ps_*_net) are per game unit (ut). Multiply by #{ut_per_hour} for per real hour."
      ],
      [
        "Snapshot metrics",
        "Metrics without a prefix below come from the daily snapshot (sampled_at) and are blank on days without one. " <>
          "sys_* = averages over a faction's player systems, dom_* = over its dominions."
      ],
      [
        "Event metrics",
        "*_attempts / *_success / *_suffered, battles, colonization come from match reports and cover every day. " <>
          "raid = Bombard, loot = Pillage, conquest = system capture, make_dominion = dominion capture, " <>
          "encourage_hate = Destabilization, conversion = Seduction."
      ],
      ["Battles", "battles counts each faction taking part, so a two-faction battle appears once per side."],
      ["Score metrics", "ps_* are sums of each player's last score-table row of the day."],
      ["Cybersecurity", "cybersecurity is the per-ut rate shown in game, not the internal progress counter."]
    ]
  end

  defp factions(match) do
    totals = get_in(match.summary || %{}, ["totals"]) || %{}
    total_keys = totals |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()
    base = ~w(key rank players victory_points systems dominions sectors)

    [base ++ Enum.map(total_keys, &"total_#{&1}")] ++
      Enum.map(match.factions || [], fn f ->
        Enum.map(base, &value(f[&1])) ++ Enum.map(total_keys, &value(get_in(totals, [f["key"], &1])))
      end)
  end

  defp faction_days(match) do
    keys = metric_keys(match.faction_days)

    [["day", "faction", "sampled_at"] ++ keys] ++
      (match.faction_days
       |> Enum.sort_by(&{&1.day, &1.faction})
       |> Enum.map(fn d -> [d.day, d.faction, iso(d.sampled_at)] ++ Enum.map(keys, &value(d.metrics[&1])) end))
  end

  defp players(match) do
    keys = metric_keys(match.players)

    [["player", "faction", "profile_id"] ++ keys] ++
      (match.players
       |> Enum.sort_by(&{&1.faction, &1.name})
       |> Enum.map(fn p -> [p.name, p.faction, p.profile_id] ++ Enum.map(keys, &value(p.metrics[&1])) end))
  end

  defp player_series(match) do
    [["player", "faction", "day", "points", "systems", "credit_net"]] ++
      (match.players
       |> Enum.sort_by(&{&1.faction, &1.name})
       |> Enum.flat_map(fn p ->
         Enum.map(p.series || [], fn [day, points, systems, credit] ->
           [p.name, p.faction, day, points, systems, credit]
         end)
       end))
  end

  defp unlocks(match) do
    [["kind", "key", "faction", "player_count", "first_day"]] ++
      (match.unlocks
       |> Enum.sort_by(&{&1.kind, &1.key, &1.faction})
       |> Enum.map(&[&1.kind, &1.key, &1.faction, &1.player_count, &1.first_day]))
  end

  defp sectors(match) do
    map = match.map || %{}
    days = map["days"] || []

    [["sector_id", "name", "victory_points"] ++ Enum.map(days, &"owner_day_#{&1["day"]}")] ++
      Enum.map(map["sectors"] || [], fn s ->
        [s["id"], s["name"], s["victory_points"]] ++
          Enum.map(days, fn d -> value(Map.get(d["sectors"] || %{}, to_string(s["id"]))) end)
      end)
  end

  @activity ~w(battles raid loot conquest make_dominion)

  defp systems(match) do
    map = match.map || %{}
    days = map["days"] || []
    faction_keys = map["faction_keys"] || []
    activity = get_in(match.summary || %{}, ["activity"]) || %{}

    header =
      ~w(system_id name x y sector_id type) ++
        Enum.map(@activity, &"#{&1}_events") ++ Enum.map(days, &"status_day_#{&1["day"]}")

    rows =
      (map["systems"] || [])
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        counts = Map.get(activity, to_string(s["id"]), %{})

        [s["id"], s["name"], s["x"], s["y"], s["sector_id"], s["type"]] ++
          Enum.map(@activity, &(counts[&1] || 0)) ++
          Enum.map(days, fn d -> status(Enum.at(d["systems"] || [], i), faction_keys) end)
      end)

    [header | rows]
  end

  # --- helpers -------------------------------------------------------------

  # Codes from RC.Archive.Importer.map_data/2.
  defp status(nil, _), do: nil
  defp status(0, _), do: "uninhabited"
  defp status(1, _), do: "neutral"

  defp status(code, faction_keys) when is_integer(code) do
    faction = Enum.at(faction_keys, div(code - 2, 2))
    kind = if rem(code, 2) == 0, do: "system", else: "dominion"
    "#{faction} #{kind}"
  end

  defp metric_keys(rows), do: rows |> Enum.flat_map(&Map.keys(&1.metrics || %{})) |> Enum.uniq() |> Enum.sort()

  defp value(v) when is_list(v), do: Enum.join(v, ", ")
  defp value(v) when is_map(v), do: Jason.encode!(v)
  defp value(v), do: v

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(%NaiveDateTime{} = dt), do: dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
end
