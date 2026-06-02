defmodule Portal.MapView do
  use Portal, :view
  import Phoenix.View, only: [render_one: 3, render_many: 3]
  alias Portal.MapView

  def render("index.json", %{maps: maps}) do
    render_many(maps, MapView, "map_partial.json")
  end

  def render("show.json", %{map: map}) do
    render_one(map, MapView, "map_full.json")
  end

  def render("edges.json", %{edges: edges}) do
    edges
  end

  def render("map_full.json", %{map: map}) do
    %{
      id: map.id,
      game_data: map.game_data,
      game_metadata: map.game_metadata,
      is_official: map.is_official,
      published_at: map.published_at,
      author: render_author(map.author),
      thumbnail: thumbnail_url(map),
      likes: map.likes,
      dislikes: map.dislikes,
      favorites: map.favorites
    }
  end

  def render("map_partial.json", %{map: map}) do
    %{
      id: map.id,
      game_metadata: map.game_metadata,
      is_official: map.is_official,
      published_at: map.published_at,
      author: render_author(map.author),
      thumbnail: thumbnail_url(map),
      likes: map.likes,
      dislikes: map.dislikes,
      favorites: map.favorites
    }
  end

  # Display name only — never leak email / role / settings out the public
  # list endpoints. NotLoaded means the caller forgot to preload :author
  # (treat as anonymous rather than crash).
  defp render_author(%RC.Accounts.Account{} = author), do: %{id: author.id, name: author.name}
  defp render_author(_), do: nil

  # Construct the URL the SPA hits to display the thumbnail. We don't
  # use Waffle.url/2 because its dev asset_host/storage_dir combo
  # produces "localhost/priv/storage/..." which has no scheme — the
  # endpoint's /uploads Plug.Static handles the real serving.
  defp thumbnail_url(%{thumbnail: %{file_name: name}, id: id})
       when is_binary(name) and is_integer(id) do
    [basename | _] = String.split(name, ".", parts: 2)
    "/uploads/thumbnails/scenarios/#{id}/#{basename}_thumb.png"
  end

  defp thumbnail_url(_), do: nil
end
