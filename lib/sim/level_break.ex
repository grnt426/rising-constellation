defmodule Sim.LevelBreak do
  @moduledoc """
  Finds "level breaks" — how much ship veterancy it takes to flip a matchup.

  Two views:

    * `type_matrix/2` — the clean, bounded one. For each pair of ship base-types
      (mono fleets), how many uniform levels does the *loser* need (winner held
      at base level) before it wins >50%? Directly answers "at what level do
      scouts beat interceptors?" Storage is the type x type grid (<=15x15).

    * `tide_turn_counters/3` — your simplified arena metric. Over a set of
      genome pairings (e.g. the Pareto front / Hall of Fame), for each pairing
      where fleet A loses, add +1 level to *every* ship in A and re-run; if that
      flips A to a >50% win, attribute the flip *fractionally* to A's ship types
      (a 60%-interceptor fleet credits 0.6 to interceptors). Enemy composition
      is intentionally ignored to keep the space bounded. The result is a
      `%{ship_type => weight}` map: high weight = "this type frequently sits one
      level under a cliff."
  """

  alias Sim.{Fleet, Arena, Genome}

  @doc """
  Level-break matrix over mono fleets of `types`. Returns a list of
  `%{a, b, base_winner, base_loser, base_winrate_a, break_level}` (one per
  unordered pair); `break_level` is the integer levels the loser needs, or
  `:none` if no flip within `:max_boost`.

  Opts: `:tiles`, `:battles` (30), `:base_level` (0), `:max_boost` (15).
  """
  def type_matrix(types, opts \\ []) do
    tiles = Keyword.get(opts, :tiles, Sim.Setup.tile_count())
    battles = Keyword.get(opts, :battles, 30)
    base_level = Keyword.get(opts, :base_level, 0)
    max_boost = Keyword.get(opts, :max_boost, 15)

    pairs = for a <- types, b <- types, a < b, do: {a, b}

    pairs
    |> Task.async_stream(
      fn {a, b} -> pair_break(a, b, tiles, battles, base_level, max_boost) end,
      max_concurrency: System.schedulers_online(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, r} -> r end)
  end

  defp pair_break(a, b, tiles, battles, base_level, max_boost) do
    fa = Fleet.mono(a, tiles, id: 1, level: base_level)
    fb = Fleet.mono(b, tiles, id: 2, level: base_level)
    base = Arena.matchup(fa, fb, n: battles, parallel: false)

    {loser, winner} = if base.attacker_win_rate >= 0.5, do: {b, a}, else: {a, b}

    %{
      a: a,
      b: b,
      base_winner: winner,
      base_loser: loser,
      base_winrate_a: base.attacker_win_rate,
      break_level: find_break(loser, winner, tiles, battles, base_level, max_boost)
    }
  end

  # Smallest +k on the loser (winner held at base) that wins it >50%.
  defp find_break(loser, winner, tiles, battles, base_level, max_boost) do
    fw = Fleet.mono(winner, tiles, id: 2, level: base_level)

    Enum.reduce_while(1..max_boost, :none, fn k, _acc ->
      fl = Fleet.mono(loser, tiles, id: 1, level: min(base_level + k, 15))
      m = Arena.matchup(fl, fw, n: battles, parallel: false)
      if m.attacker_win_rate > 0.5, do: {:halt, k}, else: {:cont, :none}
    end)
  end

  @doc """
  Fractional "+1 level turns the tide?" counters over `genome_pairs`
  (`[{genome_a, genome_b}]`) for `stage`. See the module doc. Opts: `:battles` (20).
  """
  def tide_turn_counters(genome_pairs, stage, opts \\ []) do
    battles = Keyword.get(opts, :battles, 20)

    genome_pairs
    |> Task.async_stream(
      fn {ga, gb} -> tide_one(ga, gb, stage, battles) end,
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, r} -> r end)
    |> Enum.reduce(%{}, fn contrib, acc -> Map.merge(acc, contrib, fn _k, v1, v2 -> v1 + v2 end) end)
  end

  defp tide_one(ga, gb, stage, battles) do
    fa = Fleet.from_genome(ga, stage, id: 1)
    fb = Fleet.from_genome(gb, stage, id: 2)
    base = Arena.matchup(fa, fb, n: battles, parallel: false)

    if base.attacker_win_rate < 0.5 do
      boosted = boosted_fleet(ga, stage, 1)
      flipped = Arena.matchup(boosted, fb, n: battles, parallel: false)
      if flipped.attacker_win_rate > 0.5, do: type_fractions(ga, stage), else: %{}
    else
      %{}
    end
  end

  # +1 level to every (non-empty) slot of a genome, rebuilt into a fleet.
  defp boosted_fleet(genome, stage, id) do
    slots = Enum.map(Genome.decode(genome, stage), fn {t, k, l} -> {t, k, min(l + 1, 15)} end)
    Fleet.build(slots, id: id)
  end

  # Fractional composition of a fleet by ship base-type (stack-size stripped).
  defp type_fractions(genome, stage) do
    slots = Genome.decode(genome, stage)
    total = length(slots)

    if total == 0 do
      %{}
    else
      slots
      |> Enum.map(fn {_t, key, _l} -> base_type(key) end)
      |> Enum.frequencies()
      |> Map.new(fn {type, count} -> {type, count / total} end)
    end
  end

  # Strip the stack-size suffix: :fighter_4v2 -> :fighter_4, :corvette_1 -> :corvette_1.
  defp base_type(key) do
    s = Atom.to_string(key)

    case Regex.run(~r/^(.*?)v\d+$/, s) do
      [_, base] -> String.to_existing_atom(base)
      _ -> key
    end
  end
end
