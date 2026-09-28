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
    # Stage 4 (mini) — count of instances spawned from this scenario
    # that ever started running and had ≥1 registered player. Populated
    # by the list/show queries; not a column on the table.
    field(:plays, :integer, virtual: true)

    belongs_to(:author, RC.Accounts.Account, foreign_key: :author_id)

    # Stage 4 (mini) — every instance spawned from this scenario writes
    # the link back here. Used by the play-count subquery in
    # `RC.Scenarios.list_scenarios_query/0`.
    has_many(:instances, RC.Instances.Instance)

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
    |> validate_wave()
  end

  @doc false
  def changeset_reuse_thumbnail(scenario, attrs) do
    scenario
    |> cast(attrs, @castable_attrs_with_thumbnail)
    |> validate_required([:game_data, :game_metadata, :is_map, :thumbnail])
    |> validate_wave()
  end

  # A Rebel Defense scenario must be playable as one: Legacy speed, one human
  # faction and the Rebellion, each with a sector. See Wave.Lobby.
  defp validate_wave(changeset) do
    case get_field(changeset, :game_data) do
      %{} = game_data ->
        case Wave.Lobby.validate_scenario(game_data) do
          :ok -> mirror_mode(changeset, game_data)
          {:error, reason} -> add_error(changeset, :game_data, Atom.to_string(reason))
        end

      _ ->
        changeset
    end
  end

  # Scenario lists render game_metadata only, so the mode is mirrored there
  # for the "Rebel Defense" badge.
  defp mirror_mode(changeset, game_data) do
    metadata = get_field(changeset, :game_metadata) || %{}
    mode = if Wave.Lobby.wave?(game_data), do: Wave.mode_type()

    cond do
      Map.get(metadata, "game_mode_type") == mode -> changeset
      mode == nil -> put_change(changeset, :game_metadata, Map.delete(metadata, "game_mode_type"))
      true -> put_change(changeset, :game_metadata, Map.put(metadata, "game_mode_type", mode))
    end
  end

  @doc false
  def changeset_no_thumbnail(scenario, attrs) do
    scenario
    |> cast(attrs, @castable_attrs)
    |> validate_required([:game_data, :game_metadata, :is_map])
    |> validate_wave()
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
