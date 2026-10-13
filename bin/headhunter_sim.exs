# Monte Carlo of the Headhunter daily: what a leaderboard looks like for the
# rules in Daily.Headhunter, and how it moves with the exposure curve.
#
#   mix run --no-start bin/headhunter_sim.exs
#   SIM_VARIANTS=1 mix run --no-start bin/headhunter_sim.exs        # other exposure curves
#   SIM_VARIANTS=levels mix run --no-start bin/headhunter_sim.exs   # other level schedules
#   SIM_VARIANTS=removal mix run --no-start bin/headhunter_sim.exs  # other enemy removal skill
#
# The model: 15-second steps over a 30-minute run. A player profile is an
# Intelligence curve, the moments its Erased take the field, how often it
# acts on an opening, and a flat removal bonus (a lex). Each Erased starts at
# level 1 with one removal point, strikes the exposed target it has the best
# odds against whenever it is under cover (never below 30%), and puts 60% of
# its level-ups into removal. A removed Erased is replaced two minutes later.
#
# Engine numbers used (read from the code, not derived): removal attack is 18
# per assassin point, an Erased has 10 Protection per level, cover starts at
# 80, recovers 0.25/ut (5 per 15 s at the daily clock), threshold 75; removal
# costs 20..30 cover on a success, 10..20 on a critical, 30..50 on a failure,
# 50..80 on a critical failure, and pays 12 / 15 / 8 / 2.5 XP; a level costs
# 10(L+1) + ((L+1)/2)^2.5 XP. Odds come from Wave.Intel.band/3, which mirrors
# Core.Dice.

