defmodule RC.Uploader do
  @moduledoc """
  The uploads context.
  """

  import Ecto.Query, warn: false
  alias RC.Repo

  alias RC.Uploader.Upload
  alias RC.Uploader.ImageUpload

  @doc """
  Returns the list of uploads.

  Returns {:error, reason} if the filter parameters are invalid.

  ## Examples

      iex> list_uploads()
      {:ok, [%Upload{}, ...]}

      iex> list_uploads(invalid_filter_params)
      {:error, reason}

  """

  def list_uploads(params \\ %{}) do
    filtrex_params = params
    config = ImageUpload.filter_options()

    case Filtrex.parse_params(config, filtrex_params) do
      {:ok, filter} ->
        uploads =
          Upload
          |> preload(:account)
          |> Filtrex.query(filter)
          |> Repo.paginate()

        {:ok, uploads}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get a single upload.

  Returns `nil` if the id is invalid.

  ## Examples

      iex> get_upload(123)
      %Upload{}

      iex> get_upload(456)
      nil

  """
  def get_upload(id), do: Repo.get(Upload, id)

  @doc """
  Returns true if `upload_id` was uploaded by `account_id`. Used by the
  Portal.Plug.Authorization `:upid` clause to gate DELETE /uploads/:upid —
  blog-writer membership alone is too coarse (any writer could otherwise
  wipe any other user's uploads).
  """
  def own_upload?(account_id, upload_id) do
    Repo.exists?(
      from(u in Upload,
        where: u.account_id == ^account_id and u.id == ^upload_id
      )
    )
  end

  @doc """
  Deletes an upload.

  ## Examples

      iex> delete_upload(upload)
      {:ok, %Upload{}}

      iex> delete_upload(upload)
      {:error, %Ecto.Changeset{}}

  """
  def delete_upload(%Upload{} = upload) do
    Repo.delete(upload)
  end

  @doc """
  Creates a standard upload.

  ## Examples

      iex> create_upload(%{field: value})
      {:ok, %Upload{}}

      iex> create_upload(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_standard_upload(attrs \\ %{}) do
    %Upload{}
    |> Upload.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates an image upload.

  ## Examples

      iex> create_upload(%{field: value})
      {:ok, %ImageUpload{}}

      iex> create_upload(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_image_upload(attrs \\ %{}) do
    %ImageUpload{}
    |> ImageUpload.changeset(attrs)
    |> Repo.insert()
  end
end
