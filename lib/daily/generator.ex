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

  # The daily's own speed: Legacy (:slow) content + a fast tick factor,
  # hidden from the scenario editor. See Data.Game.Speed{,.Content}.
  @speed "daily"
  @mode "prod"
  @time_limit_minutes 30
  @galaxy_size 120
  @center 60
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
    {positives, negative} = pick_mutators(bytes, include_unimplemented)
    mutator_keys = positives ++ [negative]

    system = %{
      "key" => 1,
      "position" => %{"x" => @center, "y" => @center},
      "sector" => 0,
      "type" => archetype
    }

    %{
      "blackholes" => [],
      "date" => 4000,
      "factions" => [%{"key" => "tetrarchy", "sector_number" => 1}],
      "mode" => @mode,
      "sectors" => [
        %{
          "area" => 400,
          "centroid" => [@center * 1.0, @center * 1.0],
          "faction" => "tetrarchy",
          "key" => 0,
          "name" => sector_name,
          # Per-sector victory-point value. The engine's Victory tracker sums
          # this across sectors (Instance.Victory.Victory.update_tracks/1), so
          # it must be a number — a missing value crashes the victory agent.
          # The daily ends on its time limit, not points, so the value is
          # nominal.
          "victory_points" => 1,
          "points" => sector_points(),
          "systems" => [system]
        }
      ],
      "seed" => ingame_seed(bytes),
      "size" => @galaxy_size,
      "speed" => @speed,
      "systems" => [Map.delete(system, "sector")],
      "time_limit" => @time_limit_minutes,
      "victory_points" => @victory_points,
      "game_mode_type" => "daily",
      "mutators" => Enum.map(mutator_keys, fn key -> %{"key" => Atom.to_string(key)} end),
      "daily" => %{
        "date" => date_iso,
        "objective" => Atom.to_string(objective),
        "archetype" => archetype
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

  # Roll two distinct boons and one bane, without replacement.
  defp pick_mutators(bytes, include_unimplemented) do
    positives = mutator_pool(:positive, include_unimplemented)
    negatives = mutator_pool(:negative, include_unimplemented)

    {p1, rest} = take(positives, at(bytes, 8))
    {p2, _} = take(rest, at(bytes, 9))
    {n1, _} = take(negatives, at(bytes, 10))

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

  # A small square sector polygon centred on the lone system. The geometry
  # is cosmetic for a one-system galaxy (there's nothing to zoom out to) but
  # the engine still expects a closed boundary.
  defp sector_points do
    [[50, 50], [70, 50], [70, 70], [50, 70], [50, 50]]
  end
end
