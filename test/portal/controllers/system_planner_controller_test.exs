defmodule Portal.SystemPlannerControllerTest do
  use Portal.APIConnCase

  import RC.Fixtures

  setup %{conn: conn} do
    {:ok, conn: login(conn, fixture(:user))}
  end

  defp template(conn, speed) do
    conn
    |> get("/api/system-planner/template?speed=#{speed}")
    |> json_response(200)
  end

  test "the template computes into a full system", %{conn: conn} do
    plan = template(conn, "medium") |> Map.put("faction", "cardan")

    body = conn |> post("/api/system-planner/compute", plan) |> json_response(200)

    assert %{"system" => system, "growth" => growth} = body
    assert is_number(growth)
    assert system["population_status"] == "normal"
    assert system["production"]["value"] > 0
    # the starting infrastructure houses the population
    assert %{"value" => housing, "details" => %{"building" => [_]}} = system["habitation"]
    assert housing > 0
    assert [_ | _] = system["bodies"]
  end

  test "an impossible plan is a 422 with the reason", %{conn: conn} do
    plan = template(conn, "slow") |> Map.put("faction", "cardan") |> Map.put("lexes", ["nope"])

    assert %{"message" => "unknown_lex"} =
             conn |> post("/api/system-planner/compute", plan) |> json_response(422)
  end

  test "an unknown speed is a 422", %{conn: conn} do
    assert %{"message" => "invalid_speed"} =
             conn |> get("/api/system-planner/template?speed=warp") |> json_response(422)
  end

  test "game data can be loaded for another speed", %{conn: conn} do
    flash = conn |> get("/api/data") |> json_response(200)
    legacy = conn |> get("/api/data?speed=slow") |> json_response(200)

    levels = fn data, key -> data["building"] |> Enum.find(&(&1["key"] == key)) |> Map.get("levels") |> length() end

    # Flash buildings have a single level; Legacy ones have five.
    assert levels.(flash, "infra_open") == 1
    assert levels.(legacy, "infra_open") == 5
  end

  test "requires a signed-in account" do
    conn = Phoenix.ConnTest.build_conn() |> put_req_header("accept", "application/json")
    assert conn |> post("/api/system-planner/compute", %{}) |> response(401)
  end
end