defmodule Sim do
  @steps 120
  @date "2026-10-27"

  def defaults do
    %{
      per_step: 0.2,
      cap: 1.0,
      exposed_cover: Daily.Headhunter.exposed_cover(),
      strike_chance: Daily.Headhunter.strike_chance(),
      recruit: fn n -> Daily.Headhunter.recruit(@date, n) end,
      main_skill: 0.6,
      min_odds: 0.3,
      enemy_points: &Daily.Headhunter.removal_points/1
    }
  end

  def reveal(p, intel, level), do: min(Float.floor(max(intel, 0) / 25) * p.per_step / level, p.cap)

  def roll(attack, level, defense) do
    {lo, hi} = Wave.Intel.band(attack, level, defense)
    v = lo + :rand.uniform() * (hi - lo)

    cond do
      v < 0.05 -> :critical_failure
      v < 0.5 -> :normal_failure
      v < 0.95 -> :normal_success
      true -> :critical_success
    end
  end

  def cost(:critical_failure), do: {50 + :rand.uniform(31) - 1, 2.5}
  def cost(:normal_failure), do: {30 + :rand.uniform(21) - 1, 8}
  def cost(:normal_success), do: {20 + :rand.uniform(11) - 1, 12}
  def cost(:critical_success), do: {10 + :rand.uniform(11) - 1, 15}

  def success?(r), do: r in [:normal_success, :critical_success]

  def threshold(level), do: Float.round(10 * (level + 1) + :math.pow((level + 1) / 2, 2.5))

  def gain(agent, xp, p) do
    xp = agent.xp + xp
    need = threshold(agent.level)

    if xp > need do
      pts = if :rand.uniform() < p.main_skill, do: agent.pts + 1, else: agent.pts
      gain(%{agent | level: agent.level + 1, pts: pts, xp: 0.0}, xp - need, p)
    else
      %{agent | xp: xp}
    end
  end

  # profile: %{intel: fn step -> intel end, joins: [step], attention: 0..1, bonus: flat attack, replacements: n}
  def run(profile, p \\ defaults()) do
    state = %{
      enemies: %{},
      agents: [],
      pending: profile.joins,
      replacements: profile.replacements,
      kills: 0,
      reveals: 0,
      strikes: 0,
      lost: 0,
      attempts: 0
    }

    Enum.reduce(1..@steps, state, fn t, s -> step(t, s, profile, p) end)
  end

  defp step(t, s, profile, p) do
    intel = profile.intel.(t)

    # arrivals
    enemies =
      if t <= Daily.Headhunter.total() do
        r = p.recruit.(t)

        Map.put(s.enemies, t, %{
          level: r.level,
          bold: r.bold?,
          evasion: r.evasion,
          state: :hidden,
          struck: false,
          born: t
        })
      else
        s.enemies
      end

    # the player's agents join, recover cover
    {joining, pending} = Enum.split_with(s.pending, &(&1 <= t))
    fresh = Enum.map(joining, fn _ -> %{level: 1, pts: 1, xp: 5.0, cover: 80.0} end)
    agents = Enum.map(s.agents ++ fresh, fn a -> %{a | cover: min(a.cover + 5, 100.0)} end)

    # exposure runs out
    enemies =
      Map.new(enemies, fn
        {k, %{state: {:exposed, until}} = e} when until <= t -> {k, %{e | state: :hidden}}
        other -> other
      end)

    s = %{s | enemies: enemies, agents: agents, pending: pending}

    # the sweep, then the bold ones
    s =
      Enum.reduce(Enum.sort(Map.keys(s.enemies)), s, fn k, s ->
        e = s.enemies[k]

        cond do
          e.state != :hidden ->
            s

          reveal(p, intel, e.level) > e.evasion ->
            %{s | enemies: Map.put(s.enemies, k, %{e | state: {:exposed, 1_000_000}}), reveals: s.reveals + 1}

          e.bold and not e.struck and s.agents != [] and :rand.uniform() < p.strike_chance ->
            target = Enum.random(s.agents)
            attack = 18 * p.enemy_points.(e.level)
            result = roll(attack, e.level, 10 * target.level + intel)
            {lost_cover, _} = cost(result)
            cover = min(80 + 5 * (t - e.born), 100) - lost_cover
            state = if cover < 75, do: {:exposed, t + ceil((75 - cover) / 5)}, else: :hidden

            {agents, lost, pending, replacements} =
              if success?(result) do
                if s.replacements > 0,
                  do: {List.delete(s.agents, target), s.lost + 1, [t + 8 | s.pending], s.replacements - 1},
                  else: {List.delete(s.agents, target), s.lost + 1, s.pending, 0}
              else
                {s.agents, s.lost, s.pending, s.replacements}
              end

            %{
              s
              | enemies: Map.put(s.enemies, k, %{e | struck: true, state: state}),
                agents: agents,
                lost: lost,
                pending: pending,
                replacements: replacements,
                attempts: s.attempts + 1
            }

          true ->
            s
        end
      end)

    # the player's strikes: each agent under cover takes the best exposed target
    Enum.reduce(0..(length(s.agents) - 1)//1, s, fn i, s ->
      act(i, s, profile, p, 2)
    end)
  end

  defp act(_i, s, _profile, _p, 0), do: s

  defp act(i, s, profile, p, left) do
    agent = Enum.at(s.agents, i)
    attack = 18 * agent.pts + profile.bonus

    best =
      s.enemies
      |> Enum.filter(fn {_k, e} -> match?({:exposed, _}, e.state) end)
      |> Enum.map(fn {k, e} -> {Wave.Intel.success_chance(attack, agent.level, 10 * e.level), k, e} end)
      |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    case best do
      {odds, k, e} when agent.cover >= 75 and odds >= p.min_odds ->
        if :rand.uniform() < profile.attention do
          result = roll(attack, agent.level, 10 * e.level)
          {lost_cover, xp} = cost(result)
          agent = gain(%{agent | cover: agent.cover - lost_cover}, xp, p)

          {enemies, kills} =
            if success?(result),
              do: {Map.put(s.enemies, k, %{e | state: :dead}), s.kills + 1},
              else: {s.enemies, s.kills}

          s = %{s | agents: List.replace_at(s.agents, i, agent), enemies: enemies, kills: kills, strikes: s.strikes + 1}
          act(i, s, profile, p, left - 1)
        else
          s
        end

      _ ->
        s
    end
  end

  def ramp(final, from_step, to_step) do
    fn t ->
      cond do
        t <= from_step -> 0.0
        t >= to_step -> final * 1.0
        true -> final * (t - from_step) / (to_step - from_step)
      end
    end
  end

  def summarize(label, profile, p, runs \\ 400) do
    results = for _ <- 1..runs, do: run(profile, p)
    kills = results |> Enum.map(& &1.kills) |> Enum.sort()
    avg = fn key -> Float.round(Enum.sum(Enum.map(results, &Map.get(&1, key))) / runs, 1) end
    pct = fn q -> Enum.at(kills, min(trunc(q * runs), runs - 1)) end

    :io.format(
      "~-34s kills ~5.1f  (p10 ~3w  p50 ~3w  p90 ~3w)  exposures ~6.1f  strikes ~5.1f  lost ~4.1f of ~4.1f attempts~n",
      [
        label,
        Enum.sum(kills) / runs,
        pct.(0.1),
        pct.(0.5),
        pct.(0.9),
        avg.(:reveals),
        avg.(:strikes),
        avg.(:lost),
        avg.(:attempts)
      ]
    )
  end
end

:rand.seed(:exsss, {1, 2, 3})

levels = for n <- 1..Daily.Headhunter.total(), do: Daily.Headhunter.recruit("2026-10-27", n).level
IO.puts("roster levels: " <> inspect(Enum.frequencies(levels) |> Enum.sort()))
IO.puts("bold: #{Enum.count(1..Daily.Headhunter.total(), &Daily.Headhunter.recruit("2026-10-27", &1).bold?)}")

IO.puts("\nexposure chance (rows: Intelligence, columns: level 1..9)")

for intel <- [25, 50, 75, 100, 150, 200, 250, 300] do
  row = for l <- 1..9, do: :io_lib.format("~5.1f%", [Daily.Headhunter.reveal_chance(intel, l) * 100])
  roster = for n <- 1..Daily.Headhunter.total(), do: Daily.Headhunter.recruit("2026-10-27", n)
  seen = Enum.count(roster, &Daily.Headhunter.exposed?(intel, &1.level, &1.evasion))
  IO.puts(String.pad_leading("#{intel}", 4) <> "  " <> Enum.join(row, " ") <> "   exposes #{seen} of #{length(roster)}")
