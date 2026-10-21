defmodule Mix.Tasks.Edict.Editors do
  @shortdoc "Writes the Edict editor kit (VS Code, JetBrains, Notepad++, LSP) to a folder"
  @moduledoc """
  Writes the editor kit the Scenario Workshop offers for download, unpacked,
  so it can be tried or tested without the server:

      mix edict.editors [DIR]

  DIR defaults to `tmp/edict-editors`. See `Edict.EditorKit`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    dir = List.first(args) || "tmp/edict-editors"
    Edict.EditorKit.write(dir)
    Mix.shell().info("Edict editor kit #{Edict.EditorKit.version()} written to #{dir}")
  end
end
