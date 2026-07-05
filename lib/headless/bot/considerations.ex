defmodule Headless.Bot.Considerations do
  @moduledoc """
  Typed consideration library for evolvable utility targeting (game-ai-v2.md
  §2). A consideration maps a candidate galaxy-system summary to a
  normalized 0..1 score using only bot-visible state. Genomes carry, per
  decision point, a LIST of `[consideration_name, weight]` pairs; candidates
  are ranked by the weighted sum and the argmax wins.

  The library is deliberately a closed, typed set: structural evolution
  composes these — it never writes code. New considerations are added here
  (by humans today, by the LLM-mutation loop later) and become available to
  every genome's add-consideration mutation immediately.

  Scores are heuristically normalized; exact scaling matters less than
  ordering, since evolution tunes the weights around whatever scale each
  consideration emits.
  """

  # Names are strings because they live inside JSON genomes.
  @names ~w(proximity population development sector_vp leader_target weak_owner strength instability sector_swing border)

  @doc "All consideration names available to structural mutations."
  def names, do: @names

  @doc """
  Rank `candidates` (galaxy-system summaries) from `here_id` using the
  genome's `[name, weight]` list; returns the best candidate's id, or nil.
  `extra` carries decision-point context (e.g. `:strength` scores for
  colonization).
  """
  def rank(view, here_id, candidates, gene_list, extra \\ %{})
  def rank(_view, _here, [], _genes, _extra), do: nil
  def rank(_view, nil, _candidates, _genes, _extra), do: nil

  def rank(view, here_id, candidates, gene_list, extra) do
    ctx = build_ctx(view, here_id, candidates, extra)

    if ctx == nil do
      nil
    else
      # Travel isn't free — physics, not preference. A small constant
      # proximity term breaks ties toward near targets, so a gene list
      # whose mutations stripped every distance-sensitive consideration
      # degrades into a nearest-ranker instead of an arbitrary-far one
      # (the failure mode that cratered early sector_swing/border
      # adopters: constant scores → max_by picks whatever comes first,
      # and the agent spends the game in transit). Learned weights
      # dominate it at normal magnitudes.
      candidates
      |> Enum.max_by(fn s -> score(gene_list, ctx, s) + 0.15 * consider("proximity", ctx, s) end, fn -> nil end)
      |> case do
        nil -> nil
        s -> s.id
      end
    end
  end

  @doc "Weighted-sum utility of one candidate under a gene list."
  def score(gene_list, ctx, s) do
    Enum.reduce(gene_list, 0.0, fn
      [name, w], acc -> acc + w * consider(name, ctx, s)
      {name, w}, acc -> acc + w * consider(name, ctx, s)
      _, acc -> acc
    end)
  end

  # Context: per-rank precomputation shared across candidates.
  defp build_ctx(view, here_id, candidates, extra) do
    systems = view.galaxy.stellar_systems

    case Enum.find(systems, fn s -> s.id == here_id end) do
      nil ->
        nil

      here ->
        counts =
          systems
          |> Enum.filter(& &1.faction)
          |> Enum.frequencies_by(& &1.faction)

        # Sector plurality counts follow the engine's ownership rule:
        # only INHABITED systems (class != nil) score (galaxy/sector.ex).
        sector_counts =
          systems
          |> Enum.filter(&(&1.class != nil))
          |> Enum.group_by(& &1.sector_id)
          |> Map.new(fn {sec, ss} -> {sec, Enum.frequencies_by(ss, & &1.faction)} end)

        neighbors =
          Enum.reduce(view.galaxy.edges, %{}, fn e, acc ->
            a = e.s1.id
            b = e.s2.id

            acc
            |> Map.update(a, [b], &[b | &1])
            |> Map.update(b, [a], &[a | &1])
          end)

        %{
          my_faction: view.player.faction,
          sector_counts: sector_counts,
          neighbors: neighbors,
          by_id: Map.new(systems, &{&1.id, &1}),
          here: here.position,
          max_pop: max_of(candidates, & &1.population),
          max_dev: max_of(candidates, & &1.score),
          sector_vp: Map.new(view.galaxy.sectors, fn sec -> {sec.id, sec.victory_points} end),
          max_vp: view.galaxy.sectors |> Enum.map(& &1.victory_points) |> Enum.max(fn -> 1 end),
          faction_counts: counts,
          max_faction: counts |> Map.values() |> Enum.max(fn -> 1 end),
          strength: Map.get(extra, :strength, %{}),
          max_strength: extra |> Map.get(:strength, %{}) |> Map.values() |> Enum.max(fn -> 1.0 end),
          instability: Map.get(extra, :instability, %{})
        }
    end
  end

  # Closer is better; ~40 map units is the half-score distance on our
  # 120-wide scenario bands.
  defp consider("proximity", ctx, s) do
    1.0 / (1.0 + :math.sqrt(dist2(ctx.here, s.position)) / 40.0)
  end

  # Big population = rich economy = valuable pillage / conquest / intel.
  defp consider("population", ctx, s), do: safe_div(s.population, ctx.max_pop)

  # Development (body count score) = built-up progress worth degrading.
  defp consider("development", ctx, s), do: safe_div(s.score, ctx.max_dev)

  # Systems in high-victory-point sectors decide the game.
  defp consider("sector_vp", ctx, s), do: safe_div(Map.get(ctx.sector_vp, s.sector_id, 0), ctx.max_vp)

  # Owner holds many systems: hitting the leader steals winner progress.
  defp consider("leader_target", ctx, s),
    do: safe_div(Map.get(ctx.faction_counts, s.faction, 0), ctx.max_faction)

  # Owner holds few systems: prey on the weak.
  defp consider("weak_owner", ctx, s),
    do: 1.0 - safe_div(Map.get(ctx.faction_counts, s.faction, 0), ctx.max_faction)

  # Colonization value (precomputed system strength, passed via extra).
  defp consider("strength", ctx, s), do: safe_div(Map.get(ctx.strength, s.id, 0.0), ctx.max_strength)

  # Low stability (engine: happiness) = ripe for destabilization. Only
  # systems SCOUTED to visibility >= 3 appear in the map (information
  # rules); everything else scores 0 — you can't quake what you can't see.
  # Values arrive pre-normalized (0 = stable, 1 = on the brink).
  defp consider("instability", ctx, s), do: Map.get(ctx.instability, s.id, 0.0)

  # Marginal sector-majority math (catalog #36): sector VP goes to the
  # PLURALITY holder (ties keep the incumbent), so the cheapest system that
  # FLIPS a sector is worth more than a better system elsewhere. 1.0 =
  # taking this system makes me the strict plurality leader; 0.4 = it
  # strips a point from the sector's current leader (denial); 0 otherwise.
  defp consider("sector_swing", ctx, s) do
    counts = Map.get(ctx.sector_counts, s.sector_id, %{})
    mine = Map.get(counts, ctx.my_faction, 0)

    rival_best =
      counts
      |> Enum.reject(fn {f, _} -> f == ctx.my_faction or f == nil end)
      |> Enum.map(fn {f, n} -> if f == s.faction, do: n - 1, else: n end)
      |> Enum.max(fn -> 0 end)

    leader =
      counts
      |> Enum.reject(fn {f, _} -> f == nil end)
      |> Enum.max_by(fn {_f, n} -> n end, fn -> nil end)

    cond do
      # No swing where I already lead — piling into a won sector is not
      # sector play (this bug made every home-sector candidate score 1.0).
      mine > rival_best -> 0.0
      mine + 1 > rival_best -> 1.0
      match?({f, _} when f != nil, leader) and elem(leader, 0) == s.faction -> 0.4
      true -> 0.0
    end
  end

  # Fraction of the candidate's lane-neighbors held by enemy factions
  # (catalog #17/#34): high = frontline, low = interior. Pairs positively
  # for forward defense/raiding staging, negatively for safe colonization.
  defp consider("border", ctx, s) do
    neighbors = Map.get(ctx.neighbors, s.id, [])

    case neighbors do
      [] ->
        0.0

      ids ->
        enemy =
          Enum.count(ids, fn id ->
            case Map.get(ctx.by_id, id) do
              nil -> false
              n -> n.faction != nil and n.faction != ctx.my_faction
            end
          end)

        enemy / length(ids)
    end
  end

  defp consider(_unknown, _ctx, _s), do: 0.0

  defp max_of(list, fun) do
    list |> Enum.map(fun) |> Enum.max(fn -> 1 end)
  end

  defp safe_div(_num, den) when den in [0, 0.0], do: 0.0
  defp safe_div(num, den), do: num / den

  defp dist2(a, b), do: (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
end
