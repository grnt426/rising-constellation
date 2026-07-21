defmodule Daily.Generator do
  @moduledoc """
  Turns a calendar date into a complete `game_data` map for a daily
  challenge: one procedurally-generated star system, one sector, one
  faction (the solo player), no opponents or neutrals.

  Everything is derived deterministically from the date, so every player who
  opens the same day's challenge solves the *identical* system with the
  *identical* mutators — that's what makes the leaderboard fair. The output
  is the same string-keyed shape the normal galaxy generator consumes (see
  `Instance.Manager.init_from_model/4` and
  test/support/scenario_game_data.json), so a daily reuses the entire
  economy/tick engine unchanged.

  Two layers of seeding are involved and should not be confused:

    * the date → a SHA-256 digest, consumed here to pick the system
      archetype, the objective and the mutator set (the *shape* of the day).
    * the in-game `"seed"` (3 ints, also derived from the digest) feeds
      `:rand.seed(:exrop, …)` inside the engine, which fills in the system's
      bodies, tiles and resource factors deterministically.

  The daily runs in its own `:daily` speed (see `Data.Game.Speed`): it
  inherits the `:slow` "Legacy" content set (building upgrades, the fuller
  patent/lex roster) — every speed-branching Data module falls back to its
  slow spec for `:daily` — but carries a fast tick factor so a 30-minute
  session covers a meaningful economic arc. `:daily` is `selectable: false`,
  so the scenario editor's speed picker never offers it; only generated
  dailies use it.
  """

  alias Data.Game.Mutator

  # Star types the seed map uses (see priv/repo/seeds_data/map_game_data.json).
  @archetypes ~w(yellow_dwarf orange_dwarf red_dwarf white_dwarf)
  @sector_names ~w(Vael Korrin Ossuar Tessella Nubrae Halcyon Drava Mireth Selith Auran)
  # The day's solo faction — picked deterministically so everyone plays the
  # same one (its starting agent + traditions shape the optimal line). Keys
  # mirror Data.Game.Faction.Content; the fixed order keeps a given date's
  # pick stable even if the catalog is later reordered.
  @factions ~w(tetrarchy myrmezir cardan synelle ark)

  # The daily's own speed: Legacy (:slow) content + a fast tick factor,
  # hidden from the scenario editor. See Data.Game.Speed{,.Content}.
  @speed "daily"
  @mode "prod"
  # 30-minute session — the design default within its 10–45 min window.
  @time_limit_minutes 30
  @galaxy_size 120
  @center 60
  # Radius of the circle sector-day systems sit on, around the sector centre.
  # Well under half the spatial adjacency threshold (Galaxy.SpatialGraph
  # @max_dist 12), so every pair of systems gets a direct hyperlane.
  @sector_radius 5
  # Far above any reachable score, so victory-by-points never fires; the
  # daily ends on its time limit instead (the "Daily Complete" freeze is a
  # later milestone — for now the instance simply runs to the deadline).
  @victory_points 999_999

  @doc """
  Build the `game_data` map for `date` (a `Date` or an ISO-8601 string).

  Options:

    * `:include_unimplemented` — when true, the mutator roll may pick
      catalog entries whose engine effect isn't wired yet (useful for
      previewing the full roadmap). Defaults to false, so a generated daily
      only ever uses mutators that actually do something.
  """
  def for_date(date, opts \\ [])
  def for_date(%Date{} = date, opts), do: for_date(Date.to_iso8601(date), opts)

  def for_date(date_iso, opts) when is_binary(date_iso) do
    bytes = digest_bytes(date_iso)
    include_unimplemented = Keyword.get(opts, :include_unimplemented, false)

    archetype = pick(@archetypes, at(bytes, 6))
    sector_name = pick(@sector_names, at(bytes, 11))
    objective = pick(Daily.Objective.keys(), at(bytes, 7))
    faction = pick(@factions, at(bytes, 12))

    # Package days (The Bequest, ...): the objective pins its own mutator set
    # — the scripted setup IS the day's identity — instead of the usual roll
    # of 2 boons + 1 bane.
    mutator_keys =
      case Map.get(Daily.Objective.get(objective), :package_mutators) do
        pins when is_list(pins) and pins != [] ->
          pins

        _ ->
          {positives, negative} = pick_mutators(bytes, include_unimplemented)
          positives ++ [negative]
      end

    # A sector-day objective carries a `:sector` spec; otherwise the day is the
    # classic lone home system.
    sector_spec = Map.get(Daily.Objective.get(objective), :sector)
    systems = build_systems(archetype, sector_spec)

    %{
      "blackholes" => [],
      "date" => 4000,
      "factions" => [%{"key" => faction, "sector_number" => 1}],
      "mode" => @mode,
      "sectors" => [build_sector(faction, sector_name, systems, sector_spec)],
      "seed" => ingame_seed(bytes),
      "size" => @galaxy_size,
      "speed" => @speed,
      "systems" => Enum.map(systems, &Map.delete(&1, "sector")),
      "time_limit" => @time_limit_minutes,
      "victory_points" => @victory_points,
      "game_mode_type" => "daily",
      "mutators" => Enum.map(mutator_keys, fn key -> %{"key" => Atom.to_string(key)} end),
      "daily" => %{
        "date" => date_iso,
        "objective" => Atom.to_string(objective),
        "archetype" => archetype,
        "faction" => faction
      }
    }
  end

  @doc """
  Lightweight metadata mirror (for instance listing / filtering), derived
  from a generated `game_data`. Mirrors the `game_metadata` convention the
  scenario editor uses for mutators.
  """
  def metadata_for(game_data) do
    %{
      "speed" => game_data["speed"],
      "mutators" => game_data["mutators"],
      "daily" => true,
      "objective" => get_in(game_data, ["daily", "objective"])
    }
  end

  # --- deterministic helpers ------------------------------------------------

  # 32 deterministic bytes from the date. The version prefix lets us
  # intentionally reshuffle every daily in future without colliding with old
  # ones (bump "v1").
  defp digest_bytes(date_iso) do
    :crypto.hash(:sha256, "tetrarchy-daily:v1:" <> date_iso) |> :binary.bin_to_list()
  end

  defp at(bytes, index), do: Enum.at(bytes, index)

  defp pick(list, byte), do: Enum.at(list, rem(byte, length(list)))

  # Three positive integers for :rand.seed(:exrop, {a, b, c}).
  defp ingame_seed(bytes), do: [int16(bytes, 0), int16(bytes, 2), int16(bytes, 4)]
  defp int16(bytes, offset), do: at(bytes, offset) * 256 + at(bytes, offset + 1) + 1

  # Roll two distinct boons and one bane, without replacement. The bane may
  # never share an `axis` with a rolled boon: a day that both boosts and
  # nerfs the same lever (say, tech income) reads as having nothing
  # interesting to offer. Same-polarity stacking stays legal — contradiction
  # is filtered, not synergy. (Objective-vs-mutator collisions are NOT
  # filtered; a rare bane on the scored resource is a deliberately hard day.)
  defp pick_mutators(bytes, include_unimplemented) do
    positives = mutator_pool(:positive, include_unimplemented)
    negatives = mutator_pool(:negative, include_unimplemented)

    {p1, rest} = take(positives, at(bytes, 8))
    {p2, _} = take(rest, at(bytes, 9))

    boon_axes = [Map.get(p1, :axis), Map.get(p2, :axis)]
    eligible_negatives = Enum.reject(negatives, &(Map.get(&1, :axis) in boon_axes))
    # Safety net only — with banes spread across many axes the filtered pool
    # can't empty today, but a future catalog shouldn't crash the daily.
    eligible_negatives = if eligible_negatives == [], do: negatives, else: eligible_negatives

    {n1, _} = take(eligible_negatives, at(bytes, 10))

    {[p1.key, p2.key], n1.key}
  end

  defp mutator_pool(polarity, true), do: Mutator.daily_by_polarity(polarity)

  defp mutator_pool(polarity, false) do
    Enum.filter(Mutator.daily_by_polarity(polarity), & &1.implemented)
  end

  defp take(list, byte) do
    index = rem(byte, length(list))
    {Enum.at(list, index), List.delete_at(list, index)}
  end

  # A small square sector polygon centred on the systems. Geometry is cosmetic
  # for a single-sector daily (there's no neighbouring sector to zoom out to,
  # and edges are spatial, not polygon-bound) but the engine still expects a
  # closed boundary. The 20×20 box comfortably contains the @sector_radius
  # cluster.
  defp sector_points do
    [[50, 50], [70, 50], [70, 70], [50, 70], [50, 50]]
  end

  # --- system / sector layout ----------------------------------------------

  # The day's systems. Default is the lone home system at the sector centre; a
  # sector-day objective emits `systems` count systems in a small circular
  # cluster. Every system is the day's archetype, keyed 1..count.
  defp build_systems(archetype, nil) do
    [%{"key" => 1, "position" => %{"x" => @center, "y" => @center}, "sector" => 0, "type" => archetype}]
  end

  defp build_systems(archetype, %{systems: count}) when is_integer(count) and count >= 1 do
    for i <- 1..count do
      %{"key" => i, "position" => system_position(i, count), "sector" => 0, "type" => archetype}
    end
  end

  # Evenly spaced on a small circle around the sector centre. The layout is
  # fixed (not seed-derived), so every player of the date gets the same map;
  # the per-system ±0.5 spawn jitter still hides the exact geometry in-game.
  defp system_position(_i, 1), do: %{"x" => @center, "y" => @center}

  defp system_position(i, count) do
    angle = 2 * :math.pi() * (i - 1) / count
    %{
      "x" => Float.round(@center + @sector_radius * :math.cos(angle), 2),
      "y" => Float.round(@center + @sector_radius * :math.sin(angle), 2)
    }
  end

  defp build_sector(faction, sector_name, systems, sector_spec) do
    base = %{
      "area" => 400,
      "centroid" => [@center * 1.0, @center * 1.0],
      "faction" => faction,
      "key" => 0,
      "name" => sector_name,
      # Per-sector victory-point value. The engine's Victory tracker sums this
      # across sectors (Instance.Victory.Victory.update_tracks/1), so it must
      # be a number — a missing value crashes the victory agent. The daily
      # ends on its time limit (time_only victory), not points, so it's
      # nominal even when the player owns every system.
      "victory_points" => 1,
      "points" => sector_points(),
      "systems" => systems
    }

    case neutral_override(sector_spec) do
      nil -> base
      override -> Map.put(base, "neutral", override)
    end
  end

  # Force the non-home systems to the objective's NPC status via the engine's
  # "fixed" neutral distribution (Instance.Manager.compute_neutral_overrides/1
  # sorts a sector's systems by key, forces the first floor(count × ratio) to
  # :inhabited_neutral and the rest to :uninhabited):
  #
  #   * :uninhabited — ratio 0, so every system is uninhabited; the seeded
  #     home pick (Galaxy.get_initial_system) lands on one of them and the
  #     rest are colonization targets.
  #   * :neutral — ratio just over (count-1)/count, so exactly one system (the
  #     highest key) stays uninhabited to become the deterministic home, and
  #     the rest are neutral to conquer or vassalize.
  #
  # Every daily system is guaranteed habitable (StellarSystem.new's daily
  # ensure_habitable_planet), so the forced status always takes.
  defp neutral_override(nil), do: nil
  defp neutral_override(%{npc: :uninhabited}), do: %{"mode" => "fixed", "ratio" => 0.0}

  defp neutral_override(%{systems: count, npc: :neutral}) when is_integer(count) and count >= 2 do
    %{"mode" => "fixed", "ratio" => (count - 0.5) / count}
  end
end
