defmodule Portal.OgImage do
  @moduledoc """
  Link-preview (og:image) PNGs for Forge maps/scenarios and game lobbies,
  rendered from the row's own `game_data`, so a preview never depends on
  a stored thumbnail existing or being current.

    * maps and scenarios: the Forge thumbnail render
      (RC.Scenarios.ThumbnailRenderer);
    * lobbies: the lobby's map, with sectors in their assigned faction's
      colors, drawn by the game-view renderer the Discord news cards use
      (RC.Discord.Render.GalaxyMap).

  Both are oriented like the game (RC.GalaxyView). Served by
  Portal.OgImageController at `/og/:kind/:share_token.png`. The URL
  carries `?v=` (renderer version + geometry fingerprint), so an edited
  map or a renderer change gets a new URL and scrapers refetch it.
  Rendered PNGs are cached on local disk under that same fingerprint.
  """

  alias RC.Discord.Render
  alias RC.Discord.Render.GalaxyMap
  alias RC.Scenarios.ThumbnailRenderer

  # Bump when the lobby render changes (maps follow ThumbnailRenderer's).
  @lobby_version 1
  @width 400

  @doc "Absolute og:image URL for a map, scenario or instance row."
  def url(kind, row) when kind in [:map, :scenario, :instance] do
    "#{Portal.Endpoint.url()}/og/#{kind}/#{row.share_token}.png?v=#{fingerprint(kind, row)}"
  end

  @doc "`{:ok, png}` for the row, rendering (and caching) it on first use."
  def png(kind, row) do
    path = Path.join(cache_dir(), "#{kind}-#{row.id}-#{fingerprint(kind, row)}.png")

    case File.read(path) do
      {:ok, png} ->
        {:ok, png}

      _ ->
        with {:ok, png} <- Render.rasterize(svg(kind, row), @width) do
          File.mkdir_p(cache_dir())
          File.write(path, png)
          {:ok, png}
        end
    end
  end

  defp svg(:instance, instance) do
    game_data = lobby_game_data(instance)
    sectors = game_data["sectors"] || []
    ownership = %{systems: %{}, sectors: Map.new(sectors, &{&1["key"], &1["faction"]})}

    ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@width}" viewBox="0 0 #{@width} #{@width}">) <>
      GalaxyMap.render_nested(game_data, ownership, 0, 0, @width) <> "</svg>"
  end

  defp svg(_kind, row), do: ThumbnailRenderer.render(row.game_data || %{})

  # The lobby map (InstanceMap.vue) sizes the galaxy by game_metadata.
  defp lobby_game_data(instance) do
    game_data = instance.game_data || %{}
    size = game_data["size"] || (instance.game_metadata || %{})["size"]
    if size, do: Map.put(game_data, "size", size), else: game_data
  end

  defp fingerprint(kind, row) do
    game_data = row.game_data || %{}
    geometry = Map.take(game_data, ["size", "systems", "sectors", "blackholes"])
    version = if kind == :instance, do: "l#{@lobby_version}", else: "t#{ThumbnailRenderer.version()}"
    "#{version}-#{:erlang.phash2(geometry) |> Integer.to_string(36)}"
  end

  defp cache_dir, do: Path.join(System.tmp_dir!(), "rc-og")
end
