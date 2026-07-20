defmodule Headless.Flags do
  @moduledoc """
  Experiment flags: parallel A/B attribution for DT changes (user pivot
  2026-07-18; the first batch is shaped by docs/game-ai-human-strategy.md).

  The one-lever-per-restart discipline capped development at ~1 change/day.
  Flags replace serializing the calendar with stratifying the data: each DT
  change lands behind a named flag, the marathon assigns a random on/off set
  PER ITERATION to the EVOLVER bot only (opponents always play baseline),
  and stamps the assignment into every results.jsonl line. Every flag gets
  its own A/B readout from the same night — ~50% of evals per arm — and a
  winning arm gets hard-coded, its flag deleted.

  A flag is OFF by default everywhere, so baseline behavior stays the
  shipped behavior: policy code must read flags only through `on?/2`, and
  an absent assignment (older archives, headless.run, tests) means
  all-off.
  """

  # Round-2 verdicts (24h A/B, 2026-07-19, n=1165 — see game-ai-learnings.md):
  # first_colony_guarantee + dominion_slot_gate WON and are hard-coded;
  # cap_rung_guarantee (colonies -0.37, ideology starvation),
  # income_gated_lanes (fit -19), train_on_neutrals (fit -24, VP delay)
  # LOST and are deleted with their genes.
  @flags %{
    "quality_siting" =>
      "colony targets ranked by code doctrine strength(3.0)+proximity(1.0) instead of the genome's colonize list (human doctrine 2b: quality dominates distance)",
    "dev_ladder" =>
      "per-system development ladder: prod floor (prod_floor gene) after growth gates, specialization blend by best body factor, 4-hab-per-body cap (human doctrine 3b)"
  }

  def all, do: Map.keys(@flags)
  def describe, do: @flags

  @doc "Random on/off per flag — one assignment per marathon iteration."
  def assign(rng \\ &:rand.uniform/0), do: Map.new(all(), fn f -> {f, rng.() < 0.5} end)

  @doc "Read a flag from policy mem. Absent assignment = off = baseline."
  def on?(mem, name) do
    flags = Map.get(mem, :flags) || %{}
    Map.get(flags, name, false) == true
  end

  @doc ~S(Parse a CLI spec: "all" | "none" | "flag1,flag2".)
  def parse("all"), do: Map.new(all(), &{&1, true})
  def parse("none"), do: Map.new(all(), &{&1, false})

  def parse(csv) when is_binary(csv) do
    on = csv |> String.split(",", trim: true) |> MapSet.new()

    unknown = MapSet.difference(on, MapSet.new(all()))
    if MapSet.size(unknown) > 0, do: raise(ArgumentError, "unknown flags: #{Enum.join(unknown, ", ")}")

    Map.new(all(), &{&1, MapSet.member?(on, &1)})
  end
end
