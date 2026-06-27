defmodule Sim.Strategy do
  @moduledoc """
  Strategic-goal fleet archetypes, as fitness functions, plus a cross-play
  matrix to compare them.

  Each strategic goal is a different NSGA-II objective set. Evolving each
  against a common *diverse* gauntlet yields that goal's strongest design;
  cross-playing the champions against one another reveals whether the meta has
  a **general-purpose** fleet (one design strong against most counters) or a
  **rock-paper-scissors** structure (best design depends on the opponent).

  Strategic goals modelled:
    * `:defense`   — hold a system: deny the attacker's raid power and win.
    * `:raid_soft` — pillage a backline; losses are acceptable (max delivered
      bombing power per credit, ignore survival).
    * `:raid_hard` — raid that must punch through defenses (max bombing power
      *and* win the fight).
    * `:intercept` — beat an unknown fleet (robust combat win).

  (A 5th, `:screen` — a cheap sacrificial fleet that delays/ties up the enemy —
  needs a time/economy model we don't have, so it's omitted.)
  """

  alias Sim.{GA, Fleet, Arena, Genome}

  @doc "Strategic goals as {objectives, champion-selection metric}."
  def strategies do
    [
      %{
        name: :defense,
        desc: "hold a system (deny raid + win)",
        objectives: [{:deny, :min, & &1.enemy_bomb}, {:eff, :max, & &1.margin}, {:cost, :min, & &1.credit}],
        pick: fn m -> -m.enemy_bomb end
      },
      %{
        name: :raid_soft,
        desc: "pillage backline, losses OK",
        objectives: [{:raid, :max, & &1.bomb}, {:cost, :min, & &1.credit}],
        pick: fn m -> m.bomb end
      },
      %{
        name: :raid_hard,
        desc: "raid through defenses",
        objectives: [{:raid, :max, & &1.bomb}, {:eff, :max, & &1.margin}, {:cost, :min, & &1.credit}],
        pick: fn m -> if m.margin > 0.0, do: m.bomb, else: m.bomb - 1000.0 end
      },
      %{
        name: :intercept,
        desc: "beat an unknown fleet",
        objectives: [{:eff, :max, & &1.margin}, {:cost, :min, & &1.credit}],
        pick: fn m -> m.margin end
      }
    ]
  end

  @doc """
  Evolve each strategy's strongest champion against a common diverse gauntlet.
  Returns a list of `%{name, desc, genome, metrics}`.
  """
  def champions(stage, opts \\ []) do
    gauntlet = diverse_gauntlet(stage)
    base = Keyword.merge([pop_size: 30, generations: 15, battles: 8, base_seed: 1], opts)

    Enum.map(strategies(), fn s ->
      res = GA.run(stage, base ++ [gauntlet: gauntlet, objectives: s.objectives])
      champ = Enum.max_by(res.front, fn ind -> s.pick.(ind.metrics) end)
      %{name: s.name, desc: s.desc, genome: champ.genome, metrics: champ.metrics}
    end)
  end

  @doc """
  Cross-play every champion (as attacker) against every champion (as defender).
  Returns one row per ordered pair with the metrics each side cares about.
  """
  def cross_play(champions, stage, opts \\ []) do
    n = Keyword.get(opts, :battles, 40)

    for a <- champions, d <- champions do
      fa = Fleet.from_genome(a.genome, stage, id: 1)
      fd = Fleet.from_genome(d.genome, stage, id: 2)
      m = Arena.matchup(fa, fd, n: n, base_seed: 1, parallel: true)

      %{
        attacker: a.name,
        defender: d.name,
        att_win: m.attacker_win_rate,
        att_bomb: m.mean_survival.attacker_bomb,
        def_bomb: m.mean_survival.defender_bomb,
        att_pv_frac: m.mean_survival.attacker_pv_frac
      }
    end
  end

  @doc "Coarse composition archetype: the ship base-types making up >= 20% of the fleet."
  def archetype(genome, stage) do
    slots = Genome.decode(genome, stage)
    total = max(length(slots), 1)

    slots
    |> Enum.map(fn {_t, key, _l} -> base_type(key) end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_t, c} -> c / total >= 0.2 end)
    |> Enum.map(fn {t, _c} -> t end)
    |> Enum.sort()
  end

  defp diverse_gauntlet(:early), do: mono([:fighter_4v2, :fighter_2v2, :corvette_1v2, :corvette_2v2, :fighter_3v2])
  defp diverse_gauntlet(:mid), do: mono([:fighter_4v4, :corvette_1v3, :corvette_3v3, :frigate_1, :frigate_2])
  defp diverse_gauntlet(:late), do: mono([:corvette_1v3, :frigate_1, :capital_1, :capital_2, :frigate_2])

  defp mono(keys) do
    tiles = Sim.Setup.tile_count()
    Enum.map(keys, fn k -> Fleet.mono(k, tiles, id: 2) end)
  end

  defp base_type(key) do
    case Regex.run(~r/^(.*?)v\d+$/, Atom.to_string(key)) do
      [_, base] -> String.to_existing_atom(base)
      _ -> key
    end
  end
end
