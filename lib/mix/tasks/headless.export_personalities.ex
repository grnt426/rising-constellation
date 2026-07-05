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

  DEPLOYMENT GATES (game-ai-v2.md §V2.1): training fitness is relative and
  permissive by design — the archive keeps turtles as breeding stock. But
  a champion shipped against humans must be able to speak the game's
  verbs, so export requires ABSOLUTE viability: `games ≥ 2`, mean
  `colonies ≥ 1`, `mean_vp ≥ 6`, `opener_rate ≥ 0.9` (absent in pre-V2.1
  archives → passes; the colonies gate carries). These are factual "can
  play" checks, not strategy prescriptions — covert specialists and
  dominion-rushers pass. The shipped `colonies: 0.0` Generalist does not.
  """

  use Mix.Task

  @factions ~w(tetrarchy myrmezir ark cardan synelle)

  @min_games 2
  @min_colonies 1.0
  @min_vp 6.0
  @min_opener_rate 0.9

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

  # "Can it speak the game's verbs" — absolute facts, not strategy.
  defp viable?(stats) do
    Map.get(stats, "games", 0) >= @min_games and
      Map.get(stats, "colonies", 0) >= @min_colonies and
      Map.get(stats, "mean_vp", 0) >= @min_vp and
      Map.get(stats, "opener_rate", 1.0) >= @min_opener_rate
  end

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
