defmodule Headless.Fitness do
  @moduledoc """
  Dense, empire-first fitness (user redesign 2026-07-21). Replaces the
  win-centric scalar whose colony term saturated at ~3 systems — the
  literal reason the champion FRONTIER sat flat for three weeks (p90
  fitness ~400, cp75 systems stuck at 3) while more systems demonstrably
  win more (6 systems 76% vs 2-system's 56%). The old formula gave the GA
  no gradient to expand past 3 and rewarded hollow timeout wins over
  strong-but-lost empires.

  The user's ranked model of a "good bot" — one worth playing against —
  in descending weight:

    1. Strong empire        (golden-line-relative economics, biggest weight)
    2. Colonizing many       (LINEAR — the un-saturated fix)
    3. Engaging many mechanics (diminishing breadth over 6 categories)
    4. Looking human         (anti-degenerate; a knob, mostly latent)
    5. Getting victory points (lowest weight; a hollow timeout win ~= 0)

  The pieces reinforce: a stronger start → more colonies → more mechanics
  in play → more human-like → victory falls out. So rewarding 1–3 DIRECTLY
  (not only through the noisy win) is the dense gradient the scalar lacked,
  and — because empire quality and winning are aligned in the data — it
  cannot breed hollow turtles.

  `score/1` is pure and takes a signal map, so the LIVE per-game path
  (marathon) and the ARCHIVE RE-SCORE (mix headless.rescore, from stored
  aggregate stats) share one ruler. Weights are FIRST-PASS and tunable:
  at the golden line with all mechanics and a decisive win the score is
  ~1000, so "distance to 1000" reads as "distance to an ideal opponent";
  exceeding the line pushes above it.
  """

  # Priority weights (descending, per the user's ranking). Tunable.
  @w_empire 400.0
  @w_colony 250.0
  @w_mech 200.0
  @w_vp 100.0
  # Anti-degenerate (priority 4) is a PENALTY knob — sits between mechanics
  # and VP in importance; mostly latent, bites idle-hoarders.
  @w_degen 150.0
  # Extra demotion for the do-nothing pattern: reach the clock with almost
  # no empire and almost no engagement. Makes those genomes score NEGATIVE
  # so they can never be a deployed champion (user: "no value in hollow
  # wins" / "timing out should be negatively rewarded").
  @hollow_penalty 120.0

  # Human golden line at cp75 (docs/game-ai-training-handbook.md): the
  # empire yardstick. sys/pop/income/tech.
  @gold %{sys: 6.0, pop: 390.0, income: 3464.0, tech: 607.0}

  @doc """
  Score a bot from a signal map. Fields (all optional, default 0/false):

    * economy (cp75-ish): `:sys, :pop, :income, :tech, :hoarded`
    * `:colonies` — systems settled (final)
    * mechanic engagement (counts; > 0 = engaged): `:infiltrate,
      :destabilize, :dominion, :counter, :military`
    * outcome: `:won` (0..1 — 1.0 a win, a fraction for aggregate arms),
      `:my_vp, :their_vp`, `:ut_left` (UT remaining at game end; low =
      timeout)
  """
  def score(s) do
    empire = empire_score(s)
    breadth = breadth_count(s)

    @w_empire * empire +
      @w_colony * colony_score(s) +
      @w_mech * breadth_score(breadth) +
      @w_vp * vp_score(s) -
      @w_degen * degen(s) -
      hollow(s, empire, breadth)
  end

  @doc "Which of the 6 strategic mechanics this bot engaged (settle + 5 interaction)."
  def mechanics(s) do
    %{
      settle: g(s, :colonies) > 0,
      infiltrate: g(s, :infiltrate) > 0,
      destabilize: g(s, :destabilize) > 0,
      dominion: g(s, :dominion) > 0,
      counter: g(s, :counter) > 0,
      military: g(s, :military) > 0
    }
  end

  # --- components -------------------------------------------------------------

  # Golden-line-relative economy, capped 1.3 (30% past the line still pays,
  # bounded against runaway/hacking). Weighted toward systems + population.
  defp empire_score(s) do
    r = fn key, ref -> min(g(s, key) / ref, 1.3) end

    0.35 * r.(:sys, @gold.sys) +
      0.30 * r.(:pop, @gold.pop) +
      0.20 * r.(:income, @gold.income) +
      0.15 * r.(:tech, @gold.tech)
  end

  # LINEAR in colonies (the un-saturation fix) — every system pays equally
  # up to 1.5 (9 systems), so the 4th–7th finally earn gradient.
  defp colony_score(s), do: min(g(s, :colonies) / @gold.sys, 1.5)

  # Diminishing breadth over the 6 mechanic categories. count 2 → 0.55,
  # 3 → 0.70, 4 → 0.80, 5 → 0.86, 6 → 0.91 — a 2-mechanic specialist scores
  # clearly below a 4-mechanic generalist but stays viable in its niche.
  defp breadth_count(s), do: mechanics(s) |> Map.values() |> Enum.count(& &1)
  defp breadth_score(count), do: 1.0 - :math.exp(-count / 2.5)

  # Victory is the LOWEST-weighted, lowest term. A decisive win (ended
  # before the clock) is worth ~1.0; a timeout/attrition win only ~0.25; a
  # hollow tiebreak win (timeout + no VP progress) ≈ 0. A loss scores 0 on
  # this term but keeps all the empire/colony/mechanic reward — a good loss
  # beats a hollow win, by design.
  defp vp_score(s) do
    won = clamp(g(s, :won), 0.0, 1.0)
    timeout = timeout_frac(s)
    outcome = won * (1.0 - 0.75 * timeout)
    margin = clamp(0.04 * (g(s, :my_vp) - g(s, :their_vp)), -0.3, 0.4)
    clamp(outcome + margin, 0.0, 1.4)
  end

  # 0 when the game ended with time to spare (decisive), ramping to 1 as
  # ut_left → 0 (clock-out). Uses ut_left directly per game; the aggregate
  # path passes mean ut_left from mean_duration_ut.
  defp timeout_frac(s), do: 1.0 - clamp(g(s, :ut_left) / 200.0, 0.0, 1.0)

  # Idle-hoarding is un-human-like — real players spend. Ramps 0→1 as
  # hoarded credit runs 50k→250k.
  defp degen(s), do: clamp((g(s, :hoarded) - 50_000) / 200_000, 0.0, 1.0)

  # The do-nothing turtle: reached the clock (timeout), touched ≤2
  # mechanics, and never built an empire. Scaled by how timed-out it was.
  defp hollow(s, empire, breadth) do
    if breadth <= 2 and empire < 0.35 and timeout_frac(s) > 0.5,
      do: @hollow_penalty * timeout_frac(s),
      else: 0.0
  end

  defp g(s, key), do: Map.get(s, key, 0) || 0
  defp clamp(x, lo, hi), do: x |> max(lo) |> min(hi)
end
