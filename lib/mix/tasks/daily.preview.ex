defmodule Mix.Tasks.Daily.Preview do
  use Mix.Task

  @shortdoc "Print the generated daily challenge for a date (default: today)"

  @moduledoc """
  Show what the daily-challenge generator produces for a given day.

      mix daily.preview                # today (UTC)
      mix daily.preview 2026-06-21     # a specific date
      mix daily.preview 2026-06-21 --all  # allow not-yet-wired mutators

  Pure and deterministic: same date always prints the same daily. No
  database or running game instance required — this exercises
  `Daily.Generator` / `Daily.Objective` only.
  """

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: [all: :boolean])

    date =
      case positional do
        [iso | _] -> iso
        [] -> Date.utc_today() |> Date.to_iso8601()
      end

    include_unimplemented = Keyword.get(opts, :all, false)
    game_data = Daily.Generator.for_date(date, include_unimplemented: include_unimplemented)
    objective = Daily.Objective.get(game_data["daily"]["objective"])
    [system] = game_data["systems"]

    IO.puts("== Daily challenge: #{date} ==")
    IO.puts("  system   : #{system["type"]} at (#{system["position"]["x"]}, #{system["position"]["y"]})")
    IO.puts("  sector   : #{hd(game_data["sectors"])["name"]}")
    IO.puts("  speed    : #{game_data["speed"]} (Legacy content, fast clock)")
    IO.puts("  time      : #{game_data["time_limit"]} min")
    IO.puts("  seed      : #{inspect(game_data["seed"])}")
    IO.puts("")
    IO.puts("  objective : #{objective.name} (#{objective.aggregation} #{objective.resource})")
    IO.puts("              #{objective.description}")
    IO.puts("")
    IO.puts("  mutators  :")

    Enum.each(game_data["mutators"], fn %{"key" => key} ->
      m = Data.Game.Mutator.get(key)
      flag = if m.implemented, do: " ", else: "*"
      IO.puts("    [#{polarity_glyph(m.polarity)}]#{flag} #{m.name} — #{m.description}")
    end)

    unless include_unimplemented do
      IO.puts("")
      IO.puts("  (only wired mutators are rolled; pass --all to include roadmap entries marked *)")
    end
  end

  defp polarity_glyph(:positive), do: "+"
  defp polarity_glyph(:negative), do: "-"
  defp polarity_glyph(_), do: "?"
end
