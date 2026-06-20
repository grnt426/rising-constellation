defmodule Mix.Tasks.Sim.Demo do
  use Mix.Task

  @shortdoc "Run sample headless fleet battles and print the results"

  @moduledoc """
  Smoke-test / showcase for the headless battle simulator.

      mix sim.demo

  Builds two early-game fleets, runs a reproducible 100-battle matchup with
  Common Random Numbers, prints the aggregate, demonstrates determinism
  (same seed -> identical result), and prints a small round-robin payoff
  matrix over a few early-game ship variants with per-fleet cost.

  Runs in-process; no database or running game instance required.
  """

  @impl true
  def run(_args) do
    Sim.Setup.ensure_installed()

    IO.puts("== Single matchup: 6x interceptor stacks vs 6x light corvettes ==")
    att = Sim.Fleet.mono(:fighter_4, 6, id: 1)
    def_ = Sim.Fleet.mono(:corvette_1, 6, id: 2)

    IO.inspect(Sim.Cost.build_cost(List.duplicate(:fighter_4, 6)), label: "attacker build cost")
    IO.inspect(Sim.Cost.build_cost(List.duplicate(:corvette_1, 6)), label: "defender build cost")

    summary = Sim.Arena.matchup(att, def_, n: 100)
    IO.inspect(summary, label: "matchup (100 battles, CRN)")

    r1 = Sim.Arena.battle(att, def_, 42)
    r2 = Sim.Arena.battle(att, def_, 42)
    IO.puts("determinism (seed 42 run twice identical?): #{r1 == r2}")

    IO.puts("\n== Round-robin payoff matrix over a few early variants ==")
    keys = [:fighter_2, :fighter_4, :corvette_1, :corvette_2]
    rr = Sim.Arena.round_robin(keys, tiles: 9, n: 20)

    Enum.each(rr.matrix, fn {{a, b}, s} ->
      IO.puts(
        "  #{pad(a)} vs #{pad(b)}: " <>
          "#{a} wins #{s.attacker_wins}/#{s.n}, #{b} wins #{s.defender_wins}/#{s.n}, draws #{s.draws}"
      )
    end)

    IO.puts("\n  per-fleet cost (#{rr.tiles} tiles each):")

    Enum.each(rr.costs, fn {key, c} ->
      IO.puts("    #{pad(key)}: credit #{c.build.credit}, unlock(tech) #{c.unlock}")
    end)
  end

  defp pad(atom), do: String.pad_trailing(Atom.to_string(atom), 12)
end
