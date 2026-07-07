defmodule Headless.Econ do
  @moduledoc """
  ROI/bottleneck strategy module (code, not genes): classifies what each
  system's development is currently limited by and turns that into build
  and patent score bonuses. The genome decides how much to TRUST it via a
  single gene, `w_econ_roi` (0 = module off, exact legacy behavior; 3 =
  full trust) — the module itself is hand-built domain knowledge, per the
  V2 rule that strategy nodes are code and only their weighting evolves.

  Why bottleneck relief instead of per-building ROI: payoffs chain (a
  refinery is worthless without free workforce; workforce needs housing;
  housing needs tiles; tiles need infrastructure). Scoring candidates by
  the CURRENT binding constraint walks that chain backwards one link per
  purchase without needing a forward simulator: whichever dependency
  binds right now is the one whose relief has the highest marginal value,
  and relieving it exposes the next link as the new bottleneck.

  The same reasoning covers hoard-vs-invest: hoarding is only correct
  when nothing relieves a bottleneck (true save-up); if a purchase
  relieves one, its compounding return beats banked credits. The module
  therefore never gates on a savings target — it reorders what gets
  bought first, and the existing credit_floor still protects solvency.
  """

  alias Headless.Policies.HomeDev
  alias Headless.Policies.Tunable

  # Build-catalog roles (keys mirror Tunable's @catalog).
  @housing ~w(hab_open_poor hab_open_rich hab_dome)a
  @outputs ~w(mine_dome factory_orbital high_factory_dome lift_open market_open
              finance_open ideo_credit_open university_open research_open
              research_orbital ideo_open monument_dome)a
  @tech_outputs ~w(university_open research_open research_orbital)a
  @infra ~w(infra_open infra_dome)a

  @doc "Genome trust in this module, scaled to 0..1."
  def trust(g), do: g |> Map.get("w_econ_roi", 0.0) |> max(0.0) |> min(3.0) |> Kernel./(3)

  @doc """
  Binding-constraint signals for one system. Workforce is the pivot:
  surplus means output buildings staff immediately (their ROI is real);
  none means output buildings would idle, and if housing is also at cap
  the constraint has chained back to habitation.
  """
  def system_signals(system) do
    pop = system.population.value
    hab = system.habitation.value
    free_wf = system.workforce - system.used_workforce
    bodies = HomeDev.flatten_bodies(system.bodies)

    free_normal? =
      Enum.any?(bodies, fn body ->
        HomeDev.eligible_tile(body, HomeDev.biome(body.type), :normal) != nil
      end)

    free_infra? =
      Enum.any?(bodies, fn body ->
        HomeDev.eligible_tile(body, HomeDev.biome(body.type), :infrastructure) != nil
      end)

    %{
      housing_bound: hab > 0 and pop >= hab * 0.85,
      roomy: hab > 0 and pop < hab * 0.5,
      labor_surplus: free_wf >= 3,
      labor_starved: free_wf <= 0,
      slots_bound: not free_normal? and free_infra?
    }
  end

  @doc """
  Empire-level signals: the patents that BLOCK buildings the genome
  already wants (weight >= the build threshold). A non-empty blocker set
  means technology income is the empire's meta-bottleneck — the state the
  2026-07-07 live game exposed (67k idle credits, 20 tech/min, nothing
  buildable-and-wanted for an hour).
  """
  def empire_signals(view, g, catalog) do
    player = view.player

    blockers =
      catalog
      |> Enum.filter(fn {key, _, patent, _, _, _} ->
        patent != nil and patent not in player.patents and
          Map.get(g, "w_build_#{key}", 0.0) >= 0.5
      end)
      |> Enum.map(fn {_, _, patent, _, _, _} -> patent end)
      |> Enum.uniq()

    %{blockers: blockers, tech_starved: blockers != []}
  end

  @doc """
  Score bonus for building `key` (pre-trust scaling). ADDITIVE to the
  genome's w_build weight so the module can promote a building the
  genome never valued and demote one it overvalues — multiplicative
  modulation would leave hard-zero weights unrescuable.
  """
  def bonus(sig, key, empire) do
    housing? = key in @housing
    output? = key in @outputs

    0.0
    |> add(housing? and sig.housing_bound, 1.2)
    |> add(housing? and sig.roomy, -0.4)
    |> add(output? and sig.labor_surplus, 0.8)
    |> add(output? and sig.labor_starved, -0.6)
    |> add(key in @infra and sig.slots_bound, 1.5)
    |> add(key in @tech_outputs and empire.tech_starved, 0.7)
  end

  defp add(acc, true, v), do: acc + v
  defp add(acc, false, _v), do: acc

  @doc """
  Raise w_patent_* (additively, by trust) for every patent gating a
  wanted building — the chain link from "building I want" back through
  "patent that blocks it" to "research that pays for it". Applied to the
  per-decision genome copy, same pattern as reaction modulation.
  """
  def patent_pressure(g, view, catalog) do
    t = trust(g)

    if t <= 0.0 do
      g
    else
      %{blockers: blockers} = empire_signals(view, g, catalog)
      g = Enum.reduce(blockers, g, fn patent, g -> Map.update(g, "w_patent_#{patent}", t, &(&1 + t)) end)

      # The chain also runs goal -> ship -> patent: an OPEN system slot is
      # paid-for capacity going to waste, and if the transport patent is
      # what blocks filling it, that patent outranks any econ unlock.
      # Weighted 3x the building-blocker boost — without this, strict-
      # priority patent saving under boosted econ weights starves
      # transport_1 forever (596 refused orders/game, 2026-07-07).
      expansion_blocked? =
        :transport_1 not in view.player.patents and
          trunc(view.player.max_systems.value) > length(view.player.stellar_systems)

      if expansion_blocked?,
        do: Map.update(g, "w_patent_transport_1", 3.0 * t, &(&1 + 3.0 * t)),
        else: g
    end
  end

  @doc """
  The BOOMER benchmark genome: an econ racer at full module trust with a
  hand-tuned development portfolio and the expansion-lex ladder maxed,
  and its covert program zeroed so the benchmark punishes slow economy
  without confounding the signal with agent play. Runs as a permanent
  marathon opponent (the pace-setter): pure coevolution equilibrated at
  a development tempo a human doubles (2026-07-07 live-game finding), so
  the arena needs one opponent whose tempo is non-negotiable. Because it
  lives in Tunable's own gene space, evolution can copy any part of the
  recipe that wins.
  """
  def boom_genome do
    Tunable.default()
    |> Map.merge(%{
      "w_econ_roi" => 3.0,
      # Development engine: tech first (patents are the wall), then
      # credit and housing so the tech economy stays staffed and solvent.
      "w_build_university_open" => 9.0,
      "w_build_research_orbital" => 8.0,
      "w_build_research_open" => 6.0,
      "w_build_factory_orbital" => 9.0,
      "w_build_infra_open" => 9.0,
      "w_build_infra_dome" => 7.0,
      "w_build_hab_open_poor" => 8.0,
      "w_build_hab_open_rich" => 8.0,
      "w_build_hab_dome" => 6.0,
      "w_build_mine_dome" => 7.0,
      "w_build_market_open" => 7.0,
      "w_build_high_factory_dome" => 6.0,
      "w_build_lift_open" => 6.0,
      "w_build_ideo_open" => 6.0,
      # Expansion IS the boom: the transport patent outranks every econ
      # unlock (strict-priority patent saving would otherwise starve it
      # behind the boosted econ patents — the 0-colony boomer bug).
      "w_patent_transport_1" => 9.5,
      "w_patent_infra_open_1" => 9.0,
      "w_patent_infra_dome_1" => 8.0,
      "w_patent_citadel" => 8.0,
      "w_patent_open_credit" => 7.0,
      "w_patent_open_research" => 8.0,
      "w_patent_orbital_research" => 8.0,
      "w_patent_dome_industries" => 6.0,
      # Expansion ladder: system/dominion slots are the long-run ceiling
      # on everything above.
      "w_doc_system_1" => 9.0,
      "w_doc_dominion_1" => 7.0,
      "w_doc_sys_dom_2" => 8.0,
      "w_doc_system_4" => 8.0,
      "w_doc_dominion_3" => 6.0,
      # Pure boomer: no covert program.
      "w_mission_infiltrate" => 0.0,
      "w_mission_destabilize" => 0.0,
      "w_mission_assassinate" => 0.0,
      "w_mission_convert" => 0.0,
      "credit_floor" => 4_000.0
    })
  end
end
