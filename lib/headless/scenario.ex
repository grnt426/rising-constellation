defmodule Headless.Scenario do
  @moduledoc """
  Scenario `game_data` sources for headless runs.

  The default is the checked-in test fixture (269 systems, 2 factions, Fast
  speed) — the same galaxy the memory baseline work profiled, so results are
  comparable. `fixture/1` accepts overrides for quick variants (shorter
  `"time_limit"`, different `"seed"`, …). Dev-only: reads from `test/support`,
  which exists in the repo checkout but not in a prod release.
  """

  @fixture_path "test/support/scenario_game_data.json"

  @doc """
  The standard Fast test galaxy, with optional key overrides, e.g.
  `Headless.Scenario.fixture(%{"time_limit" => 10})` for a 10-minute game.
  """
  def fixture(overrides \\ %{}) do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(overrides)
  end

  @doc "Faction keys declared by a scenario, in order."
  def faction_keys(game_data) do
    Enum.map(game_data["factions"], & &1["key"])
  end

  @doc """
  A synthesized multi-sector training map, built from the fixture's system
  pool re-bucketed into N vertical bands. Spawn sectors sit at the two ends
  (owned by the given factions); middle bands are NEUTRAL buffers with their
  own (varied) sector victory points — sector adjacency is computed by the
  engine from the band polygons (bands overlap by 1 unit so SAT collision
  connects neighbors in a chain). This teaches bots sector valuation, buffer
  crossing, and neutral-zone play.

  Options: `:factions` (two keys, default ~w(tetrarchy myrmezir)),
  `:sectors` (bands, default 4), `:systems_per_sector` (default 15),
  `:vp_seed` (varies per-sector victory points), `:time_limit`,
  `:victory_points` (win threshold).
  """
  def generate(opts \\ []) do
    base = fixture()
    faction_keys = Keyword.get(opts, :factions, ["tetrarchy", "myrmezir"])
    nf = length(faction_keys)
    # Need at least one band per team so every faction gets a distinct home.
    n_sectors = max(Keyword.get(opts, :sectors, 4), nf)
    per_sector = Keyword.get(opts, :systems_per_sector, 15)
    vp_seed = Keyword.get(opts, :vp_seed, 1)

    # Spawn bands evenly spaced across the chain: 2 teams at the ends, 3
    # teams at ends + middle, etc. band_index => faction_key.
    spawn_of =
      for(j <- 0..(nf - 1), do: {(if nf == 1, do: 0, else: round(j * (n_sectors - 1) / (nf - 1))), Enum.at(faction_keys, j)})
      |> Map.new()

    pool = Enum.flat_map(base["sectors"], & &1["systems"])
    {min_x, max_x} = pool |> Enum.map(& &1["position"]["x"]) |> Enum.min_max()
    band_w = (max_x - min_x) / n_sectors

    sectors =
      for i <- 0..(n_sectors - 1) do
        lo = min_x + i * band_w
        hi = lo + band_w

        systems =
          pool
          |> Enum.filter(fn s -> s["position"]["x"] >= lo and s["position"]["x"] < hi + 0.001 end
          )
          |> Enum.sort_by(fn s -> abs(s["position"]["x"] - (lo + hi) / 2) end)
          |> Enum.take(per_sector)
          |> Enum.map(&Map.put(&1, "sector", i))

        owner = Map.get(spawn_of, i)

        # CENTER-WEIGHTED VP (user map-realism model 2026-07-08): central
        # sectors are the most-contested ground and carry the highest
        # reward; spawn bands are always worth 1 (you already hold them).
        # Teaches bots that pushing to the center is where the game is won,
        # not turtling at a low-value home.
        vp = if owner, do: 1, else: band_vp(i, n_sectors, vp_seed)

        %{
          "key" => i,
          "name" => "Band-#{i}",
          "faction" => owner,
          "victory_points" => vp,
          "centroid" => [(lo + hi) / 2, 60.0],
          "area" => band_w * 120.0,
          # Rectangle with ±1 overlap so neighboring bands register adjacent.
          "points" => [[lo - 1, -10], [hi + 1, -10], [hi + 1, 130], [lo - 1, 130]],
          "systems" => systems
        }
      end

    all_systems = Enum.flat_map(sectors, & &1["systems"])

    base
    |> Map.put("sectors", sectors)
    |> Map.put("systems", all_systems)
    |> Map.put("factions", Enum.map(faction_keys, &%{"key" => &1, "sector_number" => 1}))
    |> Map.put("time_limit", Keyword.get(opts, :time_limit, 120))
    |> Map.put("victory_points", Keyword.get(opts, :victory_points, 14))
  end

  @map_pool_dir "tmp/map_pool"

  @doc """
  Production maps available for training (JSON exports of `scenarios` rows
  with `is_map: true`, pulled from prod — see docs/headless-runner.md).
  Empty when the pool directory doesn't exist.
  """
  def pool_maps do
    case File.ls(@map_pool_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.join(@map_pool_dir, &1))
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc """
  Build a playable Fast game_data from a PRODUCTION MAP export (pure
  geometry: sectors/systems/blackholes/size). Adds the scenario layer the
  instance pipeline expects: two spawn sectors get faction ownership
  (random distinct pair among sectors with enough systems — real maps have
  varied topologies, so random pairs vary the contact distance), every
  sector gets seeded victory points, systems get their sector key, and the
  fixture's Fast settings (speed/mode/date) come along as the base.

  Options: `:factions` (two keys), `:vp_seed`, `:time_limit` (default 120),
  `:victory_points` (default 14 — the real game's threshold).
  """
  def from_map(path, opts \\ []) do
    raw = path |> File.read!() |> Jason.decode!()
    factions = Keyword.get(opts, :factions, ["tetrarchy", "myrmezir"])
    n = length(factions)
    vp_seed = Keyword.get(opts, :vp_seed, 1)

    # N distinct spawn sectors (one per faction/team). Prefer sectors with
    # enough systems; if a small map can't field N, fall back to its N
    # biggest sectors so team formats still boot.
    eligible =
      case Enum.filter(raw["sectors"], fn s -> length(s["systems"]) >= 3 end) do
        sectors when length(sectors) >= n -> sectors
        _ -> Enum.sort_by(raw["sectors"], fn s -> -length(s["systems"]) end) |> Enum.take(n)
      end

    homes = eligible |> Enum.take_random(n) |> Enum.map(& &1["key"])
    faction_of = Map.new(Enum.zip(homes, factions))

    max_sector_systems =
      raw["sectors"] |> Enum.map(&length(&1["systems"])) |> Enum.max(fn -> 1 end) |> max(1)

    sectors =
      raw["sectors"]
      |> Enum.map(fn s ->
        systems = Enum.map(s["systems"], &Map.put(&1, "sector", s["key"]))

        # Center-weighted VP by contention proxy: spawn sectors are low
        # value (you already own them); interior sectors scale with SIZE
        # (bigger sector = more systems to fight over = higher reward).
        # Real central sectors on production maps are typically the large,
        # well-connected ones, so size is a cheap stand-in for centrality
        # without recomputing adjacency.
        vp =
          if Map.has_key?(faction_of, s["key"]),
            do: 1,
            else: size_vp(length(s["systems"]), max_sector_systems)

        s
        |> Map.delete("points03")
        |> Map.merge(%{
          "faction" => Map.get(faction_of, s["key"]),
          "victory_points" => vp,
          "systems" => systems
        })
      end)

    fixture()
    |> Map.put("sectors", sectors)
    |> Map.put("systems", Enum.flat_map(sectors, & &1["systems"]))
    |> Map.put("size", raw["size"])
    |> Map.put("blackholes", raw["blackholes"] || [])
    |> Map.put("factions", Enum.map(factions, &%{"key" => &1, "sector_number" => 1}))
    |> Map.put("time_limit", Keyword.get(opts, :time_limit, 120))
    |> Map.put("victory_points", Keyword.get(opts, :victory_points, 14))
  end

  @doc """
  A small training-scale galaxy: the standard fixture downsampled to
  `systems_per_sector` systems per sector (default 25 → 50 total across the
  fixture's two faction-owned sectors). Keeps the systems nearest each
  sector's centroid so the play area stays coherent; sector ownership,
  factions, seed, and speed are untouched. System bodies/tiles are generated
  at instance boot from the seed, so the descriptors here are all that's
  needed.
  """
  def small(opts \\ []) do
    per_sector = Keyword.get(opts, :systems_per_sector, 25)
    game_data = fixture()

    sectors =
      Enum.map(game_data["sectors"], fn sector ->
        [cx, cy] = sector["centroid"]

        systems =
          sector["systems"]
          |> Enum.sort_by(fn s ->
            dx = s["position"]["x"] - cx
            dy = s["position"]["y"] - cy
            dx * dx + dy * dy
          end)
          |> Enum.take(per_sector)

        Map.put(sector, "systems", systems)
      end)

    kept_keys = MapSet.new(Enum.flat_map(sectors, fn s -> Enum.map(s["systems"], & &1["key"]) end))

    game_data
    |> Map.put("sectors", sectors)
    |> Map.put("systems", Enum.filter(game_data["systems"], &MapSet.member?(kept_keys, &1["key"])))
  end

  # --- sector VP weighting ---------------------------------------------------

  # Synthetic linear bands: centrality from the middle index. Edge/spawn
  # bands ~1-2, the central band up to ~6. `+ jitter` (0..1) breaks
  # mirror-band ties so the two halves aren't identical.
  defp band_vp(i, n_sectors, vp_seed) do
    mid = (n_sectors - 1) / 2
    centrality = if mid == 0, do: 0.0, else: 1.0 - abs(i - mid) / mid
    jitter = rem(vp_seed * 7 + i * 5, 2)
    1 + round(centrality * 4) + jitter
  end

  # Production maps: VP scales with sector size relative to the map's
  # biggest sector — big interior sectors are the contested prizes. Range
  # 2..6 so even the smallest non-spawn sector is worth more than a home.
  defp size_vp(sector_systems, max_sector_systems) do
    2 + round(4 * sector_systems / max_sector_systems)
  end
end
