defmodule Headless.Strategist do
  @moduledoc """
  V3 pillar 1: the phase strategist (docs/game-ai-v3.md).

  An explicit game-phase state machine that owns STRATEGY — the
  when-and-why that V2 left to gene weights and accumulated as ad-hoc
  "critical path" arms inside the Tunable policy. Two weeks of marathon
  telemetry settled the thesis: every step-change in bot strength came
  from hand-coded decision structure; the GA only ever tuned numbers
  inside it. So the structure gets one owner, ordered by design.

  Phase 1 of the migration: `phase/2` classifies the game, `steer/3`
  applies the phase's directives to the per-decision genome copy —
  initially the same forced-weight arms that lived in
  `Tunable.apply_expansion_priority/2`, now dispatched per phase. The
  taskmaster nodes (build/patent/lex/ship/mission/covert) remain in
  `Headless.Policies.Tunable`; budget pools and tasks land in later
  phases (see the design doc's migration plan).
  """

  @phases [:opening, :foundation, :expansion, :consolidation, :endgame]
  def phases, do: @phases

  # The system-slot ladder, in ancestor order (see Tunable's doctrine
  # table). system_1/sys_dom_2/system_4 raise the SYSTEM cap; the dominion
  # rungs are their ancestors. Caps out at ~9 systems — bounded expansion.
  @expansion_ladder [:system_1, :dominion_1, :sys_dom_2, :system_4, :dominion_3]

  # Colony-ship tech price (fast-mode data; keep in sync with Tunable's
  # @transport_tech).
  @transport_tech 2_000

  # Growth-curve lines (player knowledge, user 2026-07-12): stability > 24
  # maxes the growth formula (useful happiness caps at 25); housing
  # headroom > 10 keeps the habitation factor from pinching. Tunable's
  # build_actions applies the same lines per system.
  @growth_happy_target 24.0
  @hab_headroom 10.0

  # Endgame triggers: any faction near the 14-VP win, or the victory clock
  # (2400 UT -> 0) in its final quarter.
  @endgame_vp 10
  @endgame_time_left 600

  @doc """
  Classify the game for this bot. Monotonic hysteresis where it matters:
  once in :endgame, stay (the clock/VP situation that triggered it only
  tightens). Other transitions key on slow observables (colony count,
  opener completion), which cannot flap tick-to-tick.
  """
  def phase(view, mem) do
    cond do
      Map.get(mem, :phase) == :endgame -> :endgame
      endgame?(view) -> :endgame
      not opener_done?(mem) -> :opening
      colonies(view) == 0 -> :foundation
      colonies(view) < colony_target(mem) -> :expansion
      true -> :consolidation
    end
  end

  @doc """
  Apply the phase's directives to the per-decision genome copy. These are
  the code-level overrides no genome may starve (the V2-era "critical
  path" arms), now owned per phase:

    :opening        — none (the opener book owns every decision upstream)
    :foundation     — first-colony chain + tech bootstrap + growth rungs
    :expansion      — the same, plus the parallel-admiral lex
    :consolidation  — growth + research rungs; the cap ladder keeps
                      climbing (late slots still pay)
    :endgame        — none: forcing new colonies in the final quarter is
                      waste; the sprint reactions (r_sprint_*) own the
                      close.
  """
  def steer(g, :opening, _view), do: g

  # DT-2 (2026-07-16): the endgame commits to a VICTORY TRACK read from the
  # standings instead of steering nothing. 17% of all decisions are endgame;
  # bots were out-building opponents (income/system at human parity) but not
  # CONVERTING the advantage into the 14 VP deliberately.
  def steer(g, :endgame, view) do
    case victory_focus(view) do
      # Population points: push growth past the ~70 knee (the one case
      # players do — pop VP is why), house it, defend it.
      :population ->
        g
        |> Map.put("growth_pop_target", 120.0)
        |> Map.put("w_build_infra_open", 10.5)
        |> Map.put("w_build_infra_dome", 10.5)
        |> Map.put("w_build_hab_dome", 10.4)
        |> Map.put("w_build_happy_pot_dome", 10.4)
        |> Map.put("w_defend", 2.0)

      # Conquest: everything raids; the endgame budget split already sends
      # 45% of credit to the military pool.
      :conquest ->
        g
        |> Map.put("w_raid_enemy", 10.5)
        |> Map.put("w_conquest", 10.5)
        |> Map.put("fleet_readiness", 1.0)

      # Visibility (shadows): infiltration blitz with every Erased.
      :visibility ->
        g
        |> Map.put("w_mission_infiltrate", 10.5)
        |> Map.put("w_train_covert", 10.0)

      nil ->
        g
    end
  end

  def steer(g, phase, view) when phase in [:foundation, :expansion, :consolidation] do
    g
    |> expansion_chain(view)
    |> tech_bootstrap(view)
    |> research_rung(view)
    |> research_completion(view)
    |> growth_rungs(view)
    |> parallel_admirals(view, phase)
  end

  # Expansion critical path (user diagnosis 2026-07-08): jump ONLY the
  # critical item to the front of its OWN queue — no open slot -> next cap
  # lex; slot open but no ship patent -> transport patent. Everything else
  # stays strict-priority.
  defp expansion_chain(g, view) do
    player = view.player
    open = open_slots(view)

    cond do
      open <= 0 ->
        case Enum.find(@expansion_ladder, &(&1 not in player.doctrines)) do
          nil -> g
          lex -> Map.put(g, "w_doc_#{lex}", 11.0)
        end

      :transport_1 not in player.patents ->
        Map.put(g, "w_patent_transport_1", 11.0)

      true ->
        g
    end
  end

  # Tech bootstrap (2026-07-11): the colonization chain is paid in TECH
  # (600 patent + 2000 ship) while tech capacity scales with population and
  # bodies — while the chain still needs tech, force university builds
  # (ungated, credit-cheap, unique_body-capped) and research_orbital
  # (inert until its patent is owned).
  defp tech_bootstrap(g, view) do
    player = view.player

    if :transport_1 not in player.patents or player.technology.value < @transport_tech do
      g
      |> Map.put("w_build_university_open", 11.0)
      |> Map.put("w_build_research_orbital", 11.0)
    else
      g
    end
  end

  # Research rung (2026-07-12): once tech INCOME can absorb it, take the
  # orbital_research patent (1200 tech) — default patent weight 1.0 means
  # no genome ever climbs it unaided. 10.5 stays below the transport
  # patent; the income gate keeps it from starving the early ship save.
  defp research_rung(g, view) do
    player = view.player

    if :orbital_research not in player.patents and player.technology.change >= 40,
      do: Map.put(g, "w_patent_orbital_research", 10.5),
      else: g
  end

  # DT-1c research-chain COMPLETION (2026-07-16): per-system tech was the
  # worst gold-line deficit (29-62/system vs the human's 101) because the
  # chain stopped at orbital_research — research_open (22×body_tec, the
  # compounding building) was built ~0.5×/game against 1-2M idle credits.
  # Once tech income can absorb the 4500 patent, climb it; once owned,
  # force the build (unique_body: self-limiting; 84k from a rich pool).
  defp research_completion(g, view) do
    player = view.player

    g =
      if :open_research not in player.patents and player.technology.change >= 100,
        do: Map.put(g, "w_patent_open_research", 10.4),
        else: g

    if :open_research in player.patents,
      do: Map.put(g, "w_build_research_open", 10.8),
      else: g
  end

  # Growth-curve patent rungs (user 2026-07-12): when any system still in
  # its growth window is pinned below the stability line or out of housing
  # headroom, unlock the cheap fixes — dome_happiness (1000 tech) and
  # infra_dome_1 (2000 tech). Gated by w_growth so a genome can opt out.
  defp growth_rungs(g, view) do
    player = view.player
    wg = Map.get(g, "w_growth", 6.0)
    pop_target = Map.get(g, "growth_pop_target", 70.0)

    {need_happy, need_hab} =
      if wg >= 0.5 do
        view.systems
        |> Map.values()
        |> Enum.filter(&(&1.population.value < pop_target))
        |> Enum.reduce({false, false}, fn s, {hp, hb} ->
          {hp or s.happiness.value < @growth_happy_target,
           hb or s.habitation.value - s.population.value < @hab_headroom}
        end)
      else
        {false, false}
      end

    g =
      if need_happy and :dome_happiness not in player.patents,
        do: Map.put(g, "w_patent_dome_happiness", 10.3),
        else: g

    if need_hab and :infra_dome_1 not in player.patents,
      do: Map.put(g, "w_patent_infra_dome_1", 10.2),
      else: g
  end

  # Parallel colonization (user directive 2026-07-09): with multiple open
  # slots and a single colonizer, field a fleet — force the admiral-cap
  # lex so several admirals colonize concurrently. Expansion phase and
  # later only: during foundation the first colony chain comes first.
  defp parallel_admirals(g, view, phase) when phase in [:expansion, :consolidation] do
    if open_slots(view) >= 2 and n_admirals(view) <= 1 and
         :admiral_1 not in view.player.doctrines,
       do: Map.put(g, "w_doc_admiral_1", 10.5),
       else: g
  end

  defp parallel_admirals(g, _view, _phase), do: g

  # --- observables --------------------------------------------------------------

  defp opener_done?(mem), do: match?(%{done: true}, Map.get(mem, :opener))

  # Colonies = systems beyond the starting one. Bots start with exactly one
  # system in every format we train.
  defp colonies(view), do: max(length(view.player.stellar_systems) - 1, 0)

  defp open_slots(view) do
    trunc(view.player.max_systems.value) - length(view.player.stellar_systems)
  end

  defp n_admirals(view) do
    view.characters
    |> Map.values()
    |> Enum.count(&(&1.type == :admiral and &1.status == :on_board))
  end

  # How many colonies before this personality shifts from expansion to
  # consolidation. A V3 personality gene (spec'd in Tunable until the
  # Phase-4 genome shrink).
  defp colony_target(mem) do
    genome = Map.get(mem, :genome_active) || Map.get(mem, :genome) || %{}
    Map.get(genome, "expansion_colony_target", 4.0)
  end

  defp endgame?(view) do
    case view.victory do
      %{factions: factions, ut_time_left: t} ->
        best = factions |> Enum.map(& &1.victory_points) |> Enum.max(fn -> 0 end)
        best >= @endgame_vp or (is_number(t) and t < @endgame_time_left)

      _ ->
        false
    end
  end

  # Which victory track this faction is furthest along (track stage index),
  # ties broken population > visibility > conquest — the economy our bots
  # actually build favors that order. nil when standings are unreadable.
  defp victory_focus(view) do
    with %{factions: factions} <- view.victory,
         %{} = mine <- Enum.find(factions, &(&1.key == view.player.faction)) do
      [
        {:population, get_in(mine.population_track, [:index]) || 0, 2},
        {:visibility, get_in(mine.visibility_track, [:index]) || 0, 1},
        {:conquest, get_in(mine.conquest_track, [:index]) || 0, 0}
      ]
      |> Enum.max_by(fn {_track, index, tiebreak} -> {index, tiebreak} end)
      |> elem(0)
    else
      _ -> nil
    end
  end
end
