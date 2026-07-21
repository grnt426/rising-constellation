defmodule Mix.Tasks.Headless.Rescore do
  @shortdoc "Re-score niche archives under the current Headless.Fitness formula"

  @moduledoc """
  A fitness-formula change re-rulers every archived champion: old entries
  carry fitness from the OLD scalar, new marathon evals score under the new
  one, and the niche archive's best-per-bucket comparison mixes the two
  incoherently until the archive turns over. This recomputes each entry's
  fitness from its STORED aggregate stats (colonies, cp75 economy, mission
  usage, duration, VP) via the same `Headless.Fitness.score/1` the live
  path uses, and writes the archives back — so three weeks of lineages
  carry over onto the new ruler instead of being wiped.

  Run with the MARATHON STOPPED (it saves archives at iteration end and
  would clobber concurrent writes):

      mix headless.rescore --out tmp/marathon_night

  Aggregate stats are means across an eval's games, so the re-scored value
  is an approximation of the live mean-of-per-game-fitness (breadth/timeout
  are non-linear). That is fine: it puts old champions on the new scale so
  they compete fairly with fresh evals, and each bucket re-ranks correctly.
  """

  use Mix.Task

  @factions ~w(tetrarchy myrmezir ark cardan synelle)

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])
    out = Keyword.get(opts, :out, "tmp/marathon_night")

    Mix.Task.run("app.start")

    for faction <- @factions do
      path = Path.join(out, "archive_#{faction}.json")

      case File.read(path) do
        {:ok, json} ->
          archive = Jason.decode!(json)
          {rescored, deltas} = rescore_archive(archive)
          File.write!(path, Jason.encode!(rescored))

          mean_delta = if deltas == [], do: 0.0, else: Enum.sum(deltas) / length(deltas)

          Mix.shell().info(
            "#{faction}: #{map_size(archive)} niches re-scored · " <>
              "mean fitness #{round(old_mean(archive))} -> #{round(new_mean(rescored))} (Δ#{round(mean_delta)})"
          )

        _ ->
          Mix.shell().info("#{faction}: no archive")
      end
    end
  end

  defp rescore_archive(archive) do
    Enum.reduce(archive, {%{}, []}, fn {bucket, entry}, {acc, deltas} ->
      new_fit = Headless.Fitness.score(Headless.Fitness.signals_from_stats(entry["stats"] || %{}))
      old_fit = entry["fitness"] || 0.0
      {Map.put(acc, bucket, Map.put(entry, "fitness", new_fit)), [new_fit - old_fit | deltas]}
    end)
  end

  defp old_mean(a), do: mean(Enum.map(a, fn {_k, e} -> e["fitness"] || 0.0 end))
  defp new_mean(a), do: mean(Enum.map(a, fn {_k, e} -> e["fitness"] || 0.0 end))
  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
end
