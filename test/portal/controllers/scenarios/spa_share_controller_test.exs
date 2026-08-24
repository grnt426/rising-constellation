defmodule Portal.SpaShareControllerTest do
  use Portal.HTMLConnCase

  alias RC.Scenarios

  @game_data %{
    size: 120,
    systems: [%{key: 1, type: "red_dwarf", position: %{x: 10, y: 10}}],
    sectors: [],
    blackholes: []
  }

  defp map_fixture(published? \\ true) do
    {:ok, %{map_with_thumbnail: map}} =
      Scenarios.create_map(%{
        game_data: @game_data,
        game_metadata: %{name: ~s(Alpha "<Cluster>"), size: 120, system_number: 9, sector_number: 3},
        is_map: true,
        is_official: true
      })

    if published? do
      {:ok, map} = Scenarios.publish_map(map)
      map
    else
      map
    end
  end

  describe "GET /portal/create/map/view/:id" do
    test "serves the SPA index with injected OpenGraph tags", %{conn: conn} do
      map = map_fixture()

      conn = get(conn, "/portal/create/map/view/#{map.id}")
      html = html_response(conn, 200)

      # Injected tags with the name escaped, immediately inside <head>.
      assert html =~ ~s(property="og:title" content="Alpha &quot;&lt;Cluster&gt;&quot;")
      assert html =~ "9 systems in 3 sectors"
      assert html =~ ~s(/portal/create/map/view/#{map.id}")
      # Title swapped, app skeleton intact — the page is still the SPA.
      assert html =~ "Alpha &quot;&lt;Cluster&gt;&quot; — Tetrarchy Falls</title>"
      refute html =~ "<title>Tetrarchy Falls</title>"
      assert html =~ ~s(<div id="app">)
      assert html =~ "/portal/js/app.js"
      # No meta-refresh — this IS the destination page.
      refute html =~ "http-equiv=\"refresh\""
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
    end

    test "drafts get the untouched SPA index", %{conn: conn} do
      map = map_fixture(false)

      html = conn |> get("/portal/create/map/view/#{map.id}") |> html_response(200)

      refute html =~ "og:title"
      assert html =~ "<title>Tetrarchy Falls</title>"
    end
  end

  describe "the editor and derived routes" do
    test "the map editor URL unfurls too", %{conn: conn} do
      map = map_fixture()

      html = conn |> get("/portal/create/map/#{map.id}") |> html_response(200)
      assert html =~ ~s(property="og:title")
    end

    test "/create/map/new (non-numeric id) serves the plain index", %{conn: conn} do
      html = conn |> get("/portal/create/map/new") |> html_response(200)
      refute html =~ "og:title"
    end

    test "scenario-from-map unfurls as the source map", %{conn: conn} do
      map = map_fixture()

      html = conn |> get("/portal/create/scenario/new/#{map.id}") |> html_response(200)
      assert html =~ ~s(property="og:title" content="Alpha &quot;&lt;Cluster&gt;&quot;")
    end
  end

  test "404s when no index.html can be found (nginx falls back to static)", %{conn: conn} do
    original = Application.get_env(:rc, Portal.SpaShareController)
    Application.put_env(:rc, Portal.SpaShareController, index_path: "test/support/does_not_exist.html")
    on_exit(fn -> Application.put_env(:rc, Portal.SpaShareController, original) end)

    map = map_fixture()

    assert conn |> get("/portal/create/map/view/#{map.id}") |> response(404)
  end
end
