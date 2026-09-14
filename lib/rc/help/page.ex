defmodule RC.Help.Page do
  @moduledoc """
  One help-manual page. Built from `priv/help/<lang>/<category>/<slug>.md`
  by `RC.Help.Source` (frontmatter + raw body) and completed by
  `RC.Help.Compiler` (`html` per speed, plain `text`, `speed_sensitive`).

  See `docs/help-manual.md` §3 for the content model.
  """

  @type speed :: :fast | :medium | :slow

  @type t :: %__MODULE__{
          slug: String.t(),
          title: String.t() | nil,
          category: String.t(),
          kind: :mechanic | :guide | :catalog | :index,
          guide: String.t() | nil,
          icon: String.t() | nil,
          terms: [String.t()],
          related: [String.t()],
          aliases: [String.t()],
          sources: [String.t()],
          status: String.t(),
          lang: String.t(),
          path: String.t() | nil,
          body: String.t(),
          html: %{optional(speed) => String.t()},
          text: String.t(),
          speed_sensitive: boolean()
        }

  defstruct slug: nil,
            title: nil,
            category: "misc",
            kind: :mechanic,
            guide: nil,
            icon: nil,
            terms: [],
            related: [],
            aliases: [],
            sources: [],
            status: "draft",
            lang: "en",
            path: nil,
            body: "",
            html: %{},
            text: "",
            speed_sensitive: false
end
