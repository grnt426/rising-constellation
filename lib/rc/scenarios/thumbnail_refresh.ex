defmodule RC.Scenarios.ThumbnailRefresh do
  @moduledoc """
  Keeps stored Forge thumbnails in step with the renderer. On boot (see
  RC.Application), if `RC.Scenarios.ThumbnailRenderer.version/0` differs
  from the version the stored thumbnails were drawn with, every map and
  scenario thumbnail is re-rendered once and the new version recorded in
  site_settings. A deploy that changes the renderer (e.g. the v2 y-up
  flip) therefore refreshes the Forge lists by itself: no rpc step.

  Rows that fail to render keep their old image; link previews don't
  depend on stored thumbnails (Portal.OgImage renders from game_data).
  """

  require Logger

  alias RC.Scenarios.ThumbnailRenderer
  alias RC.SiteSettings

  @key "thumbnail_renderer_version"

  def run do
    current = ThumbnailRenderer.version()

    case SiteSettings.get(@key) do
      %{"version" => ^current} ->
        :up_to_date

      previous ->
        Logger.info("[thumbnails] renderer v#{current} (stored: #{inspect(previous)}), re-rendering all thumbnails")
        result = RC.Scenarios.regenerate_all_thumbnails()
        Logger.info("[thumbnails] refresh done: #{inspect(result)}")
        SiteSettings.put(@key, %{"version" => current, "result" => Map.new(result, fn {k, v} -> {to_string(k), v} end)})
        {:refreshed, result}
    end
  end
end
