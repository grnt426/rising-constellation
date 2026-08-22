defmodule Portal.ThumbnailUrl do
  @moduledoc """
  Builds the browser-facing URL for a Forge map/scenario thumbnail.
  Shared by MapView, ScenarioView, and the /forge share pages.

  Two storage modes:

  * **Local (dev/test)** — the endpoint's `/uploads` Plug.Static serves
    `priv/storage`, so we hand back a root-relative path. We don't use
    `Waffle.url/2` here because the dev asset_host/storage_dir combo
    ("localhost" + "priv/storage") produces a scheme-less URL the
    browser resolves relative to the current page.

  * **S3 (prod)** — `Waffle.url/2` is correct: `S3_ASSET_HOST` carries
    the scheme, so the result is an absolute URL, and waffle_ecto
    appends a `?v=` cache-buster from the attachment's updated_at so a
    regenerated thumbnail isn't hidden by browser caching.
  """

  def url(%{thumbnail: %{file_name: name} = file, id: id} = row)
      when is_binary(name) and is_integer(id) do
    if s3?() do
      RC.Uploader.ThumbnailFile.url({file, row}, :thumb)
    else
      [basename | _] = String.split(name, ".", parts: 2)
      "/uploads/thumbnails/scenarios/#{id}/#{basename}_thumb.png"
    end
  end

  def url(_), do: nil

  @doc """
  Absolute variant for OpenGraph tags — scrapers need a full URL.
  S3 URLs already are; local ones get the endpoint origin prefixed.
  """
  def absolute_url(row) do
    case url(row) do
      nil -> nil
      "/" <> _ = path -> Portal.Endpoint.url() <> path
      absolute -> absolute
    end
  end

  defp s3?, do: Application.get_env(:waffle, :storage) == Waffle.Storage.S3
end
