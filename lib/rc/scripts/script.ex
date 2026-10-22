defmodule RC.Scripts.Script do
  @moduledoc """
  A scenario script saved to an account. Every field but `layout` is derived
  on the server from the script itself (`RC.Scripts`): the client sends a
  tree or text, never a name, a digest or an error count.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "edict_scripts" do
    field(:name, :string)
    field(:description, :string, default: "")
    field(:source, :string)
    field(:program, :map)
    field(:layout, :map, default: %{})
    field(:digest, :string)
    field(:error_count, :integer, default: 0)
    field(:published_at, :utc_datetime_usec)

    belongs_to(:author, RC.Accounts.Account, foreign_key: :author_id)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:name, :description, :source, :program, :layout, :digest, :error_count]

  @doc false
  def changeset(script, attrs) do
    script
    |> cast(attrs, @fields)
    |> validate_required([:name, :source, :program, :digest])
    |> validate_length(:name, max: 60)
    |> RC.DisplayName.validate_display_name(:name)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:digest,
      name: :edict_scripts_published_digest_index,
      message: "is already published"
    )
  end

  @doc false
  def publish_changeset(script, published_at) do
    script
    |> change(published_at: published_at)
    |> unique_constraint(:digest,
      name: :edict_scripts_published_digest_index,
      message: "is already published"
    )
  end
end
