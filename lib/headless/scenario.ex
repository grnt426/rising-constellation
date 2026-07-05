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
    n_sectors = Keyword.get(opts, :sectors, 4)
    per_sector = Keyword.get(opts, :systems_per_sector, 15)
    [f1, f2] = Keyword.get(opts, :factions, ["tetrarchy", "myrmezir"])
    vp_seed = Keyword.get(opts, :vp_seed, 1)

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

        owner =
          cond do
            i == 0 -> f1
            i == n_sectors - 1 -> f2
            true -> nil
          end

        # Deterministic per-(map,sector) VP variation in 1..3 — sectors are
        # not equally valuable, so bots must learn to value them.
        vp = rem(vp_seed * 7 + i * 5, 3) + 1

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
    |> Map.put("factions", [%{"key" => f1, "sector_number" => 1}, %{"key" => f2, "sector_number" => 1}])
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
    [f1, f2] = Keyword.get(opts, :factions, ["tetrarchy", "myrmezir"])
    vp_seed = Keyword.get(opts, :vp_seed, 1)

    eligible =
      case Enum.filter(raw["sectors"], fn s -> length(s["systems"]) >= 3 end) do
        sectors when length(sectors) >= 2 -> sectors
        _ -> Enum.sort_by(raw["sectors"], fn s -> -length(s["systems"]) end) |> Enum.take(2)
      end

    [home1, home2] = eligible |> Enum.take_random(2) |> Enum.map(& &1["key"])

    sectors =
      raw["sectors"]
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        faction =
          cond do
            s["key"] == home1 -> f1
            s["key"] == home2 -> f2
            true -> nil
          end

        systems = Enum.map(s["systems"], &Map.put(&1, "sector", s["key"]))

        s
        |> Map.delete("points03")
        |> Map.merge(%{
          "faction" => faction,
          "victory_points" => rem(vp_seed * 7 + i * 5, 3) + 1,
          "systems" => systems
        })
      end)

    fixture()
    |> Map.put("sectors", sectors)
    |> Map.put("systems", Enum.flat_map(sectors, & &1["systems"]))
    |> Map.put("size", raw["size"])
    |> Map.put("blackholes", raw["blackholes"] || [])
    |> Map.put("factions", [%{"key" => f1, "sector_number" => 1}, %{"key" => f2, "sector_number" => 1}])
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
end
