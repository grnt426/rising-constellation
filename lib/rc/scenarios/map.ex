defmodule RC.Scenarios.Map do
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
    # Stage 4 (mini) — see RC.Scenarios.Scenario.
    field(:plays, :integer, virtual: true)

    belongs_to(:author, RC.Accounts.Account, foreign_key: :author_id)

    many_to_many(:folders, RC.Scenarios.Folder,
      join_through: "scenarios_folders",
      join_keys: [scenario_id: :id, folder_id: :id],
      on_delete: :delete_all,
      on_replace: :delete
    )

    timestamps(type: :utc_datetime_usec)
  end

  # Whitelist of attrs an external (controller) caller is allowed to cast.
  # `author_id`, `is_official`, and `published_at` are deliberately omitted:
  # the server controls authorship on insert, "Official" requires an admin
  # endpoint, and publishing flips via `publish_changeset/1` only.
  @castable_attrs [:game_data, :game_metadata, :is_map]

  @doc false
  def changeset(map, attrs) do
    map
    |> cast(attrs, @castable_attrs)
    |> validate_change(:is_map, fn :is_map, is_map_bool ->
      if is_map_bool,
        do: [],
        else: [is_map: "must be true when manipulating a map"]
    end)
    |> validate_required([:game_data, :game_metadata, :is_map])
  end

  @doc false
  def changeset_no_thumbnail(map, attrs) do
    map
    |> cast(attrs, @castable_attrs)
    |> validate_change(:is_map, fn :is_map, is_map_bool ->
      if is_map_bool,
        do: [],
        else: [is_map: "must be true when manipulating a map"]
    end)
    |> validate_required([:game_data, :game_metadata, :is_map])
  end

  @doc """
  Stamps `author_id` on insert. Used by the context's `create_map/2`; never
  driven by user-supplied attrs.
  """
  def put_author(changeset, account_id) when is_integer(account_id) do
    put_change(changeset, :author_id, account_id)
  end

  @doc """
  Stamps `published_at` with the current UTC time. Driven by the explicit
  Publish action — the regular update path leaves drafts as drafts.
  """
  def publish_changeset(map) do
    change(map, %{published_at: DateTime.utc_now()})
  end

  def thumbnail_changeset(map, attrs) do
    map
    |> cast_attachments(attrs, [:thumbnail])
    |> validate_required([:thumbnail])
  end
end
