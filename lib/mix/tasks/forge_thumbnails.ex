defmodule Mix.Tasks.Forge.Thumbnails do
  @moduledoc """
  Regenerate Forge map / scenario thumbnails from each row's game_data.

  Useful after the SVG renderer changes (so existing rows pick up the
  new colors / sizing / layout) and to backfill rows that were created
  before the server-side rendering pipeline existed.

      $ mix forge.thumbnails           # regenerate every row
      $ mix forge.thumbnails maps      # only maps
      $ mix forge.thumbnails scenarios # only scenarios
  """
  use Mix.Task

  import Ecto.Query, warn: false

  alias RC.Repo
  alias RC.Scenarios

  @shortdoc "Regenerate Forge map/scenario thumbnails from game_data"

  def run(args) do
    Mix.Task.run("app.start")

    {maps, scenarios} =
      case args do
        ["maps"] -> {true, false}
        ["scenarios"] -> {false, true}
        _ -> {true, true}
      end

    if maps, do: run_for(:maps)
    if scenarios, do: run_for(:scenarios)
  end

  defp run_for(:maps) do
    rows = Repo.all(from(m in RC.Scenarios.Map, where: m.is_map == true))
    Mix.shell().info("Regenerating thumbnails for #{length(rows)} map(s)…")

    Enum.each(rows, fn row ->
      case Scenarios.regenerate_map_thumbnail(row) do
        {:ok, _} -> Mix.shell().info("  ok  ##{row.id} #{name_of(row)}")
        {:error, reason} -> Mix.shell().error("  err ##{row.id} #{name_of(row)}: #{inspect(reason)}")
      end
    end)
  end

  defp run_for(:scenarios) do
    rows = Repo.all(from(s in RC.Scenarios.Scenario, where: s.is_map == false))
    Mix.shell().info("Regenerating thumbnails for #{length(rows)} scenario(s)…")

    Enum.each(rows, fn row ->
      case Scenarios.regenerate_scenario_thumbnail(row) do
        {:ok, _} -> Mix.shell().info("  ok  ##{row.id} #{name_of(row)}")
        {:error, reason} -> Mix.shell().error("  err ##{row.id} #{name_of(row)}: #{inspect(reason)}")
      end
    end)
  end

  defp name_of(row) do
    case row.game_metadata do
      %{"name" => name} -> name
      _ -> "(unnamed)"
    end
  end
end
