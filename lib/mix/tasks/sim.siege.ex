defmodule Mix.Tasks.Sim.Siege do
  use Mix.Task

  @shortdoc "Antagonistic bomb-power arena: siege (retain) vs denial (deny)"

  @moduledoc """
  Co-evolve a siege population (keep >= T bombing power through a fight) against
  a denial population (hold the enemy below T), at thresholds 20/40/60.

      mix sim.siege            # mid stage, thresholds 20 40 60
      mix sim.siege late
      mix sim.siege mid 40

  Prints the arms-race trajectory and the top designs each side evolves.
  """

  @impl true
  def run(args) do
    Sim.Setup.ensure_installed()
    {stage, thresholds} = parse(args)
    Enum.each(thresholds, fn t -> run_one(stage, t) end)
  end

  defp run_one(stage, t) do
    IO.puts("\n========== Siege arena: stage=#{stage}, threshold=#{t} bombing power ==========")

    res =
      Sim.GA.antagonize(stage, t,
        pop_size: 36,
        generations: 20,
        battles: 8,
        sample: 5,
        base_seed: 1,
        on_generation: fn g, s ->
          if rem(g, 5) == 0 do
            IO.puts("  gen #{pad(g, 2)}: siege P(retain>=#{t})=#{Float.round(s.siege_best_retain, 2)}   denial P(hold<#{t})=#{Float.round(s.denial_best_deny, 2)}")
          end
        end
      )

    show("SIEGE — best at retaining >= #{t} bomb power", res.siege_front, :bomb_ge, t, stage)
    show("DENIAL — best at holding enemy < #{t} bomb power", res.denial_front, :enemy_bomb_lt, t, stage)
  end

  defp show(label, front, metric_key, t, stage) do
    IO.puts("\n  #{label}:")
    IO.puts("    P\tcredit\townbomb\twin%\tcomposition")

    front
    |> Enum.sort_by(fn ind -> -Map.get(Map.fetch!(ind.metrics, metric_key), t, 0.0) end)
    |> Enum.take(5)
    |> Enum.each(fn ind ->
      m = ind.metrics
      p = Map.get(Map.fetch!(m, metric_key), t, 0.0)

      IO.puts("    #{Float.round(p, 2)}\t#{m.credit}\t#{m.bomb}\t#{round(m.win_rate * 100)}%\t#{Sim.GA.describe(ind.genome, stage)}")
    end)
  end

  defp parse([]), do: {:mid, [20, 40, 60]}
  defp parse([stage]), do: {String.to_atom(stage), [20, 40, 60]}
  defp parse([stage | thresholds]), do: {String.to_atom(stage), Enum.map(thresholds, &String.to_integer/1)}

  defp pad(n, w), do: String.pad_leading(to_string(n), w)
end
