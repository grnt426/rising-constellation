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
      thumbnail: map.thumbnail,
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
      thumbnail: map.thumbnail,
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
end
