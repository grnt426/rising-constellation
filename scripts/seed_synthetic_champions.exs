# Inject hand-designed "synthetic champions" into every faction archive.
#
# Rationale (2026-07-12): the GA population all descends from lineages bred
# BEFORE the happiness/tech mechanics were understood — no champion encodes
# the causal ladder the game data proves out (happiness-positive housing ->
# population growth -> pop-scaled universities -> cheap research patents ->
# body_tec research buildings -> tech compounds -> the 2600-tech colony
# chain -> repeat wide). These seeds place that ladder INTO the gene pool so
# selection can refine it instead of having to stumble onto it gene by gene.
#
# Mechanics: archive entries under "seed_*" keys become mutation parents via
# the marathon's champion sampling (2 fittest + 2 random). Fitness 250 sits
# above the population mean (~160) but below elite (400-750): sampled often
# enough to matter, never dominating. The dashboard filters "seed_" keys
# from the champions table. Run with the marathon STOPPED (it saves archives
# at iteration end and would clobber concurrent writes):
#
#   docker compose exec -u rc rc bash -lc "cd /data && mix run tmp/seed_synthetic_champions.exs"

alias Headless.Policies.Tunable

# Shared economy hygiene: what the game data says a healthy empire builds.
# Weights are 0-10 (11.0 is reserved for code-level critical-path forcing).
common = %{
  # Tech ladder: pop-scaled universities everywhere; body_tec research asap.
  "w_build_university_open" => 10.0,
  "w_build_research_orbital" => 10.0,
  # Happiness-positive housing (infra +12 happy +8 hab) over the -5 poor hab.
  "w_build_infra_open" => 10.0,
  "w_build_infra_dome" => 9.5,
  "w_build_hab_dome" => 8.0,
  "w_build_hab_open_rich" => 7.0,
  "w_build_hab_open_poor" => 0.5,
  "w_build_mine_dome" => 2.0,
  "w_build_finance_open" => 0.0,
  # Happiness + ideology producers (happy_pot_dome also pays 5*act tech).
  "w_build_happy_pot_dome" => 8.0,
  "w_build_happy_pot_orbital" => 7.0,
  "w_build_monument_dome" => 7.5,
  "w_build_ideo_open" => 8.5,
  # Credit: enough, not 322 factories.
  "w_build_market_open" => 6.0,
  "w_build_factory_orbital" => 5.0,
  # Patent ladder: colony chain + the cheap research/happiness rungs.
  "w_patent_transport_1" => 10.0,
  "w_patent_orbital_research" => 10.0,
  "w_patent_dome_happiness" => 9.0,
  "w_patent_infra_dome_1" => 9.5,
  "w_patent_open_credit" => 5.0,
  "w_patent_dome_ideo" => 6.0,
  # Expansion + fleet-capacity lexes, and the ideology economy branch.
  "w_doc_system_1" => 10.0,
  "w_doc_dominion_1" => 9.0,
  "w_doc_sys_dom_2" => 8.5,
  "w_doc_system_4" => 8.0,
  "w_doc_admiral_1" => 9.0,
  "w_doc_speaker_1" => 6.0,
  "w_doc_tech_2" => 7.0,
  # Growth curve (player wisdom): chase stability>24 / headroom>10 hard,
  # stop at the ~75-pop knee.
  "w_growth" => 8.0,
  "growth_pop_target" => 75.0,
  # Ship-tech protection + economy posture.
  "reserve_first_colony" => 8.0,
  "reserve_followup_colony" => 4.0,
  "w_econ_roi" => 2.5,
  "w_governor" => 6.0,
  "credit_floor" => 3_000.0,
  "focus_economy" => 1.3,
  "focus_expansion" => 1.3,
  "focus_military" => 0.9,
  "focus_shadows" => 0.7,
  "w_mission_make_dominion" => 6.0
}

variants = %{
  # The golden-line chaser: balanced human ladder, colonial opener
  # (opener saves straight into the transport patent).
  "seed_developer" =>
    Map.merge(common, %{
      "opener_variant" => 2.0,
      "w_patent_open_research" => 9.0,
      "w_build_research_open" => 10.0,
      "w_build_high_factory_dome" => 7.0
    }),
  # Tech-first: exobiology opener beelines open_research; colonize once
  # the research economy is online (weaker early ship priority).
  "seed_tech_rusher" =>
    Map.merge(common, %{
      "opener_variant" => 3.0,
      "w_patent_open_research" => 10.0,
      "w_build_research_open" => 10.0,
      "w_build_high_factory_dome" => 8.0,
      "w_patent_transport_1" => 8.5,
      "reserve_first_colony" => 6.0,
      "w_doc_system_1" => 9.0,
      "w_doc_dominion_1" => 8.0
    }),
  # Width over depth: maximum parallel colonization, tech via universities
  # on many systems; keeps a defensive fleet posture for its sprawl.
  "seed_wide_boomer" =>
    Map.merge(common, %{
      "opener_variant" => 2.0,
      "w_patent_transport_2" => 6.0,
      "w_doc_admiral_1" => 10.0,
      "w_doc_admiral_2" => 7.0,
      "w_patent_open_research" => 6.0,
      "army_size" => 6.0,
      "w_defend" => 1.0,
      "reserve_followup_colony" => 6.5
    })
}

out = "tmp/marathon_night"
fitness = 250.0

for faction <- ~w(tetrarchy myrmezir ark cardan synelle) do
  path = Path.join(out, "archive_#{faction}.json")

  archive =
    case File.read(path) do
      {:ok, json} -> Jason.decode!(json)
      _ -> %{}
    end

  archive =
    Enum.reduce(variants, archive, fn {key, overrides}, acc ->
      genome = Tunable.default() |> Map.merge(overrides)
      Map.put(acc, key, %{"fitness" => fitness, "genome" => genome, "stats" => %{}})
    end)

  File.write!(path, Jason.encode!(archive))
  IO.puts("#{faction}: seeded #{map_size(variants)} synthetic champions (#{map_size(archive)} entries total)")
end
