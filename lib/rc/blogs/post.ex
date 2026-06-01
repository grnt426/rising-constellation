defmodule RC.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset
  import Filtrex.Type.Config

  alias RC.Markdown
  alias RC.Blog.Category
  alias RC.Blog.TitleSlug

  schema "blog_posts" do
    field(:title, :string)
    field(:slug, :string)
    field(:content_html, :string)
    field(:content_raw, :string)
    field(:language, :string)
    field(:picture, :string)
    field(:summary_html, :string)
    field(:summary_raw, :string)
    belongs_to(:account, RC.Accounts.Account)
    belongs_to(:category, Category)

    timestamps(type: :utc_datetime_usec)
  end

  def filter_options do
    defconfig do
      text(:language)
      number(:account_id)
      number(:category_id)
    end
  end

  @doc false
  def changeset(blog_post, attrs) do
    blog_post
    # :account_id is intentionally NOT in the cast list — it must be set by
    # the controller from the JWT subject (Blog.create_post/2 does this via
    # put_change after the changeset). Otherwise a blog-writer could post
    # `{"account_id": <victim>}` and forge authorship.
    #
    # :account_id is also dropped from `validate_required/2` because the
    # caller injects it AFTER changeset/2 runs; the not-null DB constraint
    # plus Blog.create_post/2's `validate_required([:account_id])` step are
    # the enforcement points.
    |> cast(attrs, [:title, :picture, :content_raw, :summary_raw, :language, :category_id])
    |> validate_required([:title, :picture, :content_raw, :summary_raw, :language, :category_id])
    |> validate_length(:title, max: 120)
    |> RC.DisplayName.validate_display_name(:title)
    |> validate_length(:picture, max: 120)
    |> validate_length(:summary_raw, max: 1500)
    |> validate_length(:language, max: 2)
    # Stage 5 #B2.1 fix. Markdown rendering (Earmark + HtmlSanitizeEx)
    # runs synchronously inside the changeset on `content_raw`. Without
    # this cap a nested-blockquote bomb or other pathological markdown
    # pinned a worker on parsing for tens of seconds and persisted
    # tens of MB of nested HTML into the `content_html` column.
    # 200 KB is ≈50k words — a very long article. If real authors hit
    # this, the SPA surfaces it via the existing 422 changeset-error
    # display and we raise it server-side in a one-line follow-up.
    |> validate_length(:content_raw, max: 200_000)
    |> TitleSlug.maybe_generate_slug()
    |> Markdown.render_changeset(:content_raw, :content_html)
    |> Markdown.render_changeset(:summary_raw, :summary_html)
  end
end

defmodule RC.Blog.TitleSlug do
  use EctoAutoslugField.Slug, from: :title, to: :slug, always_change: true
end
