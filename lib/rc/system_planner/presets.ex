defmodule RC.SystemPlanner.Presets do
  @moduledoc """
  Ready-made plans the system planner can open by name
  (`/portal/system-planner?preset=<name>`): the example systems the help
  manual links to (`{planner:<name>|…}`, `docs/help-manual.md`).

  One JSON file per preset in `priv/planner/presets/`, in the planner's plan
  format (`front/src/portal/planner/plan.js`). They are read at compile time,
  so a release needs nothing on disk, and the help compiler can check a
  page's `{planner:}` links without touching the game modules.
  """

  @dir Path.expand("priv/planner/presets", File.cwd!())
  @files @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

  for path <- @files do
    @external_resource path
  end

  # A new preset file is not an @external_resource of the previous compile.
  @doc false
  def __mix_recompile__?, do: @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort() != @files

  @presets Map.new(@files, fn path -> {Path.basename(path, ".json"), path |> File.read!() |> Jason.decode!()} end)

  @doc "Names of every preset, sorted."
  def names, do: @presets |> Map.keys() |> Enum.sort()

  @doc "The plan stored under `name`, as a JSON-ready map."
  def fetch(name) when is_binary(name), do: Map.fetch(@presets, name)
  def fetch(_), do: :error

  @doc "Source files (for `@external_resource` in modules that check names)."
  def files, do: @files
end
