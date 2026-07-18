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

  @flags %{
    "first_colony_guarantee" =>
      "foundation may draw the FIRST transport from raw stock when the expansion pool starves (funnel stage-5 wall)",
    "cap_rung_guarantee" =>
      "at syscap, the next system-cap lex may draw from raw ideology when the expansion pool starves",
    "income_gated_lanes" =>
      "colonization lanes derive from income velocity (human doctrine 2a), not from open-slot count",
    "train_on_neutrals" =>
      "covert agents below agent_train_level train on neutrals before enemy work (human doctrine 3c)",
    "dominion_slot_gate" =>
      "make_dominion dispatch requires a free dominion slot (human doctrine 2d, tall default)"
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
