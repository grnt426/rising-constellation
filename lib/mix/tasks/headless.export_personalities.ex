defmodule Mix.Tasks.Headless.ExportPersonalities do
  @shortdoc "Export the strongest marathon champions as the bot personality pack"

  @moduledoc """
  Reads the marathon niche archives and writes `priv/bot_personalities.json`
  — the curated personality pack live bot-opponent games draw from
  (see RC.Bots). Ship the file by committing it; priv/ is included in
  releases, so the game server never depends on training artifacts.

      mix headless.export_personalities
      mix headless.export_personalities --archives tmp/marathon_night --top 5

  Selection: per faction, the top `--top` (default 5) archive niches by
  fitness, skipping injected seed_* reservoir entries (they're probes, not
  proven champions). Each entry carries a display name derived from its
  behavioral profile so the lobby can show "Shadow Operative" instead of a
  genome hash.

  DEPLOYMENT GATES ("plays like a real player", user spec 2026-07-07):
  training fitness is relative and permissive by design — the archive
  keeps turtles and degenerate winners as breeding stock and as balance
  signals. But a champion shipped against HUMANS must feel like a real
  opponent, so export requires, beyond basic viability (`games ≥ 2`,
  `opener_rate ≥ 0.9`):

    * at least one win, with `mean_win_vp ≥ 10` — its wins are scored
      wins, not clock-out attrition;
    * `mean_win_colonies > 1` — it takes more than one system on the way;
    * AGENT VARIETY ≥ 2 of the three classes (Navarch missions / Erased
      missions / Siderian missions), read from the usage telemetry — it
      plays the whole board, not one lever.

  Win-only means exist from 2026-07-07 archives onward (older entries
  fall back to stricter all-game means); usage exists from 2026-07-06.
  A degenerate-but-winning champion failing these gates stays in the
  archive — useful for seeding and balance work — it just never fronts
  a user-facing game.
  """

  use Mix.Task

  @factions ~w(tetrarchy myrmezir ark cardan synelle)

  @min_games 2
  @min_opener_rate 0.9
  @min_win_vp 10.0
  @min_win_colonies 1.0
  @min_agent_variety 2

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [archives: :string, top: :integer, out: :string])
    dir = Keyword.get(opts, :archives, "tmp/marathon_night")
    top = Keyword.get(opts, :top, 5)
    out = Keyword.get(opts, :out, "priv/bot_personalities.json")

    pack =
      Map.new(@factions, fn faction ->
        champions =
          case File.read(Path.join(dir, "archive_#{faction}.json")) do
            {:ok, json} ->
              json
              |> Jason.decode!()
              |> Enum.reject(fn {key, entry} ->
                String.starts_with?(key, "seed_") or not viable?(entry["stats"])
              end)
              |> Enum.sort_by(fn {_key, entry} -> -entry["fitness"] end)
              |> Enum.take(top)
              |> Enum.map(fn {key, entry} ->
                %{
                  name: personality_name(entry["stats"]),
                  niche: key,
                  fitness: Float.round(entry["fitness"] / 1, 1),
                  stats: entry["stats"],
                  genome: entry["genome"]
                }
              end)

            _ ->
              []
          end

        {faction, champions}
      end)

    empty = for {f, []} <- pack, do: f

    unless empty == [],
      do: Mix.shell().error("WARNING: no VIABLE champions for #{Enum.join(empty, ", ")} (live games fall back to Tunable.default())")

    File.write!(out, Jason.encode!(%{generated_at: System.system_time(:second), personalities: pack}, pretty: true))
    total = pack |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    Mix.shell().info("wrote #{out}: #{total} personalities across #{map_size(pack)} factions")
  end

  # "Plays like a real player" — factual behavior checks, not strategy
  # prescriptions. Degenerate winners stay archived; they just don't ship.
  defp viable?(stats) do
    Map.get(stats, "games", 0) >= @min_games and
      Map.get(stats, "wins", 0) >= 1 and
      Map.get(stats, "opener_rate", 1.0) >= @min_opener_rate and
      (Map.get(stats, "mean_win_vp") || Map.get(stats, "mean_vp", 0)) >= @min_win_vp and
      (Map.get(stats, "mean_win_colonies") || Map.get(stats, "colonies", 0)) > @min_win_colonies and
      agent_variety(Map.get(stats, "usage")) >= @min_agent_variety
  end

  # Distinct agent CLASSES exercised, from mission usage: Navarch
  # (colonization/raid/conquest), Erased (infiltrate/assassination),
  # Siderian (encourage_hate/make_dominion/conversion). No usage
  # telemetry -> unverifiable -> fails (pre-instrumentation entries).
  defp agent_variety(usage) when is_map(usage) do
    missions = Map.get(usage, "mission") || Map.get(usage, :mission) || %{}
    keys = missions |> Map.keys() |> Enum.map(&to_string/1)

    [
      ~w(colonization raid conquest),
      ~w(infiltrate assassination),
      ~w(encourage_hate make_dominion conversion)
    ]
    |> Enum.count(fn class -> Enum.any?(class, &(&1 in keys)) end)
  end

  defp agent_variety(_), do: 0

  # A readable archetype label from what the champion actually DID in its
  # evaluation games (mirrors the marathon's behavior-niche axes).
  defp personality_name(stats) do
    col = Map.get(stats, "colonies", 0)
    mil = Map.get(stats, "military", 0)
    cov = Map.get(stats, "covert", 0)
    flips = Map.get(stats, "dominion_flips", 0)

    cond do
      mil >= 2 and cov >= 10 -> "Shadow Warlord"
      mil >= 2 -> "Warlord"
      cov >= 40 and col >= 2 -> "Expansionist Spymaster"
      cov >= 40 -> "Shadow Operative"
      flips >= 1 and cov >= 10 -> "Propagandist"
      col >= 3 -> "Administrator"
      col >= 1 and cov >= 10 -> "Quiet Colonist"
      cov >= 10 -> "Whisper Agent"
      true -> "Generalist"
    end
  end
end
