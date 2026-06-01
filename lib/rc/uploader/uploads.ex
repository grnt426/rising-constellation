defmodule RC.Uploader.Upload do
  use Ecto.Schema
  use Waffle.Ecto.Schema

  import Ecto.Changeset
  import Filtrex.Type.Config

  alias RC.Uploader.StandardFile
  alias RC.Uploader.ImageFile

  @invalid_formats ~w(image)

  schema "uploads" do
    field(:name, :string)
    field(:file, StandardFile.Type)
    field(:thumb_file, ImageFile.Type)
    field(:medium_file, ImageFile.Type)
    field(:content_type, :string)
    belongs_to(:account, RC.Accounts.Account)

    timestamps()
  end

  def filter_options do
    defconfig do
      text(:name)
      text(:content_type)
      number(:account_id)
    end
  end

  def changeset(file, params) do
    file
    |> cast(params, [:name, :account_id, :content_type])
    |> cast_attachments(params, [:file], allow_paths: true)
    |> validate_exclusion(:content_type, @invalid_formats)
    |> validate_required([:name, :account_id, :content_type])
    # Stage 5 #B1.3 fix. Column is `text` in Postgres with no DB-side cap;
    # the old changeset accepted arbitrary-length names that bloated the
    # uploads table over time. 200 chars is generous for any filename.
    |> validate_length(:name, max: 200)
  end
end
