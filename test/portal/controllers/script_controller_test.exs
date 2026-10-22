defmodule Portal.ScriptControllerTest do
  use Portal.APIConnCase

  import RC.Fixtures

  @tithe ~s|setup {\n  name = "Tithe"\n}\n\nscore player.credit\n|

  setup %{conn: conn} do
    alice = fixture(:user)
    bob = fixture(:user2)
    {:ok, alice: alice, bob: bob, as_alice: login(conn, alice), as_bob: login(build_conn(), bob)}
  end

  test "the scripts API needs a signed-in account" do
    assert build_conn() |> get("/api/edict/scripts") |> response(401)
    assert build_conn() |> post("/api/edict/scripts", %{source: @tithe}) |> response(401)
  end

  test "save, list, open, change and delete your own scripts", %{as_alice: conn} do
    %{"script" => script} =
      conn |> post("/api/edict/scripts", %{source: @tithe, layout: %{pos: %{}}}) |> json_response(201)

    assert %{"name" => "Tithe", "error_count" => 0, "mine" => true, "published_at" => nil, "source" => @tithe} = script
    assert %{"decls" => _} = script["program"]

    assert %{"scripts" => [%{"id" => id}], "limit" => 10} = conn |> get("/api/edict/scripts") |> json_response(200)
    assert id == script["id"]
    assert %{"script" => %{"source" => @tithe}} = conn |> get("/api/edict/scripts/#{id}") |> json_response(200)

    changed = String.replace(@tithe, "player.credit", "player.credit * 2")

    assert %{"script" => %{"source" => ^changed}} =
             conn |> put("/api/edict/scripts/#{id}", %{source: changed}) |> json_response(200)

    assert conn |> delete("/api/edict/scripts/#{id}") |> response(204)
    assert conn |> get("/api/edict/scripts/#{id}") |> json_response(404)
  end

  test "refusals come with a code the editor can explain", %{as_alice: conn} do
    assert %{"message" => "script_invalid", "detail" => _} =
             conn |> post("/api/edict/scripts", %{source: "setup {"}) |> json_response(422)

    %{"script" => %{"id" => broken}} =
      conn |> post("/api/edict/scripts", %{source: "score player.credt"}) |> json_response(201)

    assert %{"message" => "script_has_errors"} =
             conn |> put("/api/edict/scripts/#{broken}/publish") |> json_response(422)

    for i <- 2..10, do: post(conn, "/api/edict/scripts", %{source: "score #{i}"})

    assert %{"message" => "script_limit", "limit" => 10} =
             conn |> post("/api/edict/scripts", %{source: "score 11"}) |> json_response(422)
  end

  test "publishing: others can find, open and attach it, never change it; copies can't be published",
       %{as_alice: alice_conn, as_bob: bob_conn} do
    %{"script" => %{"id" => id}} = alice_conn |> post("/api/edict/scripts", %{source: @tithe}) |> json_response(201)

    # private until published
    assert bob_conn |> get("/api/edict/scripts/#{id}") |> json_response(404)
    assert %{"scripts" => []} = bob_conn |> get("/api/edict/scripts/published") |> json_response(200)

    assert %{"script" => %{"published_at" => published}} =
             alice_conn |> put("/api/edict/scripts/#{id}/publish") |> json_response(200)

    assert published

    assert %{"scripts" => [listed]} = bob_conn |> get("/api/edict/scripts/published?search=tit") |> json_response(200)
    assert %{"id" => ^id, "mine" => false, "name" => "Tithe"} = listed
    refute Map.has_key?(listed, "source")

    assert %{"script" => %{"source" => @tithe, "mine" => false}} =
             bob_conn |> get("/api/edict/scripts/#{id}") |> json_response(200)

    # bob can't change, publish or delete it
    assert bob_conn |> put("/api/edict/scripts/#{id}", %{source: "score 1"}) |> json_response(404)
    assert bob_conn |> delete("/api/edict/scripts/#{id}/publish") |> json_response(404)
    assert bob_conn |> delete("/api/edict/scripts/#{id}") |> json_response(404)

    # bob's unchanged copy saves, but can't be published
    %{"script" => %{"id" => copy}} = bob_conn |> post("/api/edict/scripts", %{source: @tithe}) |> json_response(201)

    assert %{"message" => "script_duplicate", "script" => %{"id" => ^id}} =
             bob_conn |> put("/api/edict/scripts/#{copy}/publish") |> json_response(409)

    assert %{"script" => %{"published_at" => nil}} =
             alice_conn |> delete("/api/edict/scripts/#{id}/publish") |> json_response(200)
  end

  test "POST /api/edict/check-scenario checks the picked scripts against the map, without their text",
       %{as_alice: conn} do
    %{"script" => %{"id" => fits}} =
      conn |> post("/api/edict/scripts", %{source: "setup {\n  factions = 2\n}\nscore 1\n"}) |> json_response(201)

    %{"script" => %{"id" => misfit}} =
      conn |> post("/api/edict/scripts", %{source: "setup {\n  factions = 5\n}\nscore 1\n"}) |> json_response(201)

    game_data = %{"speed" => "fast", "time_limit" => 60, "factions" => [%{"key" => "tetrarchy"}, %{"key" => "cardan"}]}

    body =
      conn
      |> post("/api/edict/check-scenario", %{game_data: game_data, scripts: [fits, misfit, 999_999]})
      |> json_response(200)

    assert %{"max_scripts" => 3, "scripts" => [a, b]} = body
    refute Map.has_key?(a, "source") or Map.has_key?(b, "source")
    assert [%{"diagnostics" => []}, %{"diagnostics" => [%{"severity" => "warning", "message" => m}]}] = body["checks"]
    assert m =~ "written for 5 factions"
  end
end
