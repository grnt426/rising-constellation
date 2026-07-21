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
      new_fit = Headless.Fitness.score(signals(entry["stats"] || %{}))
      old_fit = entry["fitness"] || 0.0
      {Map.put(acc, bucket, Map.put(entry, "fitness", new_fit)), [new_fit - old_fit | deltas]}
    end)
  end

  # Build the Headless.Fitness signal map from an archive entry's STORED
  # aggregate stats (JSON string keys). cp75 economy, colonies, the 6
  # mechanic categories, and a soft (fractional) outcome from win rate +
  # mean duration.
  defp signals(stats) do
    cp = get_in(stats, ["checkpoints", "75"]) || get_in(stats, ["checkpoints", "50"]) || %{}
    mission = get_in(stats, ["usage", "mission"]) || %{}
    ships = get_in(stats, ["usage", "ship"]) || %{}
    games = max(stats["games"] || 1, 1)
    dur = stats["mean_duration_ut"] || 2400.0

    %{
      sys: cp["sys"] || (stats["colonies"] || 0),
      pop: cp["pop"] || 0,
      income: cp["income"] || 0,
      tech: cp["tech"] || 0,
      hoarded: cp["hoarded"] || 0,
      colonies: stats["colonies"] || 0,
      infiltrate: mission["infiltrate"] || 0,
      destabilize: mission["encourage_hate"] || 0,
      dominion: (mission["make_dominion"] || 0) + (stats["dominion_flips"] || 0),
      counter: (mission["assassination"] || 0) + (mission["conversion"] || 0),
      military: (stats["military"] || 0) + (ships |> Map.values() |> Enum.sum()),
      won: (stats["wins"] || 0) / games,
      my_vp: stats["mean_vp"] || 0,
      their_vp: stats["mean_their_vp"] || 0,
      ut_left: max(2400.0 - dur, 0.0)
    }
  end

  defp old_mean(a), do: mean(Enum.map(a, fn {_k, e} -> e["fitness"] || 0.0 end))
  defp new_mean(a), do: mean(Enum.map(a, fn {_k, e} -> e["fitness"] || 0.0 end))
  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
end
