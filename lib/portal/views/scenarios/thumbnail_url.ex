defmodule Portal.ThumbnailUrl do
  @moduledoc """
  Builds the browser-facing URL for a Forge map/scenario thumbnail.
  Shared by MapView and ScenarioView (the Forge lists and detail pages).
  Link previews render their own image instead (Portal.OgImage).

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

  # `?v=` is the row's updated_at: a re-render (which bumps it) gets a new
  # URL, so browsers drop the old image at once. CloudFront's /uploads
  # policy ignores query strings; its copy ages out within max-age=900.
  def url(%{thumbnail: %{file_name: name}, id: id} = row)
      when is_binary(name) and is_integer(id) do
    [basename | _] = String.split(name, ".", parts: 2)
    "/uploads/thumbnails/scenarios/#{id}/#{basename}_thumb.png" <> version(row)
  end

  def url(_), do: nil

  defp version(%{updated_at: %DateTime{} = at}), do: "?v=#{DateTime.to_unix(at)}"
  defp version(_), do: ""
end
