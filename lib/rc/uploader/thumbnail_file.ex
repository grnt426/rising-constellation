defmodule RC.Uploader.ThumbnailFile do
  @moduledoc """
    The definition module for thumbnail files.

    To get the URLs of the image:
    - thumbnail: `RC.Uploader.ThumbnailFile.url({filename, %{account_id: id}}, :thumb)`

    The filename should be the same as when it was uploaded.
  """
  use Waffle.Definition
  use Waffle.Ecto.Definition

  @versions ~w(thumb)a

  def acl(:thumb, _), do: :public_read

  def transform(:thumb, _) do
    {:convert, "-resize x400"}
  end

  # Whitelist file extensions. The first clause used to pattern-match on
  # `%RC.Scenarios.Map{}`, which created a compile-time cycle (Map depends
  # on ThumbnailFile.Type, ThumbnailFile depends on Map). Switched to a
  # runtime `is_struct/2` check so the static dep is broken. Behavior is
  # identical — both clauses validated the same fields and the only diff
  # was the extra `is_map == true` invariant on the Map scope.
  def validate({file, scope}) when is_struct(scope, RC.Scenarios.Map) do
    [valid_image_extensions: valid_image_extensions, max_image_size: max_image_size] =
      Application.get_env(:rc, RC.Uploader)

    Enum.member?(valid_image_extensions, Path.extname(file.file_name)) and
      File.stat!(file.path).size <= max_image_size and scope.is_map == true
  end

  def validate({file, _scope}) do
    [valid_image_extensions: valid_image_extensions, max_image_size: max_image_size] =
      Application.get_env(:rc, RC.Uploader)

    Enum.member?(valid_image_extensions, Path.extname(file.file_name)) and
      File.stat!(file.path).size <= max_image_size
  end

  # Override the persisted filenames:
  def filename(version, {file, _}) do
    original_name = Enum.at(String.split(file.file_name, "."), 0)
    original_name <> "_" <> Atom.to_string(version)
  end

  # Override the storage directory:
  def storage_dir(_version, {_file, scope}) do
    storage_dir = Application.get_env(:waffle, :storage_dir)
    thumbnail_path = Application.get_env(:rc, RC.Uploader.ThumbnailFile) |> Keyword.get(:path)

    Path.join([
      storage_dir,
      thumbnail_path,
      "scenarios",
      "#{scope.id}"
    ])
  end

  # Provide a default URL if there hasn't been a file uploaded
  # def default_url(version, scope) do
  #   Application.get_env(:uploads, :url)
  #   |> URI.merge("/scenarios/#{scope.id}/thumbnails")
  # end

  # Specify custom headers for s3 objects
  # Available options are [:cache_control, :content_disposition,
  #    :content_encoding, :content_length, :content_type,
  #    :expect, :expires, :storage_class, :website_redirect_location]
  #
  # def s3_object_headers(version, {file, scope}) do
  #   [content_type: MIME.from_path(file.file_name)]
  # end
end
