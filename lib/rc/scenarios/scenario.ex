defmodule RC.Scenarios.Scenario do
  use Ecto.Schema
  use Waffle.Ecto.Schema
  import Ecto.Changeset

  alias RC.Uploader.ThumbnailFile

  schema "scenarios" do
    field(:game_data, :map)
    field(:game_metadata, :map)
    field(:is_map, :boolean)
    field(:is_official, :boolean, default: false)
    field(:published_at, :utc_datetime_usec)
    field(:thumbnail, ThumbnailFile.Type)
    field(:likes, :integer, virtual: true)
    field(:dislikes, :integer, virtual: true)
    field(:favorites, :integer, virtual: true)

    belongs_to(:author, RC.Accounts.Account, foreign_key: :author_id)

    many_to_many(:folders, RC.Scenarios.Folder,
      join_through: "scenarios_folders",
      on_delete: :delete_all,
      on_replace: :delete
    )

    timestamps(type: :utc_datetime_usec)
  end

  # See RC.Scenarios.Map for the rationale on the whitelist; identical here.
  @castable_attrs [:game_data, :game_metadata, :is_map]
  @castable_attrs_with_thumbnail @castable_attrs ++ [:thumbnail]

  @doc false
  def changeset(scenario, attrs) do
    scenario
    |> cast(attrs, @castable_attrs)
    |> validate_required([:game_data, :game_metadata, :is_map])
  end

  @doc false
  def changeset_reuse_thumbnail(scenario, attrs) do
    scenario
    |> cast(attrs, @castable_attrs_with_thumbnail)
    |> validate_required([:game_data, :game_metadata, :is_map, :thumbnail])
  end

  @doc false
  def changeset_no_thumbnail(scenario, attrs) do
    scenario
    |> cast(attrs, @castable_attrs)
    |> validate_required([:game_data, :game_metadata, :is_map])
  end

  @doc """
  Stamps `author_id` on insert. Used by the context's `create_scenario/2,3`;
  never driven by user-supplied attrs.
  """
  def put_author(changeset, account_id) when is_integer(account_id) do
    put_change(changeset, :author_id, account_id)
  end

  @doc """
  Stamps `published_at` with the current UTC time. Driven by the explicit
  Publish action — the regular update path leaves drafts as drafts.
  """
  def publish_changeset(scenario) do
    change(scenario, %{published_at: DateTime.utc_now()})
  end

  def thumbnail_changeset(scenario, attrs) do
    scenario
    |> cast_attachments(attrs, [:thumbnail])
    |> validate_required([:thumbnail])
  end
end
