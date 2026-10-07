defmodule Wave.Doctrine do
  @moduledoc """
  The Rebellion's own fleet designs.

  The library (`Wave.Blueprints`) holds what players built. The Rebellion does
  not field those as they are: a design it takes from the library is fuzzed
  first, a few hulls swapped for others of their class (or of the class next
  to it) and a few tiles exchanged, and that variant becomes one of its **identities**. It keeps a
  small book of them per role and builds its fleets from the book, so the
  players meet the same few fleets again and have to learn what beats them.

  Once a day the book is reviewed against what its fleets did:

    * an identity that won most of what it was in is kept and fuzzed again,
      lightly, so it drifts while it keeps winning;
    * one that lost most of it takes a strike, and is replaced from the
      library only after more strikes than the forgiveness allows;
    * one with too few results to judge stays as it is, unless the library has
      moved on (see `review/3`).

  A result is a win or a loss: a fight won, or a pillage, bombardment or
  invasion that succeeded, against a fight lost or fled or an action that
  failed (`outcome/1`).

  Pure. The Warlord keeps the book and supplies the dice.
  """

  @wins [:victorious, :normal_success, :critical_success, :success]
  @losses [:dead, :fleeing, :normal_failure, :critical_failure, :failure]

  @doc "What an engine outcome counts as for the fleet's design: `:win`, `:loss` or nil."
  def outcome(result) when result in @wins, do: :win
  def outcome(result) when result in @losses, do: :loss
  def outcome(_result), do: nil

  @doc """
  A new identity: the library design `base`, fuzzed. `id` names the lineage and
  stays with it through every later fuzz.
  """
  def new(base, id, now, alternatives, rolls, swaps, moves) do
    %{
      id: id,
      base: base.id,
      generation: 1,
      slots: fuzz(base.slots, alternatives, rolls, swaps, moves),
      stance: base.stance,
      born: now,
      wins: 0,
      losses: 0,
      total_wins: 0,
      total_losses: 0,
      strikes: 0
    }
  end

  # Classes a hull may cross into when its own class offers nothing else.
  @class_order [:fighter, :corvette, :frigate]

  @doc """
  The hulls that can stand in for each hull, among `allowed` (base stacks
  only): the other hulls of its class, or, while the players have unlocked
  only one hull of that class, the hulls of the class next to it. Capital
  ships only ever trade places with other capitals, and Carriers and colony
  ships neither leave a design nor enter one. `ships` is the catalog as
  `%{key => ship}`.
  """
  def alternatives(ships, allowed) when is_map(ships) do
    merged = for {_key, ship} <- ships, ship.merge_to != nil, into: MapSet.new(), do: ship.merge_to

    hulls =
      for {key, ship} <- ships,
          not MapSet.member?(merged, key),
          ship.class != :transport,
          key in allowed,
          do: ship

    Map.new(hulls, fn ship ->
      same = for other <- hulls, other.class == ship.class, other.key != ship.key, do: other.key
      {ship.key, Enum.sort(if(same == [], do: neighbours(ship, hulls), else: same))}
    end)
  end

  defp neighbours(ship, hulls) do
    case Enum.find_index(@class_order, &(&1 == ship.class)) do
      nil ->
        []

      index ->
        for other <- hulls, abs((Enum.find_index(@class_order, &(&1 == other.class)) || 99) - index) == 1, do: other.key
    end
  end

  @doc """
  Fuzz a layout (`[{tile, hull}]`): `swaps` times, one tile's hull becomes
  one of its stand-ins (`alternatives/2`); `moves` times, two tiles holding different hulls
  exchange them. `rolls` are numbers in 0..1, two per operation; the fuzz
  stops when they run out. Tiles are never added or removed.
  """
  def fuzz(slots, alternatives, rolls, swaps, moves) when is_list(slots) and is_list(rolls) do
    {slots, rolls} = repeat(Enum.sort(slots), rolls, swaps, &swap(&1, alternatives, &2, &3))
    {slots, _rolls} = repeat(slots, rolls, moves, &move/3)
    slots
  end

  defp repeat(slots, [a, b | rest], n, op) when n > 0, do: repeat(op.(slots, a, b), rest, n - 1, op)
  defp repeat(slots, rolls, _n, _op), do: {slots, rolls}

  defp swap(slots, alternatives, a, b) do
    case Enum.filter(slots, fn {_tile, hull} -> Map.get(alternatives, hull, []) != [] end) do
      [] ->
        slots

      open ->
        {tile, hull} = pick(open, a)
        put(slots, tile, pick(Map.fetch!(alternatives, hull), b))
    end
  end

  defp move(slots, a, b) do
    {tile, hull} = pick(slots, a)

    case Enum.filter(slots, fn {_other, other_hull} -> other_hull != hull end) do
      [] ->
        slots

      others ->
        {other, other_hull} = pick(others, b)
        slots |> put(tile, other_hull) |> put(other, hull)
    end
  end

  defp pick(list, roll), do: Enum.at(list, min(trunc(min(max(roll, 0.0), 1.0) * length(list)), length(list) - 1))

  defp put(slots, tile, hull), do: Enum.map(slots, fn {t, h} -> if t == tile, do: {t, hull}, else: {t, h} end)

  @doc "Count a result for the identity, in the current review window and for good."
  def record(design, :win),
    do: %{design | wins: design.wins + 1, total_wins: design.total_wins + 1}

  def record(design, :loss),
    do: %{design | losses: design.losses + 1, total_losses: design.total_losses + 1}

  def record(design, _other), do: design

  @doc """
  How the identity did since the last review: `:winning` with at least
  `min_results` results and a win share of `win_share` or more, `:losing` with
  that many results and a win share under `lose_share`, otherwise `:unproven`.
  """
  def verdict(design, min_results, win_share, lose_share) do
    results = design.wins + design.losses

    cond do
      results < max(min_results, 1) -> :unproven
      design.wins / results >= win_share -> :winning
      design.wins / results < lose_share -> :losing
      true -> :unproven
    end
  end

  @doc """
  What the daily review does with an identity, as `{action, design}` with the
  review window closed:

    * `:refuzz` — it is winning: fuzz it again, lightly, and clear its strikes;
    * `:replace` — it is losing and out of forgiveness (more strikes than
      `forgiveness`), or it is not winning and `outdated?` (the library's
      draw for the role has moved to costlier designs than this one);
    * `:keep` — anything else. A losing identity still inside its forgiveness
      keeps flying with one more strike.
  """
  def review(design, verdict, opts) do
    forgiveness = Keyword.get(opts, :forgiveness, 1)
    outdated? = Keyword.get(opts, :outdated?, false)
    closed = %{design | wins: 0, losses: 0}

    case verdict do
      :winning ->
        {:refuzz, %{closed | strikes: 0}}

      :losing ->
        strikes = design.strikes + 1
        if strikes > forgiveness, do: {:replace, closed}, else: {:keep, %{closed | strikes: strikes}}

      _ ->
        if outdated?, do: {:replace, closed}, else: {:keep, closed}
    end
  end

  @doc "The next generation of a winning identity: the same lineage, fuzzed again."
  def refuzz(design, alternatives, rolls, swaps, moves) do
    %{design | slots: fuzz(design.slots, alternatives, rolls, swaps, moves), generation: design.generation + 1}
  end

  @doc """
  A layout with no more than `allowance` capital ships: the first ones in tile
  order stay, each one past the allowance becomes `substitute` (or is dropped
  when there is none).
  """
  def cap_capitals(slots, ships, allowance, substitute) when is_integer(allowance) do
    {kept, _seen} =
      slots
      |> Enum.sort()
      |> Enum.flat_map_reduce(0, fn {tile, hull}, seen ->
        cond do
          not capital?(ships, hull) -> {[{tile, hull}], seen}
          seen < allowance -> {[{tile, hull}], seen + 1}
          substitute == nil -> {[], seen + 1}
          true -> {[{tile, substitute}], seen + 1}
        end
      end)

    kept
  end

  @doc """
  What stands in for a capital ship past the allowance: the hull the design
  already has most of outside capitals and Carriers, else the costliest
  frigate, corvette or fighter among `allowed`.
  """
  def capital_substitute(slots, ships, allowed) do
    own =
      slots
      |> Enum.map(fn {_tile, hull} -> hull end)
      |> Enum.reject(&(capital?(ships, &1) or transport?(ships, &1)))
      |> Enum.frequencies()
      |> Enum.max_by(fn {hull, count} -> {count, hull} end, fn -> nil end)

    case own do
      {hull, _count} ->
        hull

      nil ->
        ships
        |> Map.values()
        |> Enum.filter(&(&1.key in allowed and &1.class in [:frigate, :corvette, :fighter]))
        |> Enum.max_by(&{&1.production, &1.key}, fn -> nil end)
        |> case do
          nil -> nil
          ship -> ship.key
        end
    end
  end

  @doc "Capital ships in a layout."
  def capitals(slots, ships), do: Enum.count(slots, fn {_tile, hull} -> capital?(ships, hull) end)

  defp capital?(ships, hull), do: match?(%{class: :capital}, Map.get(ships, hull))
  defp transport?(ships, hull), do: match?(%{class: :transport}, Map.get(ships, hull))

  @doc """
  Capital ships a fleet may carry: one from the moment the players field a
  capital hull, one more every `step` of game time after that, never above
  `max`. Zero before.
  """
  def capital_allowance(nil, _now, _step, _max), do: 0

  def capital_allowance(since, now, step, max)
      when is_number(since) and is_number(now) and is_number(step) and step > 0 and is_integer(max) do
    min(1 + trunc(Kernel.max(now - since, 0) / step), max)
  end
end
