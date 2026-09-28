defmodule Portal.OgImageControllerTest do
  use Portal.HTMLConnCase

  alias RC.Scenarios

  @game_data %{
    "size" => 120,
    "systems" => [
      %{"key" => 1, "type" => "red_dwarf", "position" => %{"x" => 10, "y" => 10}},
      %{"key" => 2, "type" => "blue_giant", "position" => %{"x" => 90, "y" => 100}}
    ],
    "sectors" => [
      %{
        "key" => 0,
        "name" => "Alpha",
        "faction" => "tetrarchy",
        "points" => [[0, 0], [120, 0], [120, 120], [0, 120]],
        "centroid" => [60, 60]
      }
    ],
    "blackholes" => []
  }

  @png_magic <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp draft_map do
    {:ok, %{map_with_thumbnail: map}} =
      Scenarios.create_map(%{game_data: @game_data, game_metadata: %{name: "WIP"}, is_map: true})

    map
  end

  defp lobby do
    %{instance: instance} = RC.ScenarioFixtures.instance_fixture()

    RC.Instances.Instance
    |> RC.Repo.get!(instance.id)
    |> Ecto.Changeset.change(game_data: @game_data, game_metadata: %{"size" => 120}, public: false)
    |> RC.Repo.update!()
  end

  test "a map's preview renders from its game_data, drafts included, by share token", %{conn: conn} do
    map = draft_map()

    conn = get(conn, "/og/map/#{map.share_token}.png")

    assert <<@png_magic, _::binary>> = response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
  end

  test "a lobby's preview is its own map, even for a private game", %{conn: conn} do
    instance = lobby()

    assert <<@png_magic, _::binary>> = conn |> get("/og/instance/#{instance.share_token}.png") |> response(200)
  end

  test "numeric ids, unknown tokens and other extensions 404", %{conn: conn} do
    map = draft_map()

    assert conn |> get("/og/map/#{map.id}.png") |> response(404)
    assert conn |> get("/og/map/AAAAAAAAAAAAAAAA.png") |> response(404)
    assert conn |> get("/og/map/#{map.share_token}.svg") |> response(404)
    # A map's token is not a scenario's.
    assert conn |> get("/og/scenario/#{map.share_token}.png") |> response(404)
  end

  test "the og:image URL changes when the geometry does" do
    map = draft_map()
    before = Portal.OgImage.url(:map, map)

    moved = put_in(map.game_data["systems"], [%{"key" => 1, "position" => %{"x" => 5, "y" => 5}}])

    assert before =~ "/og/map/#{map.share_token}.png?v=t2-"
    refute Portal.OgImage.url(:map, moved) == before
  end
end