end

# steps are 15 s: step 8 = minute 2, step 48 = minute 12
profiles = [
  {"no intel, 1 Erased", %{intel: Sim.ramp(0, 8, 48), joins: [12], attention: 0.6, bonus: 0, replacements: 1}},
  {"intel 50, 1 Erased", %{intel: Sim.ramp(50, 8, 40), joins: [12], attention: 0.6, bonus: 0, replacements: 1}},
  {"intel 100, 1 Erased", %{intel: Sim.ramp(100, 8, 40), joins: [12], attention: 0.7, bonus: 0, replacements: 1}},
  {"intel 100, 2 Erased", %{intel: Sim.ramp(100, 8, 40), joins: [8, 16], attention: 0.7, bonus: 0, replacements: 2}},
  {"intel 150, 2 Erased", %{intel: Sim.ramp(150, 8, 44), joins: [8, 16], attention: 0.8, bonus: 0, replacements: 2}},
  {"intel 200, 2 Erased", %{intel: Sim.ramp(200, 8, 48), joins: [8, 16], attention: 0.8, bonus: 0, replacements: 2}},
  {"intel 200, 4 Erased",
   %{intel: Sim.ramp(200, 8, 48), joins: [8, 12, 24, 36], attention: 0.8, bonus: 0, replacements: 3}},
  {"intel 300, 2 Erased", %{intel: Sim.ramp(300, 8, 56), joins: [8, 16], attention: 0.9, bonus: 0, replacements: 2}},
  {"intel 300, 4 Erased",
   %{intel: Sim.ramp(300, 8, 56), joins: [8, 12, 24, 36], attention: 0.9, bonus: 0, replacements: 3}},
  {"intel 300, 6 Erased + lex",
   %{intel: Sim.ramp(300, 8, 56), joins: [8, 12, 20, 28, 36, 44], attention: 0.9, bonus: 25, replacements: 4}},
  {"intel 100, 6 Erased + lex",
   %{intel: Sim.ramp(100, 8, 40), joins: [8, 12, 20, 28, 36, 44], attention: 0.9, bonus: 25, replacements: 4}}
]

# Other level rules to compare with Daily.Headhunter.level_band/1
# (SIM_VARIANTS=levels). A window is 2 minutes (8 arrivals); `k` counts them.
band_level = fn n, band ->
  {lo, hi} = band.(div(n * 15, 120))
  lo + rem(:erlang.phash2({"2026-10-27", n}, 65_536), hi - lo + 1)
end

with_levels = fn band ->
  %{
    Sim.defaults()
    | recruit: fn n -> %{Daily.Headhunter.recruit("2026-10-27", n) | level: band_level.(n, band)} end
  }
end

variants =
  case System.get_env("SIM_VARIANTS") do
    nil ->
      [{"as built", Sim.defaults()}]

    "removal" ->
      [
        {"as built: enemy removal skill is half the level", Sim.defaults()},
        {"half the level, 5 points at most", %{Sim.defaults() | enemy_points: &min(div(&1 + 1, 2), 5)}},
        {"a third of the level", %{Sim.defaults() | enemy_points: &div(&1 + 2, 3)}}
      ]

    "levels" ->
      [
        {"as built: 1..3, average +0.75 per 2 min (1..24 at the end)", Sim.defaults()},
        {"1..1, top +1 per 2 min, no cap (1..15 at the end)", with_levels.(fn k -> {1, 1 + k} end)},
        {"1..1, top +1 per 2 min to 9, then the bottom rises", with_levels.(fn k -> {max(1, k - 7), min(1 + k, 9)} end)}
      ]

    _ ->
      [
        {"as built (20% per 25 Intelligence, over level)", Sim.defaults()},
        {"12% per step", %{Sim.defaults() | per_step: 0.12}},
        {"30% per step", %{Sim.defaults() | per_step: 0.3}}
      ]
  end

for {name, p} <- variants do
  IO.puts("\n== #{name}")
  roster = for n <- 1..Daily.Headhunter.total(), do: p.recruit.(n)
  mean = fn recruits -> Float.round(Enum.sum(Enum.map(recruits, & &1.level)) / length(recruits), 1) end

  seen =
    for intel <- [50, 100, 200, 300],
        do: {intel, Enum.count(roster, &Daily.Headhunter.exposed?(intel, &1.level, &1.evasion))}

  IO.puts("levels: " <> inspect(roster |> Enum.map(& &1.level) |> Enum.frequencies() |> Enum.sort()))
  IO.puts("mean level per 4 minutes: " <> inspect(roster |> Enum.chunk_every(16) |> Enum.map(mean)))
  IO.puts("exposed at Intelligence: " <> inspect(seen))

  for {label, profile} <- profiles, do: Sim.summarize(label, profile, p)
end
