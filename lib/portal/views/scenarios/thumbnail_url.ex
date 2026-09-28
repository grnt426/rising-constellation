defmodule Portal.ThumbnailUrl do
  @moduledoc """
  Builds the browser-facing URL for a Forge map/scenario thumbnail.
  Shared by MapView, ScenarioView, and the /forge + SPA share pages.

  Always site-relative `/uploads/...`, regardless of the storage
  backend — the serving path differs behind the origin, never the URL:

  * **Local storage** (dev, or prod's fallback) — the endpoint's
    `/uploads` Plug.Static serves priv/storage.
  * **S3 storage** (prod) — object keys carry the same `uploads/`
    prefix as the URL path and nginx proxies `/uploads/*` to the
    bucket (see deploy/nginx/rc.conf.example).

  Either way CloudFront caches the response under its `/uploads/*`
  behavior, which is what lets a Forge page full of thumbnails load
  from edge caches instead of hammering the host.
  """

  def url(%{thumbnail: %{file_name: name}, id: id})
      when is_binary(name) and is_integer(id) do
    [basename | _] = String.split(name, ".", parts: 2)
    "/uploads/thumbnails/scenarios/#{id}/#{basename}_thumb.png"
  end

  def url(_), do: nil

  @doc """
  Absolute variant for OpenGraph tags — scrapers need a full URL.
  """
  def absolute_url(row) do
    case url(row) do
      nil -> nil
      path -> Portal.Endpoint.url() <> path
    end
  end
end
