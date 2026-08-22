defmodule Portal.ForgeShareControllerTest do
  use Portal.HTMLConnCase

  alias RC.Scenarios

  # Minimal-but-real game_data so the synchronous test-env thumbnail
  # regeneration has something to render instead of erroring on an
  # empty blob.
  @game_data %{
    size: 120,
    systems: [%{key: 1, type: "red_dwarf", position: %{x: 10, y: 10}}],
    sectors: [],
    blackholes: []
  }

  # The name deliberately carries markup-hostile characters — the share
  # page interpolates it into meta attributes and the body, so this
  # doubles as the escaping regression test.
  @name ~s(Spiral <Arm> & "Void")

  defp map_fixture(published? \\ true) do
    {:ok, %{map_with_thumbnail: map}} =
      Scenarios.create_map(%{
        game_data: @game_data,
        game_metadata: %{name: @name, size: 120, system_number: 42, sector_number: 7},
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

  defp scenario_fixture_published do
    {:ok, %{scenario: scenario}} =
      Scenarios.create_scenario(
        %{
          game_data: @game_data,
          game_metadata: %{name: @name, size: 120, speed: "medium", factions: [%{}, %{}]},
          is_map: false,
          is_official: true
        },
        :no_thumbnail
      )

    {:ok, scenario} = Scenarios.publish_scenario(scenario)
    scenario
  end

  describe "GET /forge/map/:id" do
    test "renders OpenGraph tags for a published map without auth", %{conn: conn} do
      map = map_fixture()

      html = conn |> get("/forge/map/#{map.id}") |> html_response(200)

      assert html =~ ~s(property="og:title")
      assert html =~ "Spiral &lt;Arm&gt; &amp; &quot;Void&quot;"
      refute html =~ "<Arm>"
      assert html =~ "42 systems in 7 sectors"
      assert html =~ ~s(url=/portal/create/map/view/#{map.id})
    end

    test "404s for a draft", %{conn: conn} do
      map = map_fixture(false)

      assert conn |> get("/forge/map/#{map.id}") |> response(404)
    end

    test "404s for unknown and non-numeric ids", %{conn: conn} do
      assert conn |> get("/forge/map/999999") |> response(404)
      assert conn |> get("/forge/map/not-a-number") |> response(404)
    end
  end

  describe "GET /forge/scenario/:id" do
    test "renders OpenGraph tags for a published scenario", %{conn: conn} do
      scenario = scenario_fixture_published()

      html = conn |> get("/forge/scenario/#{scenario.id}") |> html_response(200)

      assert html =~ ~s(property="og:title")
      assert html =~ "medium speed"
      assert html =~ "2 factions"
      assert html =~ ~s(url=/portal/create/scenario/view/#{scenario.id})
    end

    test "404s for a map id on the scenario route", %{conn: conn} do
      map = map_fixture()

      assert conn |> get("/forge/scenario/#{map.id}") |> response(404)
    end
  end
end
