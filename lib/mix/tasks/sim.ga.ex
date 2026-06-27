defmodule Mix.Tasks.Sim.Ga do
  use Mix.Task

  @shortdoc "Evolve Pareto-optimal fleet designs with NSGA-II"

  @moduledoc """
  Run the multi-objective fleet search and print the Pareto front.

      mix sim.ga            # early stage
      mix sim.ga mid
      mix sim.ga late

  Default objectives: effectiveness (survival margin vs the gauntlet) vs credit
  cost vs unlock cost. The front shows surviving bombing power too.
  """

  @impl true
  def run(args) do
    Sim.Setup.ensure_installed()

    stage =
      case args do
        [s | _] -> String.to_atom(s)
        _ -> :early
      end

    IO.puts("NSGA-II fleet search — stage=#{stage}\n")

    result =
      Sim.GA.run(stage,
        pop_size: 48,
        generations: 30,
        battles: 10,
        base_seed: 1,
        on_generation: fn g, pop ->
          if rem(g, 5) == 0 do
            best = Enum.max_by(pop, & &1.metrics.margin)
            m = best.metrics
            IO.puts("  gen #{pad(g, 2)}: best margin #{Float.round(m.margin, 2)}  (#{round(m.win_rate * 100)}% win, credit #{m.credit})")
          end
        end
      )

    front = Enum.sort_by(result.front, fn i -> -i.metrics.margin end)

    IO.puts("\nPareto front — #{length(front)} non-dominated designs (objectives=#{inspect(result.objective_names)}):\n")
    IO.puts("  margin\twin%\tcredit\tunlock\tbomb\tships\tcomposition")

    Enum.each(front, fn ind ->
      m = ind.metrics

      IO.puts(
        "  #{Float.round(m.margin, 2)}\t#{round(m.win_rate * 100)}%\t#{m.credit}\t#{m.unlock}\t#{m.bomb}\t#{m.ships}\t#{Sim.GA.describe(ind.genome, stage)}"
      )
    end)
  end

  defp pad(n, width), do: String.pad_leading(to_string(n), width)
end
