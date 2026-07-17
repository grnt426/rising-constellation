# Standalone scaling sweep of Instance.Galaxy.SpatialGraph.generate_edges/2.
#
#   docker compose exec rc mix run profile_edges.exs
#
# Feeds the real Big One system positions (grid + the same ±0.5 jitter the
# instance pipeline applies) at increasing prefixes, so local density matches
# the real galaxy at every N. Sectors are contiguous in the JSON, so a prefix
# is a spatially-contiguous region, not a sparse subsample.

raw = Jason.decode!(File.read!(System.get_env("SCENARIO_JSON", "/data/bigone.json")))
gd = raw["game_data"]

:rand.seed(:exsss, {1, 2, 3})

systems =
  gd["sectors"]
  |> Enum.flat_map(fn sec -> sec["systems"] end)
  |> Enum.with_index(1)
  |> Enum.map(fn {s, i} ->
    %{
      id: i,
      position: %Spatial.Position{
        x: s["position"]["x"] + :rand.uniform() - 0.5,
        y: s["position"]["y"] + :rand.uniform() - 0.5
      }
    }
  end)

blackholes = Enum.map(gd["blackholes"], fn b -> Instance.Galaxy.Blackhole.new(b) end)

IO.puts("total systems: #{length(systems)}, blackholes: #{length(blackholes)}")

for frac <- [0.125, 0.25, 0.5, 1.0] do
  n = round(length(systems) * frac)
  subset = Enum.take(systems, n)

  {us, edges} = :timer.tc(fn -> Instance.Galaxy.SpatialGraph.generate_edges(subset, blackholes) end)
  IO.puts("N=#{n}: #{Float.round(us / 1_000_000, 2)} s, edges=#{length(edges)}")
end

# --- name-picker cost split: file re-read vs reservoir-sampling walk ---------

path = Path.join([:code.priv_dir(:rc), "data/name/", "place.txt"])

{us, names} =
  :timer.tc(fn ->
    Enum.reduce(1..200, nil, fn _, _ -> path |> File.stream!() |> Enum.to_list() end)
  end)

IO.puts("place.txt File.stream!|>to_list: #{Float.round(us / 1000 / 200, 3)} ms/call (#{length(names)} lines)")

rstate = :rand.seed_s(:exsss, {7, 7, 7})

{us, _} =
  :timer.tc(fn ->
    Enum.reduce(1..200, rstate, fn _, rs ->
      {rs2, _picked} = REnum.take_random(rs, names, 1)
      rs2
    end)
  end)

IO.puts("REnum.take_random(names, 1) walk: #{Float.round(us / 1000 / 200, 3)} ms/call")

{us, _} =
  :timer.tc(fn ->
    Enum.reduce(1..10_000, rstate, fn _, rs ->
      {idx, rs2} = :rand.uniform_s(length(names), rs)
      _ = Enum.at(names, idx - 1)
      rs2
    end)
  end)

IO.puts("uniform-index pick (cached list): #{Float.round(us / 1000 / 10_000, 4)} ms/call")
