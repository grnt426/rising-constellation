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
  # cap_rung_guarantee, income_gated_lanes, train_on_neutrals LOST + deleted.
  #
  # Verdict log (see game-ai-learnings.md):
  #   WON, hard-coded: first_colony_guarantee, dominion_slot_gate,
  #     dev_ladder, quality_siting (the last a champion-advancer — its
  #     frontier read, top-20% fitness 446 vs 386, beat its mean read).
  #   LOST, deleted: cap_rung_guarantee, income_gated_lanes,
  #     train_on_neutrals, second_lane (guarantee fired 0x — wrong
  #     bottleneck), expansion_ideo_share (zero-colony 50% vs 30% —
  #     starved economy/covert ideology; the cap ladder wasn't
  #     ideology-limited).
  #
  # No flags are live right now. The infrastructure stays: the next round
  # (champion-focused fitness redesign, judged on the FRONTIER not the
  # mean) will add flags here again.
  @flags %{}

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
