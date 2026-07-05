defmodule Mix.Tasks.Sim.Blueprints do
  use Mix.Task

  @shortdoc "Evolve availability-conditioned fleet champions + counters, persist to JSON"

  @moduledoc """
  Run the patent-tier fleet-champion ladder (see `Sim.Blueprints`) and write
  the results under `--out` — one JSON per tier as it completes, plus a
  combined `blueprints.json`.

      mix sim.blueprints
      mix sim.blueprints --out tmp/fleet_arena --pop 32 --gens 20 --battles 8
      mix sim.blueprints --tiers t4_corvettes,t5_strike_groups --force
      mix sim.blueprints --no-counters        # skip best-response runs

  Tiers with an existing output file are skipped (resume-friendly for a
  detached run); `--force` redoes them. Dataset is always fast/prod with no
  stat overrides.
  """

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          pop: :integer,
          gens: :integer,
          battles: :integer,
          cross_battles: :integer,
          seed: :integer,
          tiers: :string,
          counters: :boolean,
          force: :boolean
        ]
      )

    tiers =
      case Keyword.get(opts, :tiers) do
        nil -> nil
        s -> s |> String.split(",") |> Enum.map(&String.to_atom(String.trim(&1)))
      end

    Sim.Blueprints.run(Keyword.put(opts, :tiers, tiers))
  end
end
