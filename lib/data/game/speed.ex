defmodule Data.Game.Speed do
  use TypedStruct
  use Util.MakeEnumerable

  def jason(), do: []

  typedstruct enforce: true do
    field(:key, atom())
    field(:value, integer())
    field(:factor, integer())
    # Whether scenario authors may choose this speed. The daily-challenge
    # speed (:daily) is selectable: false — the engine uses it but the
    # editor's picker (filtered in Portal.DataController) never offers it.
    field(:selectable, boolean(), default: true)
  end

  def specs do
    "Elixir." <> module = Atom.to_string(__MODULE__)
    module = "#{module}.Content"

    [
      %{metadata: [], content_name: "speed", module: module, sources: nil}
    ]
  end
end
