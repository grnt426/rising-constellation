defmodule RC.Scenarios.ThumbnailRefreshTest do
  use RC.DataCase

  alias RC.Scenarios.ThumbnailRefresh

  test "re-renders stored thumbnails once per renderer version" do
    {:ok, _} =
      RC.Scenarios.create_map(%{
        game_data: %{"size" => 120, "systems" => [%{"key" => 1, "position" => %{"x" => 10, "y" => 10}}]},
        game_metadata: %{"name" => "Old"},
        is_map: true
      })

    assert {:refreshed, %{total: total, ok: ok}} = ThumbnailRefresh.run()
    assert total >= 1 and ok >= 1

    assert %{"version" => 2} = RC.SiteSettings.get("thumbnail_renderer_version")
    assert ThumbnailRefresh.run() == :up_to_date
  end
end
